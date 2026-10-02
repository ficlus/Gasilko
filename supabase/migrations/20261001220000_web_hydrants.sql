-- M8.2: bounded hierarchy reads, exact-organization web writes, paper inspections.
-- Existing Android RPC signatures, membership helpers and photo paths stay intact.
create function private.web_read(org uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.web_admin_scope() where organization_id=org);
$$;
create function private.web_subtree(root uuid) returns setof uuid
language sql stable security definer set search_path='' as $$
 with recursive tree(id) as (
  select root where private.web_read(root)
  union select e.child_id from tree t join private.organization_read_edges() e on e.parent_id=t.id
 ) select id from tree where private.web_read(id);
$$;
create policy hydrants_web_read on public.hydrants for select to authenticated using(private.web_read(organization_id));
create policy types_web_read on public.hydrant_types for select to authenticated using(private.web_read(organization_id));
create policy inspections_web_read on public.inspections for select to authenticated using(private.web_read(organization_id));
-- Storage read helper is shared; write helpers retain EXACT membership semantics.
create or replace function private.photo_visible(org uuid, hydrant uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.hydrants h join public.organizations o on o.id=h.organization_id and o.active
 where h.id=hydrant and h.organization_id=org and
 (private.web_read(org) or (private.is_organization_member(org) and
 (h.active or private.has_organization_role(org,array['MANAGER','ADMIN']::text[])))));
$$;

alter table public.inspections
 add column source text not null default 'ANDROID_FIELD' check(source in ('ANDROID_FIELD','WEB_MANUAL')),
 add column performer_id uuid references public.profiles(id),
 add column performer_name text,
 add column performer_organization text,
 add column corrects_inspection_id uuid references public.inspections(id),
 add constraint manual_performer check(source<>'WEB_MANUAL' or performer_id is not null or coalesce(length(btrim(performer_name)),0)>0);
-- completed_at is the existing authoritative performed time; inspector_id remains
-- the authenticated entry actor for compatibility. No historical rows are rewritten.
create index inspections_valid_date on public.inspections(organization_id,hydrant_id,completed_at desc,id desc)
 where result<>'NOT_INSPECTED';
create index hydrants_viewport on public.hydrants(organization_id,latitude,longitude) where latitude is not null;
create index hydrants_web_code on public.hydrants(organization_id,code,id);
create index hydrant_photos_preview on public.hydrant_photos(organization_id,hydrant_id,captured_at desc,id desc)
 where active and uploaded_at is not null;
create index audit_web_hydrant on public.audit_log(organization_id,entity_id,created_at desc);
create unique index audit_web_operation_receipt on public.audit_log(entity_id) where entity_type='web_hydrant_operations';

create view private.web_hydrant_rows as
 select h.*,o.name organization_name,t.name type_name,t.code type_code,t.organization_id type_organization_id,
 latest.completed_at last_inspection_at,latest.id last_inspection_id,
 due.next_due,
 case when due.next_due is null then 'NEVER_INSPECTED' when due.next_due<statement_timestamp() then 'OVERDUE'
 when due.next_due<=statement_timestamp()+interval '30 days' then 'DUE_SOON' else 'CURRENT' end due_state,
 photo.storage_path preview_path
 from public.hydrants h join public.organizations o on o.id=h.organization_id
 join public.hydrant_types t on t.id=h.hydrant_type_id
 left join lateral(select i.id,i.completed_at from public.inspections i where i.organization_id=h.organization_id
 and i.hydrant_id=h.id and i.result<>'NOT_INSPECTED' order by i.completed_at desc,i.id desc limit 1) latest on true
 cross join lateral(select latest.completed_at + make_interval(months=>coalesce(h.inspection_interval_months,o.inspection_interval_months)) next_due) due
 left join lateral(select p.storage_path from public.hydrant_photos p where p.organization_id=h.organization_id
 and p.hydrant_id=h.id and p.active and p.uploaded_at is not null order by p.captured_at desc,p.id desc limit 1) photo on true;
