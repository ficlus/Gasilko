-- M9: frozen import manifests and bounded, replayable batches. Source files are not retained.
create table private.web_imports (
 id uuid primary key, actor uuid not null references public.profiles(id), root uuid not null references public.organizations(id),
 manifest jsonb not null, payload_hash text not null, created_at timestamptz not null default clock_timestamp(), completed_at timestamptz
);
create table private.web_import_rows (
 import_id uuid not null references private.web_imports(id), row_number integer not null,
 organization_id uuid references public.organizations(id), target uuid, frozen jsonb not null,
 operations uuid[] not null default array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()],
 result jsonb, primary key(import_id,row_number)
);
create index web_imports_history on private.web_imports(root,created_at desc,id);
create index web_import_rows_scope on private.web_import_rows(organization_id,import_id,row_number);
create table public.import_mapping_profiles (
 id uuid primary key, organization_id uuid not null references public.organizations(id), name text not null check(length(btrim(name)) between 1 and 120),
 configuration jsonb not null, active boolean not null default true, version bigint not null default 1,
 created_by uuid not null references public.profiles(id), updated_at timestamptz not null default clock_timestamp()
);
alter table public.import_mapping_profiles enable row level security;
revoke all on private.web_imports,private.web_import_rows,public.import_mapping_profiles from public,anon,authenticated,service_role;

create function public.web_exchange_context(root uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return public.web_hydrant_context(root)||jsonb_build_object('organizations',(
 select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'code',o.code,'name',o.name,'writable',private.can_manage_organization(o.id)) order by o.name,o.id),'[]')
 from public.organizations o where o.id in(select private.web_subtree(root))));
end; $$;

