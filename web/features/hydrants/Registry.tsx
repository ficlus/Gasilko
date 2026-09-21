'use client';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { dictionary, type Locale } from '../../lib/i18n';
import { browserClient } from '../../lib/supabase/browser';
import { hydrantService } from '../../lib/hydrants/service';
import { RegistryController, type Mode } from '../../lib/hydrants/controller';
import { manages, statuses, type Draft, type Failure, type Hydrant, type HydrantType, type Status } from '../../lib/hydrants/domain';
import { defaultFilters, hasFilters, queryString, type RegistryFilters } from '../../lib/hydrants/query';
type Text = ReturnType<typeof dictionary>;
export function statusLabel(t: Text, status: Status) { return { WORKING: t.hWorking, NOT_WORKING: t.hNotWorking, NEEDS_INSPECTION: t.hNeedsInspection, UNKNOWN: t.hUnknown }[status]; }
function errorLabel(t: Text, error: Failure) { return { network: t.hNetwork, expired: t.hExpired, forbidden: t.hForbidden, validation: t.hValidation, conflict: t.hConflict, server: t.hServer, unavailable: t.hUnavailable, location: t.hLocation, coordinates: t.hCoordinates, interval: t.hInvalidInterval, type: t.hInvalidType }[error]; }
function typeLabel(t: Text, type?: HydrantType) {
  if (!type) return t.hMissing;
  const seeded: Record<string, string> = { ABOVE_GROUND: t.hAboveGround, UNDERGROUND: t.hUnderground, WALL: t.hWall, OTHER: t.hOther };
  return (type.organization_id === null ? seeded[type.code] : undefined) ?? type.name;
}
export function Registry({ locale, mode, id, org, filters }: { locale: Locale; mode: Mode; id?: string; org?: string; filters: RegistryFilters }) {
  const router = useRouter();
  const [controller] = useState(() => { const client = browserClient(); return client ? new RegistryController(hydrantService(client), mode, id, org, filters) : null; });
  useEffect(() => {
    if (!controller) return;
    void controller.load();
    const c = browserClient();
    const listener = c?.auth.onAuthStateChange(event => { if (event === 'SIGNED_OUT') controller.clear(); });
    return () => { listener?.data.subscription.unsubscribe(); controller.clear(); };
  }, [controller]);
  return controller ? <RegistryView locale={locale} controller={controller} switchOrg={id => router.push(`/${locale}/hydrants` + queryString(id, defaultFilters()))}/> : <p role="alert">{dictionary(locale).configuration}</p>;
}
function DetailFields({ h, types, t }: { h: Hydrant; types: HydrantType[]; t: Text }) {
  const values: [string, string | number | null][] = [[t.hCode, h.code], [t.hType, typeLabel(t, types.find(v => v.id === h.hydrant_type_id))], [t.hStatus, statusLabel(t, h.status)], [t.hLatitude, h.latitude], [t.hLongitude, h.longitude], [t.hAddress, h.address], [t.hDescription, h.location_description], [t.hNotes, h.notes], [t.hInterval, h.inspection_interval_months], [t.hActive, h.active ? t.hActive : t.hInactive], [t.hVersion, h.version]];
  return <dl className="hydrant-fields">{values.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value ?? t.hMissing}</dd></div>)}</dl>;
}
function Confirmation({ controller, t, busy, error }: { controller: RegistryController; t: Text; busy: boolean; error?: Failure }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const message = useRef<HTMLParagraphElement>(null);
  useEffect(() => { const el = dialog.current; el?.showModal(); return () => el?.close(); }, []);
  useEffect(() => { if (error) message.current?.focus(); }, [error]);
  return <dialog ref={dialog} aria-labelledby="deactivate-heading" onCancel={e => { e.preventDefault(); controller.dismiss(); }}>
    <h2 id="deactivate-heading">{t.hDeactivate}</h2><p>{t.hConfirm}</p>
    {error && <p ref={message} tabIndex={-1} role="alert">{errorLabel(t,error)}</p>}
    <div className="actions"><button autoFocus disabled={busy} onClick={() => controller.dismiss()}>{t.hCancel}</button><button disabled={busy} onClick={() => void controller.confirm()}>{busy ? t.hSaving : t.hDeactivate}</button></div>
  </dialog>;
}
export function RegistryView({ locale, controller, switchOrg }: { locale: Locale; controller: RegistryController; switchOrg?: (id: string) => void }) {
  const s = useSyncExternalStore(controller.subscribe, controller.snapshot, controller.snapshot);
  const t = dictionary(locale), root = `/${locale}/hydrants`, query = s.org ? queryString(s.org.id,s.filters) : '';
  const blocked = s.loading || s.busy, manager = manages(s.org?.role), writable = !!s.org?.active;
  const alert = useRef<HTMLParagraphElement>(null);
  useEffect(() => { if (s.error || s.conflict) alert.current?.focus(); }, [s.error, s.conflict]);
  const current = s.selected;
  return <section className="registry" aria-busy={blocked}>
    <div className="registry-toolbar"><label>{t.selectOrganization}<select value={s.org?.id ?? ''} disabled={blocked || controller.mode !== 'list' || s.organizations.length < 2} onChange={e => switchOrg ? switchOrg(e.target.value) : void controller.switchOrganization(e.target.value)}>
      {!s.org && <option value="">{t.selectOrganization}</option>}{s.organizations.map(o => <option key={o.id} value={o.id}>{o.name}</option>)}</select></label>
      <button disabled={blocked || !!s.saved} onClick={() => void controller.load()}>{s.error ? t.hRetry : t.hRefresh}</button>
      {controller.mode !== 'list' && !s.busy && <Link href={root + query}>{t.hBack}</Link>}
    </div>
    {s.org && !writable && <p>{t.hReadOnly}</p>}
    {s.loading && <p role="status">{t.loading}</p>}{s.busy && <p role="status">{t.hSaving}</p>}
    {(s.error || s.conflict) && <p id="registry-error" role="alert" tabIndex={-1} ref={alert}>{s.conflict && t.hConflict} {s.error && errorLabel(t, s.error)}</p>}
    {s.saved ? <><p role="status">{t.hSaved}</p><DetailFields h={s.saved} types={s.types} t={t}/><Link href={`${root}/${s.saved.id}${query}`}>{t.hDetails}</Link></> : <>
    {controller.mode === 'list' && s.org && <>
      <div className="actions">{writable && !blocked && <Link href={root + '/new' + query}>{t.hAdd}</Link>}
      </div>
      <form method="get" action={root} className="registry-filters"><fieldset disabled={blocked}><legend>{t.hFilters}</legend><input type="hidden" name="org" value={s.org.id}/>
        <label>{t.hSearch}<input name="q" type="search" maxLength={200} defaultValue={s.filters.search} placeholder={t.hSearchHint}/></label>
        <label>{t.hType}<select name="type" defaultValue={s.filters.typeId ?? ''}><option value="">{t.hAll}</option>
          {s.filters.typeId && !s.types.some(v => v.id === s.filters.typeId) && <option value={s.filters.typeId}>{t.hMissing}</option>}
          {s.types.map(v => <option key={v.id} value={v.id}>{typeLabel(t,v)} ({v.organization_id ? t.hLocal : t.hGlobal}){!v.active ? ` — ${t.hInactive}` : ''}</option>)}</select></label>
        <label>{t.hStatus}<select name="status" defaultValue={s.filters.status ?? ''}><option value="">{t.hAll}</option>{statuses.map(v => <option key={v} value={v}>{statusLabel(t,v)}</option>)}</select></label>
        {manager && <label>{t.hActiveState}<select name="active" defaultValue={s.filters.active}><option value="active">{t.hActiveOnly}</option><option value="inactive">{t.hInactiveOnly}</option><option value="all">{t.hAll}</option></select></label>}
        <button>{t.hSearch}</button><Link href={root + queryString(s.org.id,defaultFilters())}>{t.hClearFilters}</Link>
      </fieldset></form>
      {!s.loading && !s.error && s.rows.length === 0 && <p>{hasFilters(s.filters) || s.filters.after ? t.hNoMatches : t.hEmpty}</p>}
      {s.rows.length > 0 && <div className="registry-table" tabIndex={0} role="region" aria-label={t.hTitle}><table><caption>{s.org.name} — {t.hTitle}</caption><thead><tr>{[t.hCode,t.hType,t.hStatus,t.hAddress,t.hActive].map(label => <th scope="col" key={label}>{label}</th>)}</tr></thead><tbody>{s.rows.map(h => <tr key={h.id}><th scope="row"><Link href={`${root}/${h.id}${query}`}>{h.code ?? t.hMissing}</Link></th><td>{typeLabel(t,s.types.find(v => v.id === h.hydrant_type_id))}</td><td>{statusLabel(t,h.status)}</td><td>{h.address || h.location_description || (h.latitude !== null ? `${h.latitude}, ${h.longitude}` : t.hMissing)}</td><td>{h.active ? t.hActive : t.hInactive}</td></tr>)}</tbody></table></div>}
      <div className="actions">{s.filters.after && <Link href={root + queryString(s.org.id,{...s.filters,after:undefined})}>{t.hFirstPage}</Link>}
      {s.more && !blocked && <Link href={root + queryString(s.org.id,{...s.filters,after:s.rows.at(-1)?.id})}>{t.hNextPage}</Link>}</div>
    </>}
    {current && (controller.mode === 'detail' || s.conflict) && <>
      <h2>{s.conflict ? t.hLatest : t.hDetails}: {current.code ?? t.hMissing}</h2><DetailFields h={current} types={s.types} t={t}/>
      {controller.mode === 'detail' && <div className="registry-detail-actions">
        {writable && (current.active || manager) && <StatusForm key={`${current.id}/${current.version}/${s.conflict}`} current={current.status} t={t} blocked={blocked} save={status => void controller.status(status)}/>}
        {manager && writable && <div className="actions">{!blocked && <Link href={`${root}/${current.id}/edit${query}`}>{t.hEdit}</Link>}<button disabled={blocked} onClick={() => void controller.requestActive()}>{current.active ? t.hDeactivate : t.hReactivate}</button></div>}
      </div>}
    </>}
    {s.draft && s.org && (controller.mode === 'new' || manager) && <>
      {s.conflict && <><h2>{t.hDraft}</h2>{!s.reviewed && <button disabled={blocked || !current} onClick={() => controller.review()}>{t.hReview}</button>}</>}
      <HydrantForm draft={s.draft} types={s.types} current={current} t={t} disabled={blocked || !writable || (s.conflict && !s.reviewed)} error={s.error} change={d => controller.change(d)} save={() => void controller.save()}/>
      {!s.busy && <Link href={current ? `${root}/${current.id}${query}` : root + query}>{t.hCancel}</Link>}
    </>}
    </>}
    {s.confirm && <Confirmation controller={controller} t={t} busy={s.busy} error={s.error}/>}
  </section>;
}
function StatusForm({ current, t, blocked, save }: { current: Status; t: Text; blocked: boolean; save: (status: Status) => void }) {
  const [status, setStatus] = useState(current);
  return <form onSubmit={e => { e.preventDefault(); save(status); }}><label>{t.hStatus}<select disabled={blocked} value={status} onChange={e => setStatus(e.target.value as Status)}>{statuses.map(v => <option value={v} key={v}>{statusLabel(t,v)}</option>)}</select></label><button disabled={blocked}>{t.hSave}</button></form>;
}
function HydrantForm({ draft, types, current, t, disabled, error, change, save }: { draft: Draft; types: HydrantType[]; current?: Hydrant; t: Text; disabled: boolean; error?: Failure; change: (draft: Draft) => void; save: () => void }) {
  const input = (key: 'latitude' | 'longitude' | 'address' | 'description' | 'notes' | 'interval', label: string, invalid: boolean) => <label key={key} htmlFor={`hydrant-${key}`}>{label}{['description','notes'].includes(key) ? <textarea id={`hydrant-${key}`} value={draft[key]} onChange={e => change({ ...draft, [key]: e.target.value })} aria-invalid={invalid || undefined} aria-describedby={invalid ? 'registry-error' : undefined}/> : <input id={`hydrant-${key}`} value={draft[key]} inputMode={key === 'interval' ? 'numeric' : 'text'} onChange={e => change({ ...draft, [key]: e.target.value })} aria-invalid={invalid || undefined} aria-describedby={invalid ? 'registry-error' : undefined}/>}</label>;
  return <form onSubmit={e => { e.preventDefault(); save(); }} noValidate><p>{t.hOnline}</p><fieldset disabled={disabled}><legend>{draft.version === undefined ? t.hAdd : t.hEdit}</legend>
    <label htmlFor="hydrant-type">{t.hType}<select id="hydrant-type" value={draft.type} aria-invalid={error === 'type' || undefined} aria-describedby={error === 'type' ? 'registry-error' : undefined} onChange={e => change({ ...draft, type: e.target.value })}><option value="">{t.hType}</option>
      {current && !types.some(v => v.id === current.hydrant_type_id && v.active) && <option value={current.hydrant_type_id}>{typeLabel(t,types.find(v => v.id === current.hydrant_type_id))} ({t.hInactive})</option>}
      {types.filter(v => v.active).map(v => <option value={v.id} key={v.id}>{typeLabel(t,v)} ({v.organization_id ? t.hLocal : t.hGlobal})</option>)}</select></label>
    {input('latitude',t.hLatitude,error === 'coordinates' || error === 'location')}{input('longitude',t.hLongitude,error === 'coordinates' || error === 'location')}{input('address',t.hAddress,error === 'location')}{input('description',t.hDescription,error === 'location')}
    {draft.version === undefined && <label>{t.hStatus}<select value={draft.status} onChange={e => change({ ...draft, status: e.target.value as Status })}>{statuses.map(v => <option key={v} value={v}>{statusLabel(t,v)}</option>)}</select></label>}
    {input('notes',t.hNotes,false)}{input('interval',t.hInterval,error === 'interval')}<button>{t.hSave}</button>
  </fieldset></form>;
}