revoke all on private.web_hydrant_rows from public,anon,authenticated,service_role;

create function public.web_hydrants(root uuid, filters jsonb default '{}', page integer default 0,
 sort_by text default 'code', bounds jsonb default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb; cap integer:=case when bounds is null then 50 else 2000 end; needle text:=lower(btrim(coalesce(filters->>'search','')));
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if page is null or page<0 or page>20000 or sort_by not in ('code','updated','due') or length(needle)>200
 or (bounds is not null and (jsonb_array_length(bounds)<>4 or (bounds->>0)::numeric < -180 or (bounds->>2)::numeric>180
 or (bounds->>1)::numeric < -90 or (bounds->>3)::numeric>90 or (bounds->>0)::numeric>(bounds->>2)::numeric
 or (bounds->>1)::numeric>(bounds->>3)::numeric)) then raise exception 'INVALID_QUERY' using errcode='22023'; end if;
 with rows as (
 select r.* from private.web_hydrant_rows r where r.organization_id in(select private.web_subtree(root))
 and (nullif(filters->>'organization','') is null or r.organization_id=(filters->>'organization')::uuid)
 and (not filters ? 'hidden' or not (filters->'hidden') ? r.organization_id::text)
 and (nullif(filters->>'type','') is null or r.hydrant_type_id=(filters->>'type')::uuid)
 and (nullif(filters->>'status','') is null or r.status=filters->>'status')
 and (coalesce(filters->>'active','active')='all' or r.active=(coalesce(filters->>'active','active')='active'))
 and (nullif(filters->>'due','') is null or r.due_state=filters->>'due')
 and (needle='' or strpos(lower(coalesce(r.code,'')),needle)>0 or strpos(lower(coalesce(r.address,'')),needle)>0
 or strpos(lower(coalesce(r.location_description,'')),needle)>0)
 and (bounds is null or (r.longitude between (bounds->>0)::numeric and (bounds->>2)::numeric
 and r.latitude between (bounds->>1)::numeric and (bounds->>3)::numeric))
 order by case when sort_by='updated' then r.updated_at end desc,
 case when sort_by='due' then r.next_due end asc nulls first, r.code,r.id
 limit cap+1 offset case when bounds is null then page*cap else 0 end
 ) select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(q)) from (select * from rows limit cap) q),'[]'),
 'more',(select count(*)>cap from rows)) into result;
 return result;
end;
$$;
create function public.web_hydrant_context(root uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('organizations',(select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,
 'writable',private.can_manage_organization(o.id)) order by o.name,o.id),'[]') from public.organizations o where o.id in(select private.web_subtree(root))),
 'types',(select coalesce(jsonb_agg(to_jsonb(t) order by t.name,t.id),'[]') from public.hydrant_types t
 where t.organization_id is null or t.organization_id in(select private.web_subtree(root))));