-- Read-only validation, reused at freeze and apply. Never query an identity before validating its target scope.
create function private.web_import_preview_row(root uuid, input jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare org uuid; h public.hydrants; candidate public.hydrants; patch jsonb:=coalesce(input->'data','{}');
 typ uuid; type_count integer; n integer:=(input->>'row')::integer; warning jsonb:='[]'; action text; before_data jsonb; after_data jsonb;
begin
 if input ? 'error' then return jsonb_build_object('row',n,'action','ERROR','error',input->>'error'); end if;
 if coalesce((input->>'blank')::boolean,false) then return jsonb_build_object('row',n,'action','SKIP'); end if;
 select o.id into org from public.organizations o where o.id in(select private.web_subtree(root))
 and private.can_manage_organization(o.id) and (o.id::text=input->>'organization' or o.code=input->>'organization');
 if org is null then raise exception 'NOT_AUTHORIZED_OR_INVALID_TARGET'; end if;
 if nullif(input->>'uuid','') is not null then
  select * into h from public.hydrants where organization_id=org and id::text=input->>'uuid';
  if not found or (nullif(input->>'code','') is not null and h.code is distinct from input->>'code') then raise exception 'NOT_AUTHORIZED_OR_INVALID_TARGET'; end if;
 elsif nullif(input->>'code','') is not null then
  select * into h from public.hydrants where organization_id=org and code=input->>'code';
  if not found then raise exception 'NOT_AUTHORIZED_OR_INVALID_TARGET'; end if;
 end if;
 if input ? 'type' then
  select count(*) into type_count from public.hydrant_types t where t.active and (t.organization_id is null or t.organization_id=org)
   and (t.id::text=input->>'type' or t.code=input->>'type');
  if type_count<>1 then raise exception 'INVALID_TYPE'; end if;
  select t.id into typ from public.hydrant_types t where t.active and (t.organization_id is null or t.organization_id=org)
   and (t.id::text=input->>'type' or t.code=input->>'type') order by (t.organization_id=org) desc nulls last,t.id limit 1;
  if typ is null then raise exception 'INVALID_TYPE'; end if;
  patch:=patch||jsonb_build_object('hydrant_type_id',typ);
 end if;
 if exists(select 1 from jsonb_object_keys(patch) k where k not in ('hydrant_type_id','latitude','longitude','address','location_description','status','notes','inspection_interval_months','active')) then raise exception 'INVALID_FIELDS'; end if;
 perform private.validate_hydrant_fields(patch-'active',false);
 if exists(select 1 from jsonb_each(patch) x where jsonb_typeof(x.value)='string' and length(x.value#>>'{}')>4096)
 or (patch ? 'latitude' and (patch->>'latitude')::numeric is distinct from round((patch->>'latitude')::numeric,6))
 or (patch ? 'longitude' and (patch->>'longitude')::numeric is distinct from round((patch->>'longitude')::numeric,6)) then raise exception 'INVALID_FIELDS'; end if;
 if patch ? 'active' and jsonb_typeof(patch->'active')<>'boolean' then raise exception 'INVALID_FIELDS'; end if;
 if h.id is null then
  patch:=jsonb_build_object('status','UNKNOWN','active',true)||patch;
  select * into candidate from jsonb_populate_record(null::public.hydrants,jsonb_build_object('status','UNKNOWN','active',true)||patch);
 else select * into candidate from jsonb_populate_record(h,patch); end if;
 if candidate.hydrant_type_id is null or candidate.status is null or candidate.status not in ('WORKING','NOT_WORKING','NEEDS_INSPECTION','UNKNOWN')
 or (candidate.latitude is null)<>(candidate.longitude is null) or candidate.latitude not between -90 and 90 or candidate.longitude not between -180 and 180
 or (candidate.latitude is null and coalesce(btrim(candidate.address),'')='' and coalesce(btrim(candidate.location_description),'')='')
 or candidate.inspection_interval_months<=0 then raise exception 'INVALID_FIELDS'; end if;
 if not exists(select 1 from public.hydrant_types t where t.id=candidate.hydrant_type_id and (t.organization_id is null or t.organization_id=org)
 and (t.active or (h.id is not null and h.hydrant_type_id=t.id and not patch ? 'hydrant_type_id'))) then raise exception 'INVALID_TYPE'; end if;
 if candidate.latitude=0 and candidate.longitude=0 then warning:='["SUSPICIOUS_COORDINATES"]'; end if;
 if candidate.latitude is null then warning:=warning||'"NO_COORDINATES"'::jsonb; end if;
 select coalesce(jsonb_object_agg(k,to_jsonb(h)->k),'{}') into before_data from jsonb_object_keys(patch) k;
 select coalesce(jsonb_object_agg(k,to_jsonb(candidate)->k),'{}') into after_data from jsonb_object_keys(patch) k;
 action:=case when h.id is null then 'CREATE' when before_data=after_data then 'UNCHANGED' else 'UPDATE' end;
 if input ? 'expected_version' and h.id is not null and (input->>'expected_version')::bigint is distinct from h.version then action:='CONFLICT'; end if;
 return jsonb_build_object('row',n,'organization_id',org,'id',h.id,'code',h.code,'action',action,'version',h.version,
 'before',before_data,'after',after_data,'data',patch,'warnings',warning,'latitude',candidate.latitude,'longitude',candidate.longitude);
exception when others then
 return jsonb_build_object('row',n,'action','ERROR','error',case when sqlerrm in ('INVALID_TYPE','INVALID_FIELDS','NOT_AUTHORIZED_OR_INVALID_TARGET') then sqlerrm else 'INVALID_FIELDS' end);
end; $$;

create function public.web_import_preview(root uuid, rows jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if jsonb_typeof(rows)<>'array' or jsonb_array_length(rows)>250 or octet_length(rows::text)>2097152 then raise exception 'LIMIT_EXCEEDED'; end if;
 return (select coalesce(jsonb_agg(private.web_import_preview_row(root,r) order by ord),'[]') from jsonb_array_elements(rows) with ordinality x(r,ord));
end; $$;

create function public.web_import_confirm(root uuid, operation uuid, manifest jsonb) returns uuid
language plpgsql volatile security definer set search_path='' as $$
declare saved private.web_imports; input jsonb; p jsonb; n integer; target uuid; org uuid; selected boolean;
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if operation is null or jsonb_typeof(manifest->'rows') is distinct from 'array' or jsonb_array_length(manifest->'rows') not between 1 and 10000
 or octet_length(manifest::text)>16777216 or length(btrim(coalesce(manifest->>'reason',''))) not between 1 and 500
 or length(coalesce(manifest->>'filename','')) not between 1 and 180 or manifest->>'filename' ~ '[/\\[:cntrl:]]'
 or coalesce(manifest->>'format','') not in ('csv','xls','xlsx') or coalesce(manifest->>'file_hash','') !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_IMPORT'; end if;
 perform pg_advisory_xact_lock(hashtextextended(operation::text,9001));
 select * into saved from private.web_imports where id=operation;
 if found then
  if saved.actor<>auth.uid() or saved.root<>root or saved.manifest is distinct from manifest then raise exception 'OPERATION_REUSED'; end if;
  return operation;
 end if;
 -- Check duplicates over the complete file, not just the selected/apply batch.
 if exists(select 1 from jsonb_array_elements(manifest->'rows') r group by r->>'row' having count(*)>1) then raise exception 'INVALID_IMPORT'; end if;
 insert into private.web_imports(id,actor,root,manifest,payload_hash) values(operation,auth.uid(),root,manifest,encode(sha256(convert_to(manifest::text,'UTF8')),'hex'));
 for input in select value from jsonb_array_elements(manifest->'rows') loop
  n:=(input->>'row')::integer; if n not between 2 and 10001 then raise exception 'INVALID_IMPORT'; end if;
  p:=private.web_import_preview_row(root,input); org:=(p->>'organization_id')::uuid; target:=(p->>'id')::uuid;
  selected:=coalesce((input->>'selected')::boolean,false);
  if selected and p->>'action' in ('CREATE','UPDATE') then
   perform private.authorize_hydrant_write(org,array['MANAGER','ADMIN']);
   if jsonb_array_length(p->'warnings')>0 and not coalesce((input->>'accept_warnings')::boolean,false) then raise exception 'WARNINGS_REQUIRE_CONFIRMATION'; end if;
   if p->>'action'='UPDATE' and not input ? 'expected_version' then raise exception 'EXPECTED_VERSION_REQUIRED'; end if;
   target:=coalesce(target,gen_random_uuid());
  end if;
  insert into private.web_import_rows(import_id,row_number,organization_id,target,frozen,result)
   values(operation,n,org,target,p,case when selected and p->>'action' in ('CREATE','UPDATE') then null
    else p||jsonb_build_object('action',case when p->>'action' in ('ERROR','CONFLICT','UNCHANGED') then p->>'action' else 'SKIP' end) end);
 end loop;
 -- Mark every member of a duplicate group, including rows excluded in the browser.
 update private.web_import_rows r set result=jsonb_build_object('row',r.row_number,'action','ERROR','error','DUPLICATE_IDENTITY')
 where r.import_id=operation and (r.target in(select target from private.web_import_rows where import_id=operation and target is not null group by target having count(*)>1)
 or r.row_number in(with source as materialized(select value v from jsonb_array_elements(manifest->'rows')),
  du as(select lower(v->>'uuid') identity from source where nullif(v->>'uuid','') is not null group by lower(v->>'uuid') having count(*)>1),
  dc as(select v->>'organization' org,v->>'code' code from source where nullif(v->>'code','') is not null group by v->>'organization',v->>'code' having count(*)>1)
  select (s.v->>'row')::integer from source s left join du on du.identity=lower(s.v->>'uuid') left join dc on dc.org=s.v->>'organization' and dc.code=s.v->>'code'
  where du.identity is not null or dc.code is not null));
 perform private.write_audit(root,auth.uid(),'IMPORT_CONFIRMED','web_imports',operation,null,jsonb_build_object('rows',jsonb_array_length(manifest->'rows'),'hash',encode(sha256(convert_to(manifest::text,'UTF8')),'hex')));
 return operation;
end; $$;

create function public.web_import_apply(root uuid, operation uuid) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare job private.web_imports; r private.web_import_rows; h jsonb; patch jsonb; answer jsonb; state text;
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into job from private.web_imports where id=operation and web_imports.root=web_import_apply.root and actor=auth.uid() for update;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 for r in select * from private.web_import_rows where import_id=operation and result is null order by row_number limit 100 loop
  begin
   perform private.authorize_hydrant_write(r.organization_id,array['MANAGER','ADMIN']);
   if r.organization_id not in(select private.web_subtree(root)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   patch:=r.frozen->'data';
   if r.frozen->>'action'='CREATE' then
    h:=public.web_hydrant_write(r.organization_id,r.target,r.operations[1],'create',patch-'active',null);
   else
    h:=to_jsonb(private.lock_hydrant_change(r.organization_id,r.target,array['MANAGER','ADMIN'],(r.frozen->>'version')::bigint));
    select coalesce(jsonb_object_agg(key,value),'{}') into patch from jsonb_each(patch-'status'-'active') where value is distinct from h->key;
    if patch<>'{}'::jsonb then h:=public.web_hydrant_write(r.organization_id,r.target,r.operations[2],'edit',patch,(h->>'version')::bigint); end if;
    if r.frozen->'data' ? 'status' and h->'status' is distinct from r.frozen->'data'->'status' then
     h:=public.web_hydrant_write(r.organization_id,r.target,r.operations[3],'status',jsonb_build_object('status',r.frozen->'data'->'status','reason',job.manifest->>'reason'),(h->>'version')::bigint);
    end if;
   end if;
   if r.frozen->'data' ? 'active' and h->'active' is distinct from r.frozen->'data'->'active' then
    h:=public.web_hydrant_write(r.organization_id,r.target,r.operations[4],'active',jsonb_build_object('active',r.frozen->'data'->'active'),(h->>'version')::bigint);
   end if;
   answer:=jsonb_build_object('row',r.row_number,'action',r.frozen->>'action','id',r.target,'code',h->>'code','version',h->'version','acknowledged',true);
   perform private.write_audit(r.organization_id,auth.uid(),'IMPORT_ROW_ACK','hydrants',r.target,null,jsonb_build_object('import_id',operation,'row',r.row_number,'operations',r.operations));
  exception when sqlstate 'P0001' or sqlstate '42501' or data_exception or integrity_constraint_violation then
   state:=case when sqlerrm='HYDRANT_VERSION_CONFLICT' then 'CONFLICT' else 'ERROR' end;
   answer:=jsonb_build_object('row',r.row_number,'action',state,'error',case when sqlstate='42501' then 'NOT_AUTHORIZED_OR_INVALID_TARGET' when state='CONFLICT' then 'STALE_VERSION' else 'INVALID_FIELDS' end);
  end;
  update private.web_import_rows set result=answer where import_id=operation and row_number=r.row_number;
 end loop;
 if not exists(select 1 from private.web_import_rows where import_id=operation and result is null) and job.completed_at is null then
  update private.web_imports set completed_at=clock_timestamp() where id=operation;
  perform private.write_audit(root,auth.uid(),'IMPORT_FINISHED','web_imports',operation,null,jsonb_build_object('operation',operation));
 end if;
 return jsonb_build_object('remaining',(select count(*) from private.web_import_rows where import_id=operation and result is null));
end; $$;

create function public.web_import_history(root uuid, operation uuid default null, page integer default 0, state text default '') returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if page not between 0 and 20000 then raise exception 'INVALID_QUERY'; end if;
 if operation is null then
  return (select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (select j.id,j.created_at,j.completed_at,j.actor,j.manifest->>'filename' filename,j.payload_hash,
   (select count(*) from private.web_import_rows r where r.import_id=j.id and (r.organization_id in(select private.web_subtree(web_import_history.root)) or (r.organization_id is null and j.actor=auth.uid())) ) visible_rows,
   (select coalesce(jsonb_object_agg(s.action,s.total),'{}') from (select coalesce(r.result->>'action','PENDING') action,count(*) total from private.web_import_rows r
    where r.import_id=j.id and (r.organization_id in(select private.web_subtree(web_import_history.root)) or (r.organization_id is null and j.actor=auth.uid())) group by coalesce(r.result->>'action','PENDING')) s) summary
   from private.web_imports j where j.root=web_import_history.root and (j.actor=auth.uid() or exists(select 1 from private.web_import_rows r where r.import_id=j.id and r.organization_id in(select private.web_subtree(web_import_history.root))))
   and (state='' or (state='PENDING')=(j.completed_at is null)) order by j.created_at desc,j.id limit 50 offset page*50) q);
 end if;
 return (select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (select r.row_number,r.organization_id,r.frozen->>'action' intended,r.result,
 r.frozen->'before' before,r.frozen->'after' after,r.result is null pending
 from private.web_import_rows r join private.web_imports j on j.id=r.import_id where j.root=web_import_history.root and j.id=operation
 and (r.organization_id in(select private.web_subtree(web_import_history.root)) or (r.organization_id is null and j.actor=auth.uid()))
 and (state='' or coalesce(r.result->>'action','PENDING')=state) order by row_number limit 100 offset page*100) q);
end; $$;

create function public.web_import_profiles(root uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if (select count(*) from public.import_mapping_profiles where organization_id in(select private.web_subtree(root)))>200 then raise exception 'LIMIT_EXCEEDED'; end if;
 return (select coalesce(jsonb_agg(to_jsonb(p) order by p.name,p.id),'[]') from (select * from public.import_mapping_profiles where organization_id in(select private.web_subtree(root)) order by name,id limit 200) p);
end; $$;
create function public.web_import_profile_save(organization uuid, operation uuid, profile uuid, expected_version bigint, name text, configuration jsonb, active boolean) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare before_row public.import_mapping_profiles; after_row public.import_mapping_profiles; actor uuid; receipt jsonb;
 request jsonb:=jsonb_build_object('profile',profile,'version',expected_version,'name',name,'configuration',configuration,'active',active);
begin
 actor:=private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']);
 if operation is null or profile is null or jsonb_typeof(configuration)<>'object' or octet_length(configuration::text)>32768
 or exists(select 1 from jsonb_object_keys(configuration) k where k not in ('columns','statuses','types','decimal','clear')) then raise exception 'INVALID_PROFILE'; end if;
 if jsonb_typeof(configuration->'columns') is distinct from 'object' or jsonb_typeof(configuration->'statuses') is distinct from 'object'
 or jsonb_typeof(configuration->'types') is distinct from 'object' or configuration->>'decimal' not in ('auto','point','comma')
 or jsonb_typeof(configuration->'clear') is distinct from 'boolean' then raise exception 'INVALID_PROFILE'; end if;
 if exists(select 1 from jsonb_each(configuration->'columns') x where x.key not in ('uuid','code','organization','type','status','latitude','longitude','address','location_description','notes','inspection_interval_months','active')
  or jsonb_typeof(x.value)<>'number' or x.value::text !~ '^[0-9]{1,2}$' or (x.value::text)::integer>63)
 or exists(select 1 from jsonb_each(configuration->'statuses') x where length(x.key)>120 or jsonb_typeof(x.value)<>'string' or x.value#>>'{}' not in ('','WORKING','NOT_WORKING','NEEDS_INSPECTION','UNKNOWN'))
 or exists(select 1 from jsonb_each(configuration->'types') x where length(x.key)>120 or jsonb_typeof(x.value)<>'string' or length(x.value#>>'{}')>64) then raise exception 'INVALID_PROFILE'; end if;
 perform pg_advisory_xact_lock(hashtextextended(operation::text,9002));
 select new_data into receipt from public.audit_log where entity_type='import_profile_operations' and entity_id=operation;
 if found then
  if receipt->'request' is distinct from request or receipt->>'actor'<>actor::text or receipt->>'organization'<>organization::text then raise exception 'OPERATION_REUSED'; end if;
  return receipt->'result';
 end if;
 select * into before_row from public.import_mapping_profiles where id=profile for update;
 if found then
  if before_row.organization_id<>organization or before_row.version<>expected_version then raise exception 'STALE_VERSION'; end if;
  update public.import_mapping_profiles p set name=web_import_profile_save.name,configuration=web_import_profile_save.configuration,
   active=web_import_profile_save.active,version=p.version+1,updated_at=clock_timestamp() where id=profile returning * into after_row;
 else
  if expected_version<>0 then raise exception 'STALE_VERSION'; end if;
  if (select count(*) from public.import_mapping_profiles where organization_id=organization)>=200 then raise exception 'LIMIT_EXCEEDED'; end if;
  insert into public.import_mapping_profiles(id,organization_id,name,configuration,active,created_by)
   values(profile,organization,name,configuration,active,actor) returning * into after_row;
 end if;
 perform private.write_audit(organization,actor,'IMPORT_PROFILE_SAVED','import_profile_operations',operation,to_jsonb(before_row),
 jsonb_build_object('actor',actor,'organization',organization,'request',request,'result',to_jsonb(after_row)));
 return to_jsonb(after_row);
end; $$;

-- All functions are invoked with the authenticated user, never a service key.
revoke all on function private.web_import_preview_row(uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.web_exchange_context(uuid),public.web_import_preview(uuid,jsonb),public.web_import_confirm(uuid,uuid,jsonb),
 public.web_import_apply(uuid,uuid),public.web_import_history(uuid,uuid,integer,text),public.web_import_profiles(uuid),
 public.web_import_profile_save(uuid,uuid,uuid,bigint,text,jsonb,boolean) from public,anon,authenticated,service_role;
grant execute on function public.web_exchange_context(uuid),public.web_import_preview(uuid,jsonb),public.web_import_confirm(uuid,uuid,jsonb),
 public.web_import_apply(uuid,uuid),public.web_import_history(uuid,uuid,integer,text),public.web_import_profiles(uuid),
 public.web_import_profile_save(uuid,uuid,uuid,bigint,text,jsonb,boolean) to authenticated;

create function private.exchange_hydrants(root uuid, filters jsonb) returns setof private.web_hydrant_rows
language sql stable security definer set search_path='' as $$
 select r.* from private.web_hydrant_rows r where r.organization_id in(select private.web_subtree(root))
 and (nullif(filters->>'organization','') is null or r.organization_id::text=filters->>'organization')
 and (not filters ? 'hidden' or not (filters->'hidden') ? r.organization_id::text)
 and (nullif(filters->>'type','') is null or r.hydrant_type_id::text=filters->>'type')
 and (nullif(filters->>'status','') is null or r.status=filters->>'status')
 and (coalesce(filters->>'active','all')='all' or r.active=(filters->>'active'='active'))
 and (nullif(filters->>'due','') is null or r.due_state=filters->>'due')
 and (coalesce(filters->>'search','')='' or strpos(lower(coalesce(r.code,'')||' '||coalesce(r.address,'')||' '||coalesce(r.location_description,'')),lower(filters->>'search'))>0);
$$;
create function public.web_exchange_export(root uuid, kind text, filters jsonb default '{}', after_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if octet_length(filters::text)>8192 then raise exception 'INVALID_QUERY'; end if;
 if kind='hydrants' then
  select coalesce(jsonb_agg(to_jsonb(q) order by q.uuid),'[]') into result from (
   select r.id uuid,r.code,r.organization_id,o.code organization_code,r.organization_name,r.hydrant_type_id,r.type_code,r.type_name,
   r.status,r.latitude,r.longitude,r.address,r.location_description,r.notes,r.inspection_interval_months,r.active,r.version,
   r.last_inspection_at,i.result last_inspection_result,i.pressure_bar latest_pressure_bar,i.flow_l_min latest_flow_l_min,r.next_due,r.due_state,r.updated_at
   from private.exchange_hydrants(root,filters) r join public.organizations o on o.id=r.organization_id
   left join public.inspections i on i.id=r.last_inspection_id where after_id is null or r.id>after_id order by r.id limit 500) q;
 elsif kind='inspections' then
  select coalesce(jsonb_agg(to_jsonb(q) order by q.uuid),'[]') into result from (
   select i.id uuid,i.hydrant_id,h.code hydrant_code,i.organization_id,h.organization_name,i.mode,i.result,i.started_at,i.completed_at,i.created_at,
   coalesce(i.performer_name,p.display_name) performer,i.performer_organization,actor.display_name entered_by,
   i.source,i.notes,i.pressure_bar,i.flow_l_min,i.corrects_inspection_id
   from public.inspections i join private.exchange_hydrants(root,filters) h on h.id=i.hydrant_id and h.organization_id=i.organization_id
   left join public.profiles p on p.id=coalesce(i.performer_id,i.inspector_id) left join public.profiles actor on actor.id=i.inspector_id
   where (after_id is null or i.id>after_id) and (nullif(filters->>'result','') is null or i.result=filters->>'result')
   and (nullif(filters->>'mode','') is null or i.mode=filters->>'mode')
   and (nullif(filters->>'from','') is null or i.completed_at>=(filters->>'from')::timestamptz)
   and (nullif(filters->>'to','') is null or i.completed_at<(filters->>'to')::timestamptz)
   order by i.id limit 500) q;
 elsif kind='teams' then
  select coalesce(jsonb_agg(to_jsonb(q) order by q.uuid),'[]') into result from (
   select t.id uuid,t.organization_id,o.name organization_name,t.name,t.active,t.created_at,t.updated_at,
   (select count(*) from public.inspection_team_members m where m.team_id=t.id and m.active) active_members
   from public.inspection_teams t join public.organizations o on o.id=t.organization_id
   where t.organization_id in(select private.web_subtree(root)) and (after_id is null or t.id>after_id)
   and (nullif(filters->>'organization','') is null or t.organization_id::text=filters->>'organization') order by t.id limit 500) q;
 elsif kind='plans' then
  select coalesce(jsonb_agg(to_jsonb(q) order by q.uuid),'[]') into result from (
   select p.id uuid,p.organization_id,o.name organization_name,p.name,p.status,p.selection_mode,p.start_latitude,p.start_longitude,p.return_to_start,p.version,p.created_at,p.started_at,p.completed_at,p.updated_at,
   (select string_agg(t.name,'; ' order by t.name,t.id) from public.inspection_plan_teams pt join public.inspection_teams t on t.id=pt.team_id and t.organization_id=pt.organization_id where pt.plan_id=p.id and pt.active) teams,
   (select string_agg(distinct r.provider,', ' order by r.provider) from public.inspection_plan_routes r where r.plan_id=p.id and r.valid) route_providers,
   (select sum(r.distance_m) from public.inspection_plan_routes r where r.plan_id=p.id and r.valid) route_distance_m,
   (select sum(r.duration_s) from public.inspection_plan_routes r where r.plan_id=p.id and r.valid) route_duration_s,
   (select count(*) from public.inspection_plan_items i where i.plan_id=p.id and i.active) total,
   (select count(*) from public.inspection_plan_items i where i.plan_id=p.id and i.active and i.completed_at is not null) completed,
   (select count(*) from public.inspection_plan_items i where i.plan_id=p.id and i.active and i.completed_at is null) remaining,
   (select count(*) from public.inspection_plan_items i where i.plan_id=p.id and i.active and i.completed_at is null and i.skipped_at is not null) skipped
   from public.inspection_plans p join public.organizations o on o.id=p.organization_id
   where p.organization_id in(select private.web_subtree(root)) and (after_id is null or p.id>after_id)
   and (nullif(filters->>'organization','') is null or p.organization_id::text=filters->>'organization') order by p.id limit 500) q;
 else raise exception 'INVALID_QUERY'; end if;
 return result;
end; $$;
revoke all on function private.exchange_hydrants(uuid,jsonb),public.web_exchange_export(uuid,text,jsonb,uuid) from public,anon,authenticated,service_role;
grant execute on function public.web_exchange_export(uuid,text,jsonb,uuid) to authenticated;

-- No physical history deletion. The only mutable job field is its one-time completion stamp.
create function private.guard_web_import() returns trigger language plpgsql set search_path='' as $$
begin
 if (to_jsonb(new)-'completed_at') is distinct from (to_jsonb(old)-'completed_at') or old.completed_at is not null then raise exception 'IMMUTABLE_IMPORT'; end if;
 return new;
end; $$;
create function private.guard_web_import_row() returns trigger language plpgsql set search_path='' as $$
begin
 if (to_jsonb(new)-'result') is distinct from (to_jsonb(old)-'result') then raise exception 'IMMUTABLE_IMPORT'; end if;
 return new;
end; $$;
revoke all on function private.guard_web_import(),private.guard_web_import_row() from public,anon,authenticated,service_role;
create trigger web_import_immutable before update on private.web_imports for each row execute function private.guard_web_import();
create trigger web_import_row_immutable before update on private.web_import_rows for each row execute function private.guard_web_import_row();
create trigger web_import_no_delete before delete on private.web_imports for each row execute function private.audit_immutable();
create trigger web_import_row_no_delete before delete on private.web_import_rows for each row execute function private.audit_immutable();
create trigger web_import_no_truncate before truncate on private.web_imports for each statement execute function private.audit_immutable();
create trigger web_import_row_no_truncate before truncate on private.web_import_rows for each statement execute function private.audit_immutable();
create trigger import_profile_no_delete before delete on public.import_mapping_profiles for each row execute function private.audit_immutable();
create trigger import_profile_no_truncate before truncate on public.import_mapping_profiles for each statement execute function private.audit_immutable();
