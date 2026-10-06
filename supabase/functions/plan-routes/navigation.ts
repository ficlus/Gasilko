import { RoutingError, type Point, type RoadProvider } from "./provider.ts";

type Item = { id: string; hydrant: string; team: string; code: string | null; latitude: number; longitude: number };
type Input = { id: string; organization: string; version: number; teams: string[]; items: Item[];
  latitude: number | null; longitude: number | null; returnToStart: boolean };

/** Read-only route from foreground GPS. Selected-team authorization is performed by the existing RPC. */
export async function navigationRoute(input: Input, snapshot: any, origin: Point, provider: RoadProvider, bearing?: number) {
  if (input.teams.length !== 1 || !input.items.length) throw new RoutingError("ROUTE_ASSIGNMENTS");
  const order = new Map<string, number>();
  for (const row of snapshot.items ?? []) if (row.plan_id === input.id && row.team_id === input.teams[0] &&
    Number.isInteger(row.route_order) && row.route_order > 0) order.set(row.id, row.route_order);
  // Keep the authoritative remaining stop order. No matrix, optimization or team mutation here.
  const actionable = new Set((snapshot.items ?? []).filter((i: any) => i.plan_id === input.id && i.active && !i.inspection_id && !i.skipped_at && i.team_id === input.teams[0]).map((i: any) => i.id));
  const items = input.items.filter(i => actionable.has(i.id)).sort((a, b) => (order.get(a.id) ?? Infinity) - (order.get(b.id) ?? Infinity) ||
    a.hydrant.localeCompare(b.hydrant));
  if (!items.length) throw new RoutingError("ROUTE_ASSIGNMENTS");
  const points: Point[] = [origin, ...items.map(i => [i.longitude, i.latitude] as Point)];
  if (input.returnToStart && input.latitude !== null && input.longitude !== null) points.push([input.longitude, input.latitude]);
  if (points.length > 100) throw new RoutingError("ROUTE_LIMIT");
  const snapped = await provider.snap(points);
  // Keep the actual vehicle origin for directional snapping; hydrants still use road access points.
  snapped[0] = origin;
  const path = await provider.route(snapped, true, bearing);
  const stops = items.map((item, index) => ({ ...item, order: index + 1, snapped: path.snapped[index + 1] }));
  const result = { plan: input.id, team: input.teams[0], version: input.version, provider: provider.name,
    distance: path.distance, seconds: path.seconds, coordinates: path.coordinates, legs: path.legs ?? [], stops };
  if (JSON.stringify(result).length > 4_000_000) throw new RoutingError("ROUTE_LIMIT");
  return result;
}