end;
$$;
create function public.web_hydrant_dashboard(root uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('metrics',(select jsonb_build_object('total',count(*),'WORKING',count(*) filter(where status='WORKING'),
 'NEEDS_INSPECTION',count(*) filter(where status='NEEDS_INSPECTION'),'NOT_WORKING',count(*) filter(where status='NOT_WORKING'),
 'OVERDUE',count(*) filter(where due_state='OVERDUE'),'NEVER_INSPECTED',count(*) filter(where due_state='NEVER_INSPECTED'))
 from private.web_hydrant_rows where active and organization_id in(select private.web_subtree(root))),
 'inspections',(select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (select i.id,i.hydrant_id,i.result,i.completed_at,h.code,o.name organization_name
 from public.inspections i join public.hydrants h on h.id=i.hydrant_id join public.organizations o on o.id=i.organization_id
 where i.organization_id in(select private.web_subtree(root)) order by i.completed_at desc,i.id desc limit 10) q),
 'changes',(select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (select h.id,h.code,h.status,h.updated_at,o.name organization_name
 from public.hydrants h join public.organizations o on o.id=h.organization_id where h.organization_id in(select private.web_subtree(root))
 order by h.updated_at desc,h.id desc limit 10) q));
end;
$$;

-- Paper documents have their own metadata and private bucket; never condition photos.
create table public.inspection_documents (
 id uuid primary key, organization_id uuid not null, hydrant_id uuid not null, inspection_id uuid not null,
 mime_type text not null check(mime_type in ('application/pdf','image/jpeg','image/webp')),
 byte_size bigint not null check(byte_size between 1 and 10485760), sha256 text not null check(sha256~'^[0-9a-f]{64}$'),
 created_by uuid not null references public.profiles(id), created_at timestamptz not null default clock_timestamp(),
 uploaded_at timestamptz,
 storage_path text generated always as ('reports/'||organization_id::text||'/'||inspection_id::text||'/'||id::text||
 case mime_type when 'application/pdf' then '.pdf' when 'image/jpeg' then '.jpg' else '.webp' end) stored unique,
 foreign key(inspection_id,hydrant_id,organization_id) references public.inspections(id,hydrant_id,organization_id)
);
create index inspection_documents_parent on public.inspection_documents(organization_id,inspection_id,created_at desc);
alter table public.inspection_documents enable row level security;
revoke all on public.inspection_documents from public,anon,authenticated,service_role;
grant select on public.inspection_documents to authenticated;
create policy documents_read on public.inspection_documents for select to authenticated using(
 private.web_read(organization_id) and (uploaded_at is not null or created_by=auth.uid()));
create trigger documents_guard after update or delete on public.inspection_documents for each row execute function private.photo_receipt_guard();
create trigger documents_no_truncate before truncate on public.inspection_documents for each statement execute function private.photo_receipt_guard();
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('inspection-documents','inspection-documents',false,10485760,array['application/pdf','image/jpeg','image/webp']);
create function private.document_object(path text, writing boolean) returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare d public.inspection_documents;
begin
 select * into d from public.inspection_documents where storage_path=path;
 if not found then return false; end if;
 if not writing then return private.web_read(d.organization_id) and (d.uploaded_at is not null or d.created_by=auth.uid()); end if;
 perform private.authorize_hydrant_write(d.organization_id,array['MANAGER','ADMIN']);
 return d.created_by=auth.uid() and d.uploaded_at is null;
end;
$$;
create policy documents_object_read on storage.objects for select to authenticated
 using(bucket_id='inspection-documents' and private.document_object(name,false));
create policy documents_object_insert on storage.objects for insert to authenticated
 with check(bucket_id='inspection-documents' and private.document_object(name,true));

create function public.web_document(document jsonb, confirm boolean default false) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare d public.inspection_documents; receipt public.inspection_documents; actor uuid; meta jsonb;
begin
 select * into d from jsonb_populate_record(null::public.inspection_documents,document);
 actor:=private.authorize_hydrant_write(d.organization_id,array['MANAGER','ADMIN']);
 if not exists(select 1 from public.inspections where id=d.inspection_id and hydrant_id=d.hydrant_id
 and organization_id=d.organization_id and source='WEB_MANUAL') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(d.id::text,8202));
 select * into receipt from public.inspection_documents where id=d.id;
 if found then
 if (receipt.organization_id,receipt.hydrant_id,receipt.inspection_id,receipt.mime_type,receipt.byte_size,receipt.sha256,receipt.created_by)
 is distinct from (d.organization_id,d.hydrant_id,d.inspection_id,d.mime_type,d.byte_size,d.sha256,actor)
 then raise exception 'DOCUMENT_UUID_REUSED' using errcode='23505'; end if;
 else
 insert into public.inspection_documents(id,organization_id,hydrant_id,inspection_id,mime_type,byte_size,sha256,created_by)
 values(d.id,d.organization_id,d.hydrant_id,d.inspection_id,d.mime_type,d.byte_size,d.sha256,actor) returning * into receipt;
 perform private.write_audit(d.organization_id,actor,'DOCUMENT_RESERVED','inspection_documents',d.id,null,jsonb_build_object('hydrant_id',d.hydrant_id,'inspection_id',d.inspection_id));
 end if;
 if confirm and receipt.uploaded_at is null then
 select metadata into meta from storage.objects where bucket_id='inspection-documents' and name=receipt.storage_path;
 if not found or (meta->>'size')::bigint is distinct from receipt.byte_size or meta->>'mimetype' is distinct from receipt.mime_type
 then raise exception 'DOCUMENT_NOT_UPLOADED' using errcode='22023'; end if;
 update public.inspection_documents set uploaded_at=clock_timestamp() where id=d.id returning * into receipt;
 perform private.write_audit(d.organization_id,actor,'DOCUMENT_UPLOADED','inspection_documents',d.id,null,jsonb_build_object('hydrant_id',d.hydrant_id));
 end if;
 return to_jsonb(receipt);
