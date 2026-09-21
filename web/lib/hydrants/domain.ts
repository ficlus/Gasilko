export const statuses = ['WORKING', 'NOT_WORKING', 'NEEDS_INSPECTION', 'UNKNOWN'] as const;
export type Status = typeof statuses[number];
export type Role = 'FIREFIGHTER' | 'MANAGER' | 'ADMIN';
export type Organization = { id: string; name: string; active: boolean; role: Role };
export type HydrantType = { id: string; organization_id: string | null; code: string; name: string; active: boolean };
export type Hydrant = { id: string; organization_id: string; code: string | null; hydrant_type_id: string; status: Status; latitude: number | null; longitude: number | null; address: string | null; location_description: string | null; notes: string | null; inspection_interval_months: number | null; active: boolean; version: number; created_by: string };
export type Fields = Pick<Hydrant, 'hydrant_type_id' | 'latitude' | 'longitude' | 'address' | 'location_description' | 'notes' | 'inspection_interval_months' | 'status'>;
export type Draft = { id: string; type: string; latitude: string; longitude: string; address: string; description: string; notes: string; interval: string; status: Status; version?: number };
export type Failure = 'network' | 'expired' | 'forbidden' | 'validation' | 'conflict' | 'server' | 'unavailable' | 'location' | 'coordinates' | 'interval' | 'type';
export class RegistryError extends Error { reason: Failure; constructor(reason: Failure) { super(reason); this.reason = reason; } }
export function failure(error: unknown): Failure { return error instanceof RegistryError ? error.reason : error instanceof TypeError ? 'network' : 'server'; }
export function manages(role?: Role) { return role === 'MANAGER' || role === 'ADMIN'; }
export function emptyDraft(id: string): Draft { return { id, type: '', latitude: '', longitude: '', address: '', description: '', notes: '', interval: '', status: 'UNKNOWN' }; }
export function draftFrom(h: Hydrant): Draft { return { id: h.id, type: h.hydrant_type_id, latitude: h.latitude?.toString() ?? '', longitude: h.longitude?.toString() ?? '', address: h.address ?? '', description: h.location_description ?? '', notes: h.notes ?? '', interval: h.inspection_interval_months?.toString() ?? '', status: h.status, version: h.version }; }
export function fields(d: Draft): Fields {
  const text = (s: string) => s.trim() || null;
  const lat = text(d.latitude), lon = text(d.longitude);
  const decimal = (s: string) => /^[+-]?(?:\d+(?:[.,]\d*)?|[.,]\d+)$/.test(s) ? Number(s.replace(',', '.')) : NaN;
  const latitude = lat === null ? null : decimal(lat), longitude = lon === null ? null : decimal(lon);
  if ((lat === null) !== (lon === null) || (latitude !== null && (!Number.isFinite(latitude) || Math.abs(latitude) > 90)) || (longitude !== null && (!Number.isFinite(longitude) || Math.abs(longitude) > 180))) throw new RegistryError('coordinates');
  if (latitude === null && !text(d.address) && !text(d.description)) throw new RegistryError('location');
  if (!d.type) throw new RegistryError('type');
  const interval = text(d.interval);
  if (interval && (!/^\d+$/.test(interval) || Number(interval) < 1 || Number(interval) > 2147483647)) throw new RegistryError('interval');
  if (!statuses.includes(d.status)) throw new RegistryError('validation');
  return { hydrant_type_id: d.type, latitude, longitude, address: text(d.address), location_description: text(d.description), notes: text(d.notes), inspection_interval_months: interval ? Number(interval) : null, status: d.status };
}
export function payload(f: Fields, create: boolean) {
  const common = { latitude: f.latitude, longitude: f.longitude, address: f.address, location_description: f.location_description, notes: f.notes, inspection_interval_months: f.inspection_interval_months };
  return create ? { ...common, status: f.status } : { ...common, hydrant_type_id: f.hydrant_type_id };
}
export interface HydrantService {
  organizations(): Promise<Organization[]>;
  types(org: string): Promise<HydrantType[]>;
  list(query: import('./query.ts').HydrantQuery): Promise<Hydrant[]>;
  get(org: string, id: string): Promise<Hydrant>;
  create(org: string, id: string, fields: Fields): Promise<Hydrant>;
  update(org: string, id: string, fields: Fields, version: number): Promise<Hydrant>;
  status(org: string, id: string, status: Status, version: number): Promise<Hydrant>;
  active(org: string, id: string, active: boolean, version: number): Promise<Hydrant>;
}
