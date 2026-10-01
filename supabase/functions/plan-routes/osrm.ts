import { RoutingError, type Point, type Matrix, type RoadPath, type RoadProvider, type NavigationLeg } from "./provider.ts";

// Keep maneuver/leg parsing at the provider boundary for a later navigation feature.
type Step = { name: string; distance: number; duration: number; geometry: { type: string; coordinates: Point[] }; maneuver: { type: string; modifier?: string; location: Point } };
type Leg = { distance: number; duration: number; steps?: Step[] };
type Route = { distance: number; duration: number; geometry: { type: string; coordinates: Point[] }; legs: Leg[] };
const point = (p: unknown): p is Point => Array.isArray(p) && p.length === 2 &&
  p.every(v => typeof v === "number" && Number.isFinite(v)) && Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 90;
const positive = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n) && n >= 0;

export class OsrmRoutingProvider implements RoadProvider {
  readonly name = "OSRM";
  private readonly authorization: string;
  private readonly base: string;
  constructor(base: string, username: string, password: string, private readonly signal: AbortSignal) {
    try {
      const url = new URL(base);
      if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || username.includes(":"))
        throw new Error();
      this.base = url.toString().replace(/\/$/, "");
      this.authorization = "Basic " + btoa(String.fromCharCode(...new TextEncoder().encode(username + ":" + password)));
    } catch { throw new RoutingError("ROUTE_CONFIGURATION", 503); }
  }
  private async get(service: string, points: Point[], query: string): Promise<any> {
    if (!points.every(point)) throw new RoutingError("ROUTE_COORDINATES");
    try {
      const response = await fetch(`${this.base}/${service}/v1/driving/${points.map(p => p.join(",")).join(";")}?${query}`, {
        headers: { Authorization: this.authorization }, signal: this.signal, redirect: "error",
      });
      if ([401, 403, 404].includes(response.status)) { await response.body?.cancel(); throw new RoutingError("ROUTE_CONFIGURATION", 503); }
      if ([413, 414, 429].includes(response.status)) { await response.body?.cancel(); throw new RoutingError("ROUTE_LIMIT"); }
      if (response.status >= 500) { await response.body?.cancel(); throw new RoutingError("ROUTE_PROVIDER", 502); }
      const reader = response.body?.getReader();
      if (!reader) throw new RoutingError("ROUTE_PROVIDER", 502);
      const chunks: Uint8Array[] = []; let size = 0;
      while (true) {
        const { value, done } = await reader.read(); if (done) break;
        size += value.length;
        if (size > 4_000_000) { await reader.cancel(); throw new RoutingError("ROUTE_LIMIT"); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      const data = JSON.parse(new TextDecoder().decode(bytes));
      if (data.code === "TooBig") throw new RoutingError("ROUTE_LIMIT");
      if (["NoSegment", "NoRoute", "NoTable"].includes(data.code)) throw new RoutingError("ROUTE_UNREACHABLE");
      if (["InvalidUrl", "InvalidService", "InvalidVersion", "InvalidOptions"].includes(data.code)) throw new RoutingError("ROUTE_CONFIGURATION");
      if (["InvalidQuery", "InvalidValue"].includes(data.code)) throw new RoutingError("ROUTE_COORDINATES");
      if (!response.ok || data.code !== "Ok") throw new RoutingError("ROUTE_PROVIDER", 502);
      return data;
    } catch (error) {
      if (error instanceof RoutingError) throw error;
      throw new RoutingError("ROUTE_PROVIDER", 502);
    }
  }
  async snap(points: Point[]): Promise<Point[]> {
    const result = new Array<Point>(points.length); let next = 0;
    await Promise.all(Array.from({ length: Math.min(4, points.length) }, async () => {
      while (next < points.length) {
        const index = next++;
        const data = await this.get("nearest", [points[index]], "number=1&radiuses=unlimited");
         const waypoint = data.waypoints?.[0];
        const snapped = waypoint?.location;
        const snapDistance = waypoint?.distance;
        
        if (
          !point(snapped) ||
          typeof snapDistance !== "number" ||
          !Number.isFinite(snapDistance) ||
          snapDistance > 300
        ) {
          throw new RoutingError("ROUTE_UNREACHABLE");
        }
        
        result[index] = snapped;
      }
    }));
    return result;
  }
  async matrix(points: Point[]): Promise<Matrix> {
    const data = await this.get("table", points, "annotations=duration,distance");
    for (const key of ["durations", "distances"]) {
      if (!Array.isArray(data[key]) || data[key].length !== points.length || data[key].some((row: unknown) =>
        !Array.isArray(row) || row.length !== points.length || !row.every(positive))) throw new RoutingError("ROUTE_UNREACHABLE");
    }
    return { times: data.durations, distances: data.distances };
  }
  async route(points: Point[], navigation = false): Promise<RoadPath> {
    const data = await this.get("route", points, `overview=full&geometries=geojson&steps=${navigation}&alternatives=false`);
    const route: Route | undefined = data.routes?.[0];
    const snapped = data.waypoints?.map((w: { location: Point }) => w.location);
    if (!route || !positive(route.distance) || !positive(route.duration) || route.geometry?.type !== "LineString" ||
      !Array.isArray(route.geometry.coordinates) || !route.geometry.coordinates.every(point) ||
      !Array.isArray(snapped) || snapped.length !== points.length || !snapped.every(point) ||
      (route.distance > 0 && route.geometry.coordinates.length < 2)) throw new RoutingError("ROUTE_PROVIDER", 502);
    const legs: NavigationLeg[] = navigation && Array.isArray(route.legs) ? route.legs.map(leg => {
      if (!positive(leg.distance) || !positive(leg.duration)) throw new RoutingError("ROUTE_PROVIDER", 502);
      const steps = (leg.steps ?? []).map(step => {
        if (!positive(step.distance) || !positive(step.duration) || !Array.isArray(step.geometry?.coordinates) ||
          !step.geometry.coordinates.every(point) || !point(step.maneuver?.location)) throw new RoutingError("ROUTE_PROVIDER", 502);
        return { coordinates: step.geometry.coordinates, distance: step.distance, seconds: step.duration,
          road: typeof step.name === "string" ? step.name.slice(0, 300) : "",
          type: typeof step.maneuver.type === "string" ? step.maneuver.type.slice(0, 40) : "continue",
          modifier: typeof step.maneuver.modifier === "string" ? step.maneuver.modifier.slice(0, 40) : "",
          location: step.maneuver.location };
      });
      return { distance: leg.distance, seconds: leg.duration, steps };
    }) : [];
    return { distance: route.distance, seconds: route.duration, coordinates: route.geometry.coordinates, snapped, legs };
  }
}