end;
$$;

create function public.web_manual_inspection(organization uuid, hydrant uuid, event jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor uuid; h public.hydrants; after_h public.hydrants; receipt public.inspections;
 eid uuid:=(event->>'id')::uuid; at_time timestamptz:=(event->>'performed_at')::timestamptz;
 performer uuid:=nullif(event->>'performer_id','')::uuid; correction uuid:=nullif(event->>'corrects_inspection_id','')::uuid;
 pressure numeric:=nullif(event->>'pressure_bar','')::numeric; flow numeric:=nullif(event->>'flow_l_min','')::numeric;
 mapped text;
begin
 actor:=private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']);
 select * into h from public.hydrants where id=hydrant and organization_id=organization for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if eid is null or at_time is null or not isfinite(at_time) or at_time>clock_timestamp() or at_time<'1970-01-01'
 or coalesce(event->>'mode','') not in ('QUICK','GUIDED','CLASSIC') or coalesce(event->>'result','') not in ('PASS','PASS_WITH_ISSUES','FAIL','NOT_INSPECTED')
 or (performer is null and coalesce(btrim(event->>'performer_name'),'')='')
 or (pressure is not null and (pressure not between 0 and 999.99 or pressure<>round(pressure,2)))
 or (flow is not null and (flow not between 0 and 999999.99 or flow<>round(flow,2))) then raise exception 'INVALID_INSPECTION' using errcode='22023'; end if;
 select * into receipt from public.inspections where id=eid;
 if found then
 if (receipt.organization_id,receipt.hydrant_id,receipt.inspector_id,receipt.source,receipt.mode,receipt.result,receipt.completed_at,
 receipt.performer_id,receipt.performer_name,receipt.performer_organization,receipt.notes,receipt.pressure_bar,receipt.flow_l_min,receipt.corrects_inspection_id)
 is distinct from (organization,hydrant,actor,'WEB_MANUAL',event->>'mode',event->>'result',at_time,performer,
 nullif(btrim(event->>'performer_name'),''),nullif(btrim(event->>'performer_organization'),''),nullif(event->>'notes',''),pressure,flow,correction)
 then raise exception 'INSPECTION_UUID_REUSED' using errcode='23505'; end if;
 return to_jsonb(receipt);
 end if;
 if performer is not null and not exists(select 1 from public.user_organizations m join public.profiles p on p.id=m.user_id
 where m.organization_id=organization and m.user_id=performer and p.account_status='ACTIVE') then raise exception 'INVALID_PERFORMER' using errcode='22023'; end if;
 if correction is not null and not exists(select 1 from public.inspections where id=correction and hydrant_id=hydrant and organization_id=organization)
 then raise exception 'INVALID_CORRECTION' using errcode='22023'; end if;
 mapped:=case event->>'result' when 'PASS' then 'WORKING' when 'PASS_WITH_ISSUES' then 'NEEDS_INSPECTION' when 'FAIL' then 'NOT_WORKING' end;
 after_h:=h;
 -- The hydrant row lock serializes this comparison with all existing inspection writes.
 -- A tie does not supersede a previously completed event.
 if mapped is not null and not exists(select 1 from public.inspections i where i.hydrant_id=hydrant
 and i.organization_id=organization and i.result<>'NOT_INSPECTED' and i.completed_at>=at_time) then
 after_h:=public.change_hydrant_status(organization,hydrant,mapped,h.version);
 end if;
 insert into public.inspections(id,hydrant_id,organization_id,inspector_id,mode,result,started_at,completed_at,notes,pressure_bar,flow_l_min,
 hydrant_version_before,hydrant_version_after,source,performer_id,performer_name,performer_organization,corrects_inspection_id)
 values(eid,hydrant,organization,actor,event->>'mode',event->>'result',at_time,at_time,nullif(event->>'notes',''),pressure,flow,
 h.version,after_h.version,'WEB_MANUAL',performer,nullif(btrim(event->>'performer_name'),''),nullif(btrim(event->>'performer_organization'),''),correction) returning * into receipt;
 perform private.write_audit(organization,actor,'INSPECTION_COMPLETED','inspections',eid,null,jsonb_build_object('hydrant_id',hydrant,
 'source','WEB_MANUAL','performed_at',at_time,'performer_id',performer,'result',receipt.result,'status_applied',after_h.version<>h.version,'corrects_inspection_id',correction));
 return to_jsonb(receipt);
end;
$$;

create function public.web_hydrant_write(organization uuid, hydrant uuid, operation uuid, action text,
 data jsonb, expected_version bigint default null) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare h public.hydrants; actor uuid; old_status text; receipt jsonb;
begin
 actor:=private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']);
 perform pg_advisory_xact_lock(hashtextextended(operation::text,8201));
 select a.new_data into receipt from public.audit_log a where a.entity_type='web_hydrant_operations' and a.entity_id=operation;
 if found then
 if (receipt->>'actor',receipt->>'organization',receipt->>'hydrant',receipt->>'action',receipt->'data',receipt->'expected_version')
 is distinct from (actor::text,organization::text,hydrant::text,action,data,coalesce(to_jsonb(expected_version),'null'::jsonb))
 then raise exception 'OPERATION_UUID_REUSED' using errcode='23505'; end if;
 return receipt->'result';
 end if;
 if operation is null or hydrant is null or data is null then raise exception 'INVALID_OPERATION' using errcode='22023'; end if;
 if action='create' then h:=public.create_hydrant(organization,(data->>'hydrant_type_id')::uuid,data-'hydrant_type_id',hydrant);
 elsif action='edit' then
 if data ? 'status' then raise exception 'USE_STATUS_REASON' using errcode='22023'; end if;
 h:=public.update_hydrant(organization,hydrant,data,expected_version);
 elsif action='status' then
 if coalesce(btrim(data->>'reason'),'')='' then raise exception 'REASON_REQUIRED' using errcode='22023'; end if;
 h:=private.lock_hydrant_change(organization,hydrant,array['MANAGER','ADMIN'],expected_version); old_status:=h.status;
 h:=public.change_hydrant_status(organization,hydrant,data->>'status',expected_version);
 perform private.write_audit(organization,actor,'HYDRANT_STATUS_REASON','hydrants',hydrant,jsonb_build_object('status',old_status),
 jsonb_build_object('status',h.status,'reason',btrim(data->>'reason')));
 elsif action='active' then h:=public.set_hydrant_active(organization,hydrant,(data->>'active')::boolean,expected_version);
 else raise exception 'INVALID_OPERATION' using errcode='22023'; end if;
 -- Existing immutable audit log doubles as the durable web operation receipt.
 perform private.write_audit(organization,actor,'WEB_HYDRANT_ACK','web_hydrant_operations',operation,null,
 jsonb_build_object('actor',actor,'organization',organization,'hydrant',hydrant,'action',action,'data',data,'expected_version',expected_version,'result',to_jsonb(h)));
 return to_jsonb(h);
end;
$$;
create function public.web_reserve_photo(photo jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
begin
 perform private.authorize_hydrant_write((photo->>'organization_id')::uuid,array['MANAGER','ADMIN']);
 return public.reserve_photo(photo);
end;
$$;
create function public.web_confirm_photo(organization uuid, photo_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
begin
 perform private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']);
 return public.confirm_photo(organization,photo_id);
end;
$$;

create function public.web_hydrant_detail(root uuid, hydrant uuid, history_page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare h private.web_hydrant_rows;
begin
 select * into h from private.web_hydrant_rows where id=hydrant and organization_id in(select private.web_subtree(root));
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if history_page<0 or history_page>20000 then raise exception 'INVALID_PAGE' using errcode='22023'; end if;
 return jsonb_build_object('hydrant',to_jsonb(h),'writable',private.can_manage_organization(h.organization_id),
 'history',(select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (
 select i.*,coalesce(i.performer_name,p.display_name) performer,entry.display_name entered_by,
 (select count(*) from public.inspection_photos ph where ph.inspection_id=i.id and ph.active and ph.uploaded_at is not null) photo_count
 from public.inspections i left join public.profiles p on p.id=coalesce(i.performer_id,i.inspector_id)
 left join public.profiles entry on entry.id=i.inspector_id where i.hydrant_id=h.id and i.organization_id=h.organization_id
 order by i.completed_at desc,i.id desc limit 25 offset history_page*25) q),
 'audit',(select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (
 select a.action,a.created_at,p.display_name actor,a.old_data,a.new_data from public.audit_log a
 left join public.profiles p on p.id=a.user_id where a.organization_id=h.organization_id and
 (a.entity_type='hydrants' and a.entity_id=h.id or a.new_data->>'hydrant_id'=h.id::text)
 order by a.created_at desc,a.id desc limit 10) q));
end;
$$;
-- Narrow, paginated directory for a manually selected performer, not a broad profile grant.
create function public.web_inspection_performers(organization uuid, search text default '') returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.can_manage_organization(organization) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return (select coalesce(jsonb_agg(to_jsonb(q)),'[]') from(select p.id,p.display_name from public.profiles p
 join public.user_organizations m on m.user_id=p.id where m.organization_id=organization and p.account_status='ACTIVE'
 and strpos(lower(coalesce(p.display_name,'')),lower(left(search,200)))>0 order by p.display_name,p.id limit 30) q);
end;
$$;

-- Explicit ACLs on new routines. Definers are owned by postgres with empty paths.
do $$
declare f record;
begin
 for f in select p.oid::regprocedure signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='public' and p.proname in ('web_hydrants','web_hydrant_context','web_hydrant_dashboard','web_document',
 'web_manual_inspection','web_hydrant_write','web_reserve_photo','web_confirm_photo','web_hydrant_detail','web_inspection_performers'))
 or (n.nspname='private' and p.proname in ('web_read','web_subtree','document_object')) loop
 execute format('alter function %s owner to postgres',f.signature);
 execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
 if f.nspname='public' or f.signature::text like '%web_read(%' or f.signature::text like '%document_object(%' then
 execute format('grant execute on function %s to authenticated',f.signature); end if;
 end loop;
end;
$$;
-- Realtime is only an invalidation signal; all reads recheck authorization.
do $$ declare tab text; begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') then
 foreach tab in array array['hydrants','inspections','hydrant_photos','inspection_photos'] loop
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=tab) then
 execute format('alter publication supabase_realtime add table public.%I',tab); end if;
 end loop; end if;
end; $$;
