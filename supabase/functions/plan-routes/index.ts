import { OsrmRoutingProvider } from "./osrm.ts";
import { GraphHopper, RoutingError, type Point, type RoadPath, type RoadProvider } from "./provider.ts";
import { drivingOrder } from "./optimize.ts";

type Item = { id: string; hydrant: string; team: string; code: string | null; latitude: number; longitude: number };
type Input = { id: string; organization: string; version: number; latitude: number | null; longitude: number | null;
  returnToStart: boolean; teams: string[]; items: Item[] };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
});
async function calculate(input: Input, provider: RoadProvider) {
  // Bound edge CPU, provider credits and response size. Provider subscription limits may be lower.
  if (input.teams.length > 20 || input.items.length > 500) throw new RoutingError("ROUTE_LIMIT");
  const results = [];
  for (const team of [...input.teams].sort()) {
    const items = input.items.filter(i => i.team === team).sort((a, b) => a.hydrant < b.hydrant ? -1 : a.hydrant > b.hydrant ? 1 : 0);
    const features: unknown[] = [];
    if (!items.length) {
      results.push({ team, provider: provider.name, profile: "car", distance_m: 0, duration_s: 0,
        stops: [], geometry: { type: "FeatureCollection", features } }); continue;
    }
    const start: Point | null = input.latitude === null ? null : [input.longitude!, input.latitude];
    const points: Point[] = [...(start ? [start] : []), ...items.map(i => [i.longitude, i.latitude] as Point)];
    if (points.length > 100) throw new RoutingError("ROUTE_LIMIT");
    const snapped = await provider.snap(points);
    const order = points.length === 1 ? [0] : drivingOrder(await provider.matrix(snapped), input.returnToStart);
    const roadPoints = order.map(i => snapped[i]);
    if (input.returnToStart && roadPoints.length > 1) roadPoints.push(roadPoints[0]);
    // A single stop with no explicit start has no driving leg. Keep its road access point, not a fake line.
    const path: RoadPath = roadPoints.length === 1 ? { distance: 0, seconds: 0, coordinates: [], snapped: roadPoints } :
      await provider.route(roadPoints);
    const stops = order.filter(i => !start || i !== 0).map((i, index) => ({ ...items[i - (start ? 1 : 0)], order: index + 1 }));
    if (new Set(path.coordinates.map(p => p.join(","))).size > 1)
      features.push({ type: "Feature", properties: { kind: "road" },
      geometry: { type: "LineString", coordinates: path.coordinates } });
    for (const stop of stops) {
      // Keep canonical stop payloads and original hydrant coordinates unchanged. The geometry JSON
      // stores the provider road-access point alongside its UUID, without a schema/Room migration.
      const routed = path.snapped[stop.order - 1 + (start ? 1 : 0)];
      features.push({ type: "Feature", properties: { kind: "stop", number: stop.order, uuid: stop.hydrant, snapped: routed },
        geometry: { type: "Point", coordinates: [stop.longitude, stop.latitude] } });
    }
    results.push({ team, provider: provider.name, profile: "car", distance_m: path.distance,
      duration_s: path.seconds, geometry: { type: "FeatureCollection", features }, stops });
  }
  if (JSON.stringify(results).length > 4_000_000) throw new RoutingError("ROUTE_LIMIT");
  return results;
}
Deno.serve(async req => {
  try {
    if (req.method !== "POST") return reply({ error: "METHOD_NOT_ALLOWED" }, 405);
    const authorization = req.headers.get("authorization");
    if (!authorization?.startsWith("Bearer ")) throw new RoutingError("EXPIRED", 401);
    const reader = req.body?.getReader();
    if (!reader) throw new RoutingError("VALIDATION", 400);
    const chunks: Uint8Array[] = []; let size = 0;
    while (true) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.length;
      if (size > 2048) { await reader.cancel(); throw new RoutingError("VALIDATION", 400); }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const raw = new TextDecoder().decode(bytes);
    let body: any; try { body = JSON.parse(raw); } catch { throw new RoutingError("VALIDATION", 400); }
    if (!uuid.test(body?.organization ?? "") || !uuid.test(body?.request?.id ?? "") ||
      !uuid.test(body?.request?.operation_id ?? "") || !Number.isSafeInteger(body?.request?.version) || body.request.version < 1)
      throw new RoutingError("VALIDATION", 400);
    // Ignore client geometry, stops, provider URLs and actor IDs entirely.
    const action = body.request.action ?? "ROUTE";
    if (!["ROUTE", "ROUTE_REMAINING"].includes(action)) throw new RoutingError("VALIDATION", 400);
    if (body.request.team_id != null && !uuid.test(body.request.team_id)) throw new RoutingError("VALIDATION", 400);
    const request = { ...(body.request.team_id ? { team_id: body.request.team_id } : {}), id: body.request.id, version: body.request.version, operation_id: body.request.operation_id, action };
    const url = Deno.env.get("SUPABASE_URL"), anon = Deno.env.get("SUPABASE_ANON_KEY");
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), key = Deno.env.get("GRAPHHOPPER_API_KEY");
    if (!url || !anon || !service) throw new RoutingError("ROUTE_CONFIGURATION", 503);
    const signal = AbortSignal.timeout(100_000);
    const auth = await fetch(url + "/auth/v1/user", { headers: { Authorization: authorization, apikey: anon }, signal });
    if (!auth.ok) {
      await auth.body?.cancel();
      if (auth.status === 401 || auth.status === 403) throw new RoutingError("EXPIRED", 401);
      throw new RoutingError("SERVER", 503);
    }
    const user = await auth.json();
    if (!uuid.test(user.id ?? "")) throw new RoutingError("EXPIRED", 401);
    async function rpc(name: string, args: unknown, trusted = false): Promise<any> {
      const response = await fetch(url + "/rest/v1/rpc/" + name, { method: "POST", signal,
        headers: { Authorization: trusted ? "Bearer " + service : authorization!, apikey: trusted ? service! : anon!,
          "Content-Type": "application/json" }, body: JSON.stringify(args) });
      if (!response.ok) {
        let error: any = {}; try { error = await response.json(); } catch { /* bounded public code only */ }
        const code = error.code === "42501" ? "FORBIDDEN" : error.message === "PLAN_VERSION_CONFLICT" ? "CONFLICT" :
          error.message === "ROUTE_COORDINATES_REQUIRED" ? "ROUTE_COORDINATES" : error.message === "ROUTE_ASSIGNMENTS_REQUIRED" ? "ROUTE_ASSIGNMENTS" :
          response.status === 401 ? "EXPIRED" : error.code?.startsWith("22") ? "VALIDATION" : "SERVER";
        throw new RoutingError(code, code === "FORBIDDEN" ? 403 : code === "EXPIRED" ? 401 : code === "CONFLICT" ? 409 : 422);
      }
      const text = await response.text(); return text ? JSON.parse(text) : null;
    }
    const prepared = await rpc("prepare_plan_routes", { organization: body.organization, request });
    if (!prepared.acknowledged) {
      const base = Deno.env.get("OSRM_BASE_URL"), username = Deno.env.get("OSRM_USERNAME"), password = Deno.env.get("OSRM_PASSWORD");
      const providerSignal = () => AbortSignal.any([signal, AbortSignal.timeout(45_000)]);
      let results;
      if (base && username && password) {
        try { results = await calculate(prepared.input as Input, new OsrmRoutingProvider(base, username, password, providerSignal())); }
        catch (error) {
          // Only transport/provider availability failures allow a fresh provider calculation.
          if (!(error instanceof RoutingError) || error.code !== "ROUTE_PROVIDER" || !key || signal.aborted) throw error;
          results = await calculate(prepared.input as Input, new GraphHopper(key, providerSignal()));
        }
      } else {
        if (base || username || password || !key) throw new RoutingError("ROUTE_CONFIGURATION", 503);
        results = await calculate(prepared.input as Input, new GraphHopper(key, providerSignal()));
      }
      await rpc("commit_plan_routes", { actor: user.id, organization: body.organization, request, input: prepared.input, results }, true);
    }
    // Fresh RLS authorization on the response, even if access changed while GraphHopper was running.
    return reply(await rpc("read_inspection_plans", { organization: body.organization }));
  } catch (error) {
    if (error instanceof RoutingError) return reply({ error: error.code }, error.status);
    // Do not log/return exceptions: fetch errors may contain the provider key-bearing URL.
    return reply({ error: "ROUTE_PROVIDER" }, 502);
  }
});

