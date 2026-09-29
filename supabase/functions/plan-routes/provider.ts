// Provider boundary. No raw response, URL, exception or key may reach logs/client/database.
export type Point = [number, number]; // longitude, latitude
export type Matrix = { times: number[][]; distances: number[][] };
export type RoadPath = { distance: number; seconds: number; coordinates: Point[] };
export interface RoadProvider {
  readonly name: string;
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
export class GraphHopper implements RoadProvider {
  readonly name = "GraphHopper";
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
      out_arrays: ["times", "distances"], fail_fast: true });
    for (const key of ["times", "distances"]) {
      if (!Array.isArray(data[key]) || data[key].length !== points.length ||
        data[key].some((row: unknown) => !Array.isArray(row) || row.length !== points.length || !row.every(number)))
        throw new RoutingError("ROUTE_UNREACHABLE");
    }
    return { times: data.times, distances: data.distances }; // seconds, meters
  }
  async route(points: Point[]): Promise<RoadPath> {
    const request = points.length === 1 ? [points[0], points[0]] : points;
    const data = await this.post("route", { profile: "car", points: request, points_encoded: false,
      instructions: false, calc_points: true, elevation: false });
    const path = data.paths?.[0];
    if (!path || !number(path.distance) || !number(path.time) ||
      !Array.isArray(path.points?.coordinates) || path.points.coordinates.length === 0 ||
      !path.points.coordinates.every(point) || !Array.isArray(path.snapped_waypoints?.coordinates) ||
      path.snapped_waypoints.coordinates.length !== request.length || !path.snapped_waypoints.coordinates.every(point))
      throw new RoutingError("ROUTE_UNREACHABLE");
    const coordinates: Point[] = path.points.coordinates.map((p: Point) => [p[0], p[1]]);
    if (coordinates.length === 1) coordinates.push([...coordinates[0]]); // verified zero-length provider path
    return { distance: path.distance, seconds: path.time / 1000, coordinates };
  }
}

