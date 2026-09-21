import { draftFrom, emptyDraft, failure, fields, manages, RegistryError, type Draft, type Failure, type Hydrant, type HydrantService, type HydrantType, type Organization, type Status } from './domain.ts';
export type Mode = 'list' | 'detail' | 'new' | 'edit';
export type RegistryState = { organizations: Organization[]; org?: Organization; rows: Hydrant[]; types: HydrantType[]; selected?: Hydrant; draft?: Draft; loading: boolean; busy: boolean; error?: Failure; conflict: boolean; reviewed: boolean; confirm: boolean; inactive: boolean; more: boolean; saved?: Hydrant };
const initial = (): RegistryState => ({ organizations: [], rows: [], types: [], loading: true, busy: false, conflict: false, reviewed: false, confirm: false, inactive: false, more: false });
// UI state only. Authorization is always enforced by RLS/RPCs.
export class RegistryController {
  service: HydrantService; mode: Mode; id?: string; preferred?: string;
  private value = initial(); private listeners = new Set<() => void>(); private generation = 0; private running = false;
  constructor(service: HydrantService, mode: Mode, id?: string, preferred?: string) { this.service = service; this.mode = mode; this.id = id; this.preferred = preferred; }
  snapshot = () => this.value;
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  private set(update: Partial<RegistryState>) { this.value = { ...this.value, ...update }; this.listeners.forEach(l => l()); }
  clear() { this.generation++; this.running = false; this.value = { ...initial(), loading: false, error: 'expired' }; this.listeners.forEach(l => l()); }
  async load(orgId = this.value.org?.id ?? this.preferred) {
    if (this.running || this.value.busy) return;
    this.running = true; const stamp = this.generation; const old = this.value;
    this.set({ loading: true, error: undefined });
    try {
      const organizations = await this.service.organizations();
      if (stamp !== this.generation) return;
      const org = orgId ? organizations.find(o => o.id === orgId) : organizations[0];
      if (!org) { this.set({ ...initial(), loading: false, organizations, error: 'forbidden' }); return; }
      const inactive = manages(org.role) && old.inactive;
      const types = await this.service.types(org.id);
      const rows = this.mode === 'list' ? await this.service.list(org.id, inactive) : [];
      const selected = this.id ? await this.service.get(org.id, this.id) : undefined;
      if (stamp !== this.generation) return;
      if (this.mode === 'edit' && !manages(org.role)) throw new RegistryError('forbidden');
      const draft = this.mode === 'new' ? old.draft ?? emptyDraft(crypto.randomUUID()) : this.mode === 'edit' && selected ? old.draft ?? draftFrom(selected) : undefined;
      this.set({ organizations, org, types, rows, selected, draft, inactive, more: rows.length === 50, loading: false });
    } catch (e) { if (stamp === this.generation) this.fail(e, true); }
    finally { if (stamp === this.generation) this.running = false; }
  }
  private fail(e: unknown, reading = false) {
    const error = failure(e);
    const locked = ['expired', 'forbidden', 'unavailable'].includes(error);
    this.set({ error, loading: false, busy: false, ...(reading ? { rows: [], types: [], selected: undefined } : {}), ...(locked ? { org: undefined, selected: undefined, draft: undefined, rows: [], types: [], confirm: false } : {}) });
  }
  async switchOrganization(id: string) {
    if (this.value.busy || this.running || this.mode !== 'list') return;
    this.generation++; this.value = { ...initial(), loading: false };
    this.listeners.forEach(l => l()); await this.load(id);
  }
  async includeInactive(value: boolean) { if (!manages(this.value.org?.role) || this.running || this.value.busy) return; this.set({ inactive: value }); await this.load(); }
  async more() {
    const s = this.value; if (this.running || s.busy || !s.org || !s.more) return;
    this.running = true; const stamp = this.generation; this.set({ loading: true, error: undefined });
    try { const page = await this.service.list(s.org.id, s.inactive, s.rows.at(-1)?.id); if (stamp === this.generation) this.set({ rows: [...s.rows, ...page.filter(h => !s.rows.some(old => old.id === h.id))], more: page.length === 50, loading: false }); }
    catch (e) { if (stamp === this.generation) this.fail(e); }
    finally { if (stamp === this.generation) this.running = false; }
  }
  change(draft: Draft) { if (!this.value.busy && !this.running && draft.id === this.value.draft?.id) this.set({ draft, error: undefined }); }
  review() { const s = this.value; if (s.conflict && s.selected && s.draft && !s.loading && !s.busy) this.set({ draft: { ...s.draft, version: s.selected.version }, reviewed: true }); }
  async save() {
    const s = this.value;
    if (this.running || s.busy || !s.org?.active || !s.draft || (s.conflict && !s.reviewed) || (this.mode === 'edit' && !manages(s.org.role))) return;
    try {
      const f = fields(s.draft);
      if (!s.types.some(t => t.id === f.hydrant_type_id && t.active) && !(this.mode === 'edit' && s.selected?.hydrant_type_id === f.hydrant_type_id)) throw new RegistryError('type');
      await this.mutate(() => this.mode === 'new' ? this.service.create(s.org!.id, s.draft!.id, f) : this.service.update(s.org!.id, s.draft!.id, f, s.draft!.version!));
    } catch (e) { this.fail(e); }
  }
  async status(status: Status) {
    const s = this.value; if (!s.org?.active || !s.selected || (!s.selected.active && !manages(s.org.role))) return;
    await this.mutate(() => this.service.status(s.org!.id, s.selected!.id, status, s.selected!.version));
  }
  async requestActive() {
    const s = this.value; if (!s.org?.active || !s.selected || !manages(s.org.role) || this.running || s.busy) return;
    if (s.selected.active) this.set({ confirm: true }); else await this.setActive(true);
  }
  dismiss() { if (!this.value.busy) this.set({ confirm: false }); }
  async confirm() { if (this.value.confirm) await this.setActive(false); }
  private async setActive(active: boolean) {
    const s = this.value; if (!s.org?.active || !s.selected || !manages(s.org.role)) return;
    await this.mutate(() => this.service.active(s.org!.id, s.selected!.id, active, s.selected!.version));
  }
  private async mutate(action: () => Promise<Hydrant>) {
    const old = this.value; if (old.busy || this.running || old.saved) return;
    const stamp = this.generation; this.set({ busy: true, error: undefined });
    try {
      const selected = await action(); if (stamp !== this.generation) return;
      this.set({ selected, busy: false, confirm: false, conflict: false, reviewed: false, ...(this.mode === 'new' || this.mode === 'edit' ? { saved: selected, draft: undefined } : {}) });
    } catch (e) {
      if (stamp !== this.generation) return;
      if (failure(e) === 'conflict' && old.selected && old.org) {
        this.set({ conflict: true, reviewed: false, confirm: false, selected: undefined });
        try { const selected = await this.service.get(old.org.id, old.selected.id); if (stamp === this.generation) this.set({ selected, busy: false }); }
        catch (reload) { if (stamp === this.generation) this.fail(reload); }
      } else this.fail(e);
    }
  }
}
