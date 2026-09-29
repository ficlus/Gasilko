// Provider boundary. No raw response, URL, exception or key may reach logs/client/database.
export type Point = [number, number]; // longitude, latitude
export type Matrix = { times: number[][]; distances: number[][] };
export type RoadPath = { distance: number; seconds: number; coordinates: Point[]; snapped: Point[] };
export interface RoadProvider {
  readonly name: string;
  snap(points: Point[]): Promise<Point[]>;
  matrix(points: Point[]): Promise<Matrix>;
  route(points: Point[]): Promise<RoadPath>;
}
export class RoutingError extends Error {
  constructor(readonly code: string, readonly status = 422) { super(code); }
}
const number = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0;
const point = (v: unknown): v is Point => Array.isArray(v) && v.length >= 2 &&
  typeof v[0] === "number" && typeof v[1] === "number" && Number.isFinite(v[0]) && Number.isFinite(v[1]) &&
  Math.abs(v[0]) <= 180 && Math.abs(v[1]) <= 90;
// Request GeoJSON, but also normalize the provider's documented 2D encoded-polyline format.
// Both formats become [longitude, latitude] before persistence; Android never decodes provider data.
function coordinates(value: unknown): Point[] {
  if (typeof value === "string") {
    const encoded = value;
    let cursor = 0, latitude = 0, longitude = 0;
    const points: Point[] = [];
    const delta = () => {
      let result = 0, shift = 0, digit: number;
      do {
        if (cursor >= encoded.length || shift > 30) throw new RoutingError("ROUTE_PROVIDER_UNAVAILABLE", 502);
        digit = encoded.charCodeAt(cursor++) - 63;
        if (digit < 0 || digit > 63) throw new RoutingError("ROUTE_PROVIDER_UNAVAILABLE", 502);
        result += (digit & 31) * 2 ** shift; shift += 5;
      } while (digit >= 32);
      return result % 2 ? -(result + 1) / 2 : result / 2;
    };
    while (cursor < encoded.length) {
      latitude += delta(); longitude += delta();
      const p: Point = [longitude / 100_000, latitude / 100_000];
      if (!point(p)) throw new RoutingError("ROUTE_PROVIDER_UNAVAILABLE", 502);
      points.push(p);
    }
    return points;
  }
  const line = value as { type?: string; coordinates?: unknown };
  if (line?.type !== "LineString" || !Array.isArray(line.coordinates) || !line.coordinates.every(point))
    throw new RoutingError("ROUTE_PROVIDER_UNAVAILABLE", 502);
  return line.coordinates.map((p: Point) => [p[0], p[1]]);
}
const distinct = (points: Point[]) => new Set(points.map(p => p.join(","))).size;
export class GraphHopper implements RoadProvider {
  readonly name = "GraphHopper";
  private readonly snaps = new Map<string, Promise<Point>>();
  constructor(private readonly key: string, private readonly signal: AbortSignal) {}
  private async post(path: "matrix" | "route", body: unknown): Promise<any> {
    try {
      const response = await fetch("https://graphhopper.com/api/1/" + path + "?key=" + encodeURIComponent(this.key), {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
        signal: this.signal, redirect: "error",
      });
      if (!response.ok) {
        await response.body?.cancel();
        throw new RoutingError(response.status === 429 || response.status === 413 ? "ROUTE_PROVIDER_LIMIT" :
          response.status === 400 ? "ROUTE_UNREACHABLE" : "ROUTE_PROVIDER_UNAVAILABLE", 502);
      }
      // Bound retained geometry/matrix data; never echo provider bodies.
      const reader = response.body?.getReader();
      if (!reader) throw new RoutingError("ROUTE_PROVIDER_UNAVAILABLE", 502);
      const chunks: Uint8Array[] = []; let size = 0;
      while (true) {
        const { value, done } = await reader.read(); if (done) break;
        size += value.length;
        if (size > 4_000_000) { await reader.cancel(); throw new RoutingError("ROUTE_PROVIDER_LIMIT", 502); }
        chunks.push(value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      return JSON.parse(new TextDecoder().decode(bytes));
    } catch (error) {
      if (error instanceof RoutingError) throw error;
      throw new RoutingError("ROUTE_PROVIDER_UNAVAILABLE", 502);
    }
  }
  async matrix(points: Point[]): Promise<Matrix> {
    // Rectangular form also supports one/two locations; square arrays remain directed (one-way roads).
    const data = await this.post("matrix", { profile: "car", from_points: points, to_points: points,
      snap_preventions: [], out_arrays: ["times", "distances"], fail_fast: true });
    for (const key of ["times", "distances"]) {
      if (!Array.isArray(data[key]) || data[key].length !== points.length ||
        data[key].some((row: unknown) => !Array.isArray(row) || row.length !== points.length || !row.every(number)))
        throw new RoutingError("ROUTE_UNREACHABLE");
    }
    return { times: data.times, distances: data.distances }; // seconds, meters
  }
  async snap(points: Point[]): Promise<Point[]> {
    // The hosted Directions API snaps every waypoint to the closest car-accessible road.
    // No local radius, distance rejection, road-name hint or excluded road class is applied.
    // Obtain the provider's actual positions before building the optimization matrix.
    // Identical-point routes resolve each access point independently: an arbitrary preliminary
    // multi-stop order must not become an extra routability constraint before optimization.
    // Bound concurrency and reuse duplicate coordinates (including shared team starts) per request.
    const snapped = new Array<Point>(points.length);
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(4, points.length) }, async () => {
      while (next < points.length) {
        const i = next++, key = points[i].join(",");
        let pending = this.snaps.get(key);
        if (!pending) {
          pending = this.route([points[i]]).then(path => path.snapped[0]);
          this.snaps.set(key, pending);
        }
        snapped[i] = await pending;
      }
    }));
    return snapped;
  }
  async route(points: Point[]): Promise<RoadPath> {
    const request = points.length === 1 ? [points[0], points[0]] : points;
    const data = await this.post("route", { profile: "car", points: request, points_encoded: false,
      snap_preventions: [], instructions: false, calc_points: true, elevation: false });
    const path = data.paths?.[0];
    if (!path || !number(path.distance) || !number(path.time))
      throw new RoutingError("ROUTE_UNREACHABLE");
    const snapped = coordinates(path.snapped_waypoints);
    const geometry = path.points == null ? [] : coordinates(path.points);
    if (snapped.length !== request.length ||
      ((distinct(snapped) > 1 || path.distance > 0) && distinct(geometry) < 2))
      throw new RoutingError("ROUTE_PROVIDER_UNAVAILABLE", 502);
    return { distance: path.distance, seconds: path.time / 1000, coordinates: geometry, snapped };
  }
}

