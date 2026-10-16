-- M14.6B. Forward-only; apply manually after M14.6A.
begin;
-- Separate schema: M14.6A definition schema-v1 stays strict and unchanged.
create table private.simulation_event_plans (
 version_id uuid primary key references public.simulation_scenario_template_versions(id),
 plan jsonb not null check(octet_length(plan::text)<=60000)
);
create table private.simulation_event_sessions (
 scenario_id uuid primary key references private.simulation_template_instances(scenario_id),
 source_version_id uuid not null references public.simulation_scenario_template_versions(id),
 organization_id uuid not null references public.organizations(id),
 plan jsonb not null check(octet_length(plan::text)<=60000),
 last_scan_at timestamptz
);
create table private.simulation_event_instances (
 scenario_id uuid not null references private.simulation_event_sessions(scenario_id),
 event_id text not null, ordinal integer not null check(ordinal between 1 and 40),
 definition jsonb not null check(octet_length(definition::text)<=12000),
 operation_id uuid not null unique default gen_random_uuid(),
 state text not null default 'PLANNED' check(state in ('PLANNED','BLOCKED','RETRYABLE_FAILURE','EXECUTED','CANCELLED')),
 version bigint not null default 1 check(version>0), attempts integer not null default 0 check(attempts between 0 and 3),
 result jsonb not null default '{}' check(octet_length(result::text)<=12000), executed_at timestamptz, simulation_seconds bigint,
 check((state='EXECUTED')=(executed_at is not null)),
 primary key(scenario_id,event_id),unique(scenario_id,ordinal)
);
create index simulation_event_due on private.simulation_event_instances(scenario_id,ordinal) where state='PLANNED';
create index simulation_event_fair on private.simulation_event_sessions(last_scan_at nulls first,scenario_id);
create table private.simulation_event_annotations (
 scenario_id uuid not null,event_id text not null,version bigint not null default 1 check(version>0),
 title text not null check(length(btrim(title)) between 1 and 200),description text not null check(length(description)<=2000),kind text not null check(kind in ('HAZARD_REVEAL','ACCESS_RESTRICTION')),
 geometry jsonb not null, revealed_at timestamptz not null default clock_timestamp(),
 primary key(scenario_id,event_id),
 foreign key(scenario_id,event_id) references private.simulation_event_instances(scenario_id,event_id)
);
create table private.simulation_event_history (
 id bigint generated always as identity primary key,
 scenario_id uuid not null,event_id text not null,event_version bigint not null,
 operation_id uuid not null, actor uuid references public.profiles(id),
 origin text not null check(origin in ('INSTRUCTOR','SIMULATION_ENGINE')),
 state text not null check(state in ('BLOCKED','RETRYABLE_FAILURE','EXECUTED','CANCELLED')),
 simulation_seconds bigint not null,result jsonb not null check(octet_length(result::text)<=12000),recorded_at timestamptz not null default clock_timestamp(),
 foreign key(scenario_id,event_id) references private.simulation_event_instances(scenario_id,event_id),
 unique(scenario_id,event_id,event_version),check((origin='INSTRUCTOR')=(actor is not null))
);
create index simulation_event_history_page on private.simulation_event_history(scenario_id,id);

create function private.validate_simulation_event_plan(p jsonb,d jsonb,ready boolean) returns void
language plpgsql immutable set search_path='' as $$
declare e jsonb;t jsonb;f jsonb;g jsonb;prior jsonb;ids text[]:='{}';seen jsonb:='{}';n numeric;
begin
 if p is null or octet_length(p::text)>60000 then raise exception 'VALIDATION_FAILED';end if;
 perform private.sim_template_keys(p,array['schema_version','events']);
 if p->'schema_version' is distinct from '1'::jsonb or jsonb_typeof(p->'events') is distinct from 'array'
 or jsonb_array_length(p->'events')>40 then raise exception 'VALIDATION_FAILED';end if;
 for e in select value from jsonb_array_elements(p->'events') loop
  perform private.sim_template_keys(e,array['id','type','title','description','trigger','visibility','effect']);
  if octet_length(e::text)>12000 or jsonb_typeof(e->'id') is distinct from 'string' or (e->>'id') !~ '^[a-zA-Z0-9_-]{1,64}$'
   or e->>'id'=any(ids) or coalesce(e->>'type','') not in ('INCIDENT_REPORT','HAZARD_REVEAL','HAZARD_UPDATE','ACCESS_RESTRICTION','RESOURCE_REQUEST','COMMUNICATION_EVENT','PHASE_CHANGE')
   or e->>'visibility' is distinct from 'COMMANDER' then raise exception 'VALIDATION_FAILED';end if;
  perform private.sim_template_text(e->'title',200,true);perform private.sim_template_text(e->'description',2000);
  t:=e->'trigger';perform private.sim_template_keys(t,array['mode','offset_seconds','event_id']);
  if t->>'mode'='SIMULATION_TIME' then
   if jsonb_typeof(t->'offset_seconds') is distinct from 'number' or t->'event_id' is distinct from 'null'::jsonb then raise exception 'VALIDATION_FAILED';end if;
   n:=(t->>'offset_seconds')::numeric;
   if n<>trunc(n) or n<0 or n>28800 then raise exception 'VALIDATION_FAILED';end if;
  elsif t->>'mode'='MANUAL' then
   if t->'offset_seconds' is distinct from 'null'::jsonb or t->'event_id' is distinct from 'null'::jsonb then raise exception 'VALIDATION_FAILED';end if;
  elsif t->>'mode'='AFTER_EVENT' then
   if t->'offset_seconds' is distinct from 'null'::jsonb or not coalesce(t->>'event_id'=any(ids),false) then raise exception 'VALIDATION_FAILED';end if;
  else raise exception 'VALIDATION_FAILED';end if;
  f:=e->'effect';
  if e->>'type' in ('HAZARD_REVEAL','HAZARD_UPDATE','ACCESS_RESTRICTION') then
   perform private.sim_template_keys(f,array['geometry','source_object_id','target_event_id','expected_version']);
   if f->'source_object_id'<>'null'::jsonb then
    if jsonb_typeof(f->'source_object_id') is distinct from 'string' or f->'geometry' is distinct from 'null'::jsonb then raise exception 'VALIDATION_FAILED';end if;
    select o->'geometry' into g from jsonb_array_elements(d->'initial_objects') o where o->>'id'=f->>'source_object_id';
    if not found then raise exception 'VALIDATION_FAILED';end if;
   else g:=f->'geometry';end if;
   if g='null'::jsonb and not ready then null;
   else
    perform private.validate_incident_geometry(g,array['Point','Polygon']);
    if g->>'type'='Polygon' and (jsonb_array_length(g->'coordinates')<>1 or jsonb_array_length(g#>'{coordinates,0}')>33) then raise exception 'VALIDATION_FAILED';end if;
   end if;
   if e->>'type'='HAZARD_UPDATE' then
    prior:=seen->(f->>'target_event_id');
    if prior is null or prior->>'type'<>'HAZARD_REVEAL' or jsonb_typeof(f->'expected_version') is distinct from 'number' then raise exception 'VALIDATION_FAILED';end if;
    n:=(f->>'expected_version')::numeric;
    if n<>trunc(n) or n<1 or n>40 then raise exception 'VALIDATION_FAILED';end if;
   elsif f->'target_event_id' is distinct from 'null'::jsonb or f->'expected_version' is distinct from 'null'::jsonb then raise exception 'VALIDATION_FAILED';end if;
  elsif f is distinct from 'null'::jsonb then raise exception 'VALIDATION_FAILED';end if;
  ids:=array_append(ids,e->>'id');seen:=seen||jsonb_build_object(e->>'id',e);
 end loop;
end; $$;
create function private.simulation_event_plan_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare v public.simulation_scenario_template_versions;
begin
 if tg_op='DELETE' then raise exception 'INVALID_TRANSITION';end if;
 if tg_op='UPDATE' and new.version_id<>old.version_id then raise exception 'INVALID_TRANSITION';end if;
 select * into v from public.simulation_scenario_template_versions where id=new.version_id for update;
 if not found or v.state<>'DRAFT' then raise exception 'INVALID_TRANSITION';end if;
 perform private.validate_simulation_event_plan(new.plan,v.definition,false);
 return new;
end; $$;
create trigger simulation_event_plan_guard before insert or update or delete on private.simulation_event_plans
 for each row execute function private.simulation_event_plan_guard();

create function private.simulation_event_instantiate() returns trigger
language plpgsql security definer set search_path='' as $$
declare p jsonb;e record;
begin
 select plan into p from private.simulation_event_plans where version_id=new.source_version_id;
 p:=coalesce(p,'{"schema_version":1,"events":[]}'::jsonb);
 perform private.validate_simulation_event_plan(p,new.definition,true);
 insert into private.simulation_event_sessions(scenario_id,source_version_id,organization_id,plan)
 values(new.scenario_id,new.source_version_id,new.organization_id,p);
 for e in select value,ordinality from jsonb_array_elements(p->'events') with ordinality loop
  insert into private.simulation_event_instances(scenario_id,event_id,ordinal,definition)
   values(new.scenario_id,e.value->>'id',e.ordinality,e.value);
 end loop;
 return new;
end; $$;
create trigger simulation_event_instantiate after insert on private.simulation_template_instances
 for each row execute function private.simulation_event_instantiate();

create function private.simulation_event_history_guard() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'INVALID_TRANSITION';end if;
 if tg_table_name='simulation_event_sessions' then
  if (new.scenario_id,new.source_version_id,new.organization_id,new.plan) is distinct from (old.scenario_id,old.source_version_id,old.organization_id,old.plan) then raise exception 'INVALID_TRANSITION';end if;
 elsif tg_table_name='simulation_event_instances' then
  if (new.scenario_id,new.event_id,new.ordinal,new.definition,new.operation_id) is distinct from (old.scenario_id,old.event_id,old.ordinal,old.definition,old.operation_id)
   or old.state in ('EXECUTED','CANCELLED') or new.version<>old.version+1 or new.state='PLANNED'
   or new.attempts<old.attempts or new.attempts>old.attempts+1 then raise exception 'INVALID_TRANSITION';end if;
 elsif tg_table_name='simulation_event_annotations' then
  if (new.scenario_id,new.event_id,new.kind,new.revealed_at) is distinct from (old.scenario_id,old.event_id,old.kind,old.revealed_at)
   or new.version<>old.version+1 then raise exception 'INVALID_TRANSITION';end if;
 end if;
 return new;
end; $$;
create trigger simulation_event_session_history before update or delete on private.simulation_event_sessions for each row execute function private.simulation_event_history_guard();
create trigger simulation_event_instance_history before update or delete on private.simulation_event_instances for each row execute function private.simulation_event_history_guard();
create trigger simulation_event_annotation_history before update or delete on private.simulation_event_annotations for each row execute function private.simulation_event_history_guard();
create trigger simulation_event_history_immutable before update or delete on private.simulation_event_history for each row execute function private.audit_immutable();

create or replace function public.simulation_template_read(p_organization_id uuid,p_template_id uuid,p_version_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare t public.simulation_scenario_templates;v public.simulation_scenario_template_versions;
begin
 if not private.simulation_template_editor(p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into t from public.simulation_scenario_templates where id=p_template_id and (organization_id is null or organization_id=p_organization_id);
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into v from public.simulation_scenario_template_versions where template_id=t.id and (p_version_id is null or id=p_version_id) order by version desc limit 1;
 if not found then raise exception 'VALIDATION_FAILED';end if;
 return jsonb_build_object('id',t.id,'revision',t.revision::text,'builtin',t.organization_id is null,'archived',t.archived,
 'version_id',v.id,'version',v.version,'state',v.state,'definition',v.definition,'event_plan',coalesce((select plan from private.simulation_event_plans where version_id=v.id),'{"schema_version":1,"events":[]}'::jsonb));
end; $$;


create or replace function public.simulation_template_command(
 p_organization_id uuid,p_operation uuid,p_action text,p_template_id uuid,p_expected_version bigint,p_payload jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.simulation_scenario_templates;v public.simulation_scenario_template_versions;
 saved private.simulation_template_receipts;req jsonb;result_value jsonb;new_id uuid;new_version uuid;d jsonb;core jsonb;
 scenario uuid;allowed text[];plan_value jsonb;
begin
 if auth.uid() is null or p_operation is null or p_expected_version is null or p_action is null
 or p_action not in ('CREATE','COPY','REVISE','SAVE','PUBLISH','ARCHIVE','START') or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>115000 then raise exception 'VALIDATION_FAILED';end if;
 allowed:=case p_action when 'CREATE' then array['definition'] when 'SAVE' then array['definition','version_id']
 when 'COPY' then array['version_id'] when 'START' then array['version_id','incident_type_id'] else array[]::text[] end;
 if p_action in ('CREATE','SAVE') and p_payload?'event_plan' then allowed:=array_append(allowed,'event_plan');end if;
 perform private.sim_template_keys(p_payload,allowed);
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,146));
 perform private.simulation_template_locks(p_organization_id);
 req:=jsonb_build_object('action',p_action,'template',p_template_id,'expected',p_expected_version,'payload',p_payload);
 select * into saved from private.simulation_template_receipts where operation_id=p_operation;
 if found then
  if saved.actor<>auth.uid() or saved.organization_id<>p_organization_id or saved.request is distinct from req then raise exception 'OPERATION_REUSED';end if;
  return saved.result;
 end if;
 if p_action='CREATE' then
  if p_template_id is not null or p_expected_version<>0 then raise exception 'STALE_VERSION';end if;
  d:=p_payload->'definition';
 else
  select * into t from public.simulation_scenario_templates where id=p_template_id for update;
  if not found or (t.organization_id is not null and t.organization_id<>p_organization_id)
   or (t.organization_id is null and p_action<>'COPY') then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  if t.revision<>p_expected_version then raise exception 'STALE_VERSION';end if;
  if t.archived then raise exception 'INVALID_TRANSITION';end if;
  select * into v from public.simulation_scenario_template_versions where template_id=t.id
   and (not(p_payload?'version_id') or id=(p_payload->>'version_id')::uuid) order by version desc limit 1;
  if not found then raise exception 'VALIDATION_FAILED';end if;
  d:=v.definition;
 end if;
 plan_value:=coalesce((select plan from private.simulation_event_plans where version_id=v.id),'{"schema_version":1,"events":[]}'::jsonb);
 if p_action in ('CREATE','SAVE') then plan_value:=coalesce(p_payload->'event_plan',plan_value);end if;
 if p_action in ('CREATE','COPY') then
  perform private.validate_simulation_template(d,false);
  new_id:=gen_random_uuid();new_version:=gen_random_uuid();
  insert into public.simulation_scenario_templates(id,organization_id,created_by) values(new_id,p_organization_id,auth.uid());
  insert into public.simulation_scenario_template_versions(id,template_id,version,state,definition,created_by)
   values(new_version,new_id,1,'DRAFT',d,auth.uid());
  insert into private.simulation_event_plans(version_id,plan) values(new_version,plan_value);
  result_value:=public.simulation_template_read(p_organization_id,new_id);
 elsif p_action='REVISE' then
  if v.state<>'PUBLISHED' then raise exception 'INVALID_TRANSITION';end if;
  new_version:=gen_random_uuid();
  insert into public.simulation_scenario_template_versions(id,template_id,version,state,definition,created_by)
   values(new_version,t.id,v.version+1,'DRAFT',d,auth.uid());
  insert into private.simulation_event_plans(version_id,plan) values(new_version,plan_value);
 elsif p_action='SAVE' then
  if v.state<>'DRAFT' then raise exception 'INVALID_TRANSITION';end if;
  d:=p_payload->'definition';perform private.validate_simulation_template(d,false);
  update public.simulation_scenario_template_versions set definition=d where id=v.id;
  insert into private.simulation_event_plans(version_id,plan) values(v.id,plan_value)
   on conflict(version_id) do update set plan=excluded.plan;
 elsif p_action='PUBLISH' then
  if v.state<>'DRAFT' then raise exception 'INVALID_TRANSITION';end if;
  perform private.validate_simulation_template(d,true);
  perform private.validate_simulation_event_plan(plan_value,d,true);
  update public.simulation_scenario_template_versions set state='PUBLISHED',published_at=clock_timestamp() where id=v.id;
 elsif p_action='ARCHIVE' then
  update public.simulation_scenario_templates set archived=true where id=t.id;
 elsif p_action='START' then
  perform private.validate_simulation_template(d,true);
  perform private.validate_simulation_event_plan(plan_value,d,true);
  scenario:=gen_random_uuid();
  -- Only commander-facing material crosses into the normal incident projection.
  core:=jsonb_build_object('title',d#>>'{metadata,title}','summary',(d#>>'{metadata,initial_situation}')||E'\n\n'||(d#>>'{briefings,commander}'),
   'incident_type_id',p_payload->>'incident_type_id','priority','NORMAL','severity','UNKNOWN',
   'longitude',d#>'{world,incident_location,0}','latitude',d#>'{world,incident_location,1}','address',null,'unknown_location_reason','');
  result_value:=public.simulation_create_scenario(gen_random_uuid(),p_organization_id,null,0,jsonb_build_object('core',core,'scenario',
   jsonb_build_object('id',scenario,'template',d#>>'{metadata,category}','seed',0,'radius_m',d#>'{world,radius_m}',
    'longitude',d#>'{world,center,0}','latitude',d#>'{world,center,1}')));
  insert into private.simulation_template_instances(scenario_id,source_version_id,definition,organization_id,created_by)
   values(scenario,v.id,d,p_organization_id,auth.uid());
  result_value:=result_value||jsonb_build_object('initialization','WAITING_COMMAND','source_version_id',v.id);
 end if;
 if p_action in ('REVISE','SAVE','PUBLISH','ARCHIVE') then
  update public.simulation_scenario_templates set revision=revision+1,updated_at=clock_timestamp() where id=t.id;
  result_value:=public.simulation_template_read(p_organization_id,t.id);
 end if;
 -- Do not put instructor definitions into broadly visible audit DTOs.
 perform private.write_audit(p_organization_id,auth.uid(),'SIM_TEMPLATE_'||p_action,'simulation_scenario_templates',coalesce(new_id,t.id),null,
  jsonb_build_object('operation_id',p_operation,'source_version',v.id,'scenario',scenario));
 insert into private.simulation_template_receipts(operation_id,actor,organization_id,request,result)
 values(p_operation,auth.uid(),p_organization_id,req,result_value);
 return result_value;
exception when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
end; $$;


-- No synthetic personnel account. Existing human timeline entries retain their constraint.
alter table public.incident_timeline alter column actor_user_id drop not null;
alter table public.incident_timeline add column actor_origin text not null default 'HUMAN'
 check(actor_origin in ('HUMAN','SIMULATION_ENGINE'));
alter table public.incident_timeline add constraint incident_timeline_actor_origin
 check((actor_origin='HUMAN' and actor_user_id is not null) or
 (actor_origin='SIMULATION_ENGINE' and actor_user_id is null and event_code='SIM_SCENARIO_EVENT'));
create function private.simulation_event_timeline_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.actor_origin='SIMULATION_ENGINE' and not exists(
  select 1 from private.simulation_event_instances e join public.simulation_scenarios s on s.id=e.scenario_id
  where s.incident_id=new.incident_id and s.organization_id=new.actor_organization_id
   and e.operation_id=new.operation_id and e.state='EXECUTED'
 ) then raise exception 'INVALID_TRANSITION';end if;
 return new;
end; $$;
create trigger simulation_event_timeline_scope before insert on public.incident_timeline
 for each row execute function private.simulation_event_timeline_guard();

create function private.simulation_event_authority(p_scenario uuid) returns boolean
language sql volatile security definer set search_path='' as $$
 select private.agent_controller(p_scenario) and exists(
 select 1 from public.simulation_scenarios s join public.user_organizations m
 on m.user_id=s.created_by and m.organization_id=s.organization_id
 where s.id=p_scenario and m.role in ('MANAGER','ADMIN'));
$$;
create function private.simulation_event_eligible(p_scenario uuid,d jsonb,seconds_value bigint) returns boolean
language sql stable security definer set search_path='' as $$
 select case d#>>'{trigger,mode}'
 when 'SIMULATION_TIME' then seconds_value>=(d#>>'{trigger,offset_seconds}')::bigint
 when 'AFTER_EVENT' then exists(select 1 from private.simulation_event_instances e
  where e.scenario_id=p_scenario and e.event_id=d#>>'{trigger,event_id}' and e.state='EXECUTED')
 else false end;
$$;

-- Called only after the shared authorization/lifecycle/clock locks. No remote side effects.
-- An interrupted transaction rolls back the claim, effect, history and timeline together.
create function private.simulation_event_execute(p_scenario uuid,p_event text,p_manual boolean,p_actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e private.simulation_event_instances;s public.simulation_scenarios;seconds_value bigint;
 f jsonb;g jsonb;a private.simulation_event_annotations;outcome jsonb;state_value text:='EXECUTED';
 revision_value bigint;sequence_value bigint;error_value text;target text;
begin
 select * into s from public.simulation_scenarios where id=p_scenario;
 select * into e from private.simulation_event_instances where scenario_id=s.id and event_id=p_event for update;
 if not found then raise exception 'VALIDATION_FAILED';end if;
 if e.state='EXECUTED' then return e.result;end if;
 if e.state='CANCELLED' or e.attempts>=3 then raise exception 'INVALID_TRANSITION';end if;
 if s.status<>'RUNNING' then raise exception 'INVALID_SIMULATION_STATE';end if;
 if not private.simulation_event_authority(s.id) then raise exception 'NOT_AUTHORIZED';end if;
 if not exists(select 1 from private.simulation_template_instances where scenario_id=s.id and state='READY') then raise exception 'TEMPLATE_SETUP_REQUIRED';end if;
 select seconds into seconds_value from public.simulation_scenario_clock where scenario_id=s.id;
 if not coalesce(private.simulation_event_eligible(s.id,e.definition,seconds_value),false)
  and not(p_manual and e.definition#>>'{trigger,mode}'='MANUAL') then raise exception 'INVALID_TRANSITION';end if;
 begin
  f:=e.definition->'effect';
  if e.definition->>'type' in ('HAZARD_REVEAL','ACCESS_RESTRICTION','HAZARD_UPDATE') then
   if f->'source_object_id'<>'null'::jsonb then
    select o->'geometry' into g from private.simulation_template_instances p,
     lateral jsonb_array_elements(p.definition->'initial_objects') o
     where p.scenario_id=s.id and o->>'id'=f->>'source_object_id';
   else g:=f->'geometry';end if;
   perform private.validate_incident_geometry(g,array['Point','Polygon']);
   target:=case when e.definition->>'type'='HAZARD_UPDATE' then f->>'target_event_id' else e.event_id end;
   if e.definition->>'type'='HAZARD_UPDATE' then
    select * into a from private.simulation_event_annotations where scenario_id=s.id and event_id=target for update;
    if not found or a.kind<>'HAZARD_REVEAL' then raise exception 'EVENT_TARGET_UNAVAILABLE';end if;
    if a.version<>(f->>'expected_version')::bigint then raise exception 'STALE_VERSION';end if;
    update private.simulation_event_annotations set geometry=g,title=e.definition->>'title',description=e.definition->>'description',version=version+1
     where scenario_id=s.id and event_id=target returning * into a;
   else
    insert into private.simulation_event_annotations(scenario_id,event_id,title,description,kind,geometry)
     values(s.id,e.event_id,e.definition->>'title',e.definition->>'description',e.definition->>'type',g) returning * into a;
   end if;
   outcome:=jsonb_build_object('annotation_id',target,'annotation_version',a.version::text,'geometry',a.geometry,'title',a.title,'description',a.description,'kind',a.kind);
  else outcome:=jsonb_build_object('type',e.definition->>'type','title',e.definition->>'title','description',e.definition->>'description');end if;
 exception when others then
  error_value:=case when sqlerrm in ('STALE_VERSION','EVENT_TARGET_UNAVAILABLE','INVALID_GEOMETRY','GEOMETRY_TOO_LARGE','UNSUPPORTED_GEOMETRY') then sqlerrm else 'EVENT_EXECUTION_FAILED' end;
  state_value:=case when error_value='EVENT_EXECUTION_FAILED' then 'RETRYABLE_FAILURE' else 'BLOCKED' end;
  outcome:=jsonb_build_object('error',error_value);
 end;
 update private.simulation_event_instances set state=state_value,version=version+1,attempts=attempts+1,result=outcome,
 executed_at=case when state_value='EXECUTED' then clock_timestamp() end,simulation_seconds=seconds_value
 where scenario_id=s.id and event_id=e.event_id returning * into e;
 insert into private.simulation_event_history(scenario_id,event_id,event_version,operation_id,actor,origin,state,simulation_seconds,result)
 values(s.id,e.event_id,e.version,e.operation_id,p_actor,case when p_actor is null then 'SIMULATION_ENGINE' else 'INSTRUCTOR' end,state_value,seconds_value,outcome);
 if state_value='EXECUTED' then
  update public.incidents set revision=revision+1,timeline_sequence=timeline_sequence+1,updated_at=clock_timestamp()
   where id=s.incident_id returning revision,timeline_sequence into revision_value,sequence_value;
  insert into public.incident_timeline(incident_id,sequence,revision,operation_id,event_ordinal,event_code,actor_user_id,actor_organization_id,actor_origin,data)
  values(s.incident_id,sequence_value,revision_value,e.operation_id,1,'SIM_SCENARIO_EVENT',null,s.organization_id,'SIMULATION_ENGINE',
   jsonb_build_object('source','SIMULATED','scenario_event_id',e.event_id,'type',e.definition->>'type',
    'reason',(e.definition->>'title')||E'\n'||(e.definition->>'description'),'simulation_seconds',seconds_value));
 end if;
 return jsonb_build_object('state',e.state,'version',e.version::text,'result',e.result);
end; $$;

create function public.simulation_scenario_event_command(p_organization_id uuid,p_incident_id uuid,p_operation uuid,
 p_event_id text,p_expected_version bigint,p_action text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios;e private.simulation_event_instances;saved private.simulation_template_receipts;
 req jsonb;result_value jsonb;seconds_value bigint;
begin
 if auth.uid() is null or p_operation is null or p_expected_version is null or coalesce(p_action,'') not in ('TRIGGER','RETRY','CANCEL')
 or length(coalesce(p_event_id,'')) not between 1 and 64 then raise exception 'VALIDATION_FAILED';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,146));
 select * into s from public.simulation_scenarios where incident_id=p_incident_id and organization_id=p_organization_id;
 if not found then raise exception 'NOT_AUTHORIZED';end if;
 perform private.agent_locks(s.id);
 if not private.simulation_template_editor(p_organization_id) or not private.simulation_controller(s.id,p_organization_id) then raise exception 'NOT_AUTHORIZED';end if;
 req:=jsonb_build_object('incident',p_incident_id,'event',p_event_id,'expected',p_expected_version,'action',p_action);
 select * into saved from private.simulation_template_receipts where operation_id=p_operation;
 if found then
  if saved.actor<>auth.uid() or saved.organization_id<>p_organization_id or saved.request is distinct from req then raise exception 'OPERATION_REUSED';end if;
  return saved.result;
 end if;
 select * into s from public.simulation_scenarios where id=s.id;
 select * into e from private.simulation_event_instances where scenario_id=s.id and event_id=p_event_id for update;
 if not found then raise exception 'VALIDATION_FAILED';end if;
 if e.version<>p_expected_version then raise exception 'STALE_VERSION';end if;
 if s.status not in ('RUNNING','PAUSED') or e.state in ('EXECUTED','CANCELLED') then raise exception 'INVALID_TRANSITION';end if;
 if p_action='CANCEL' then
  select seconds into seconds_value from public.simulation_scenario_clock where scenario_id=s.id;
  update private.simulation_event_instances set state='CANCELLED',version=version+1,result=jsonb_build_object('cancelled',true)
   where scenario_id=s.id and event_id=e.event_id returning * into e;
  insert into private.simulation_event_history(scenario_id,event_id,event_version,operation_id,actor,origin,state,simulation_seconds,result)
   values(s.id,e.event_id,e.version,e.operation_id,auth.uid(),'INSTRUCTOR','CANCELLED',seconds_value,e.result);
  result_value:=jsonb_build_object('state',e.state,'version',e.version::text,'result',e.result);
 else
  if p_action='TRIGGER' and (e.state<>'PLANNED' or e.definition#>>'{trigger,mode}'<>'MANUAL')
   or p_action='RETRY' and e.state not in ('BLOCKED','RETRYABLE_FAILURE') then raise exception 'INVALID_TRANSITION';end if;
  result_value:=private.simulation_event_execute(s.id,e.event_id,true,auth.uid());
 end if;
 insert into private.simulation_template_receipts(operation_id,actor,organization_id,request,result)
 values(p_operation,auth.uid(),p_organization_id,req,result_value);
 return result_value;
end; $$;

create function public.simulation_scenario_event_batch() returns jsonb
language plpgsql security definer set search_path='' set statement_timeout='2500ms' set lock_timeout='100ms' as $$
declare session_row record;e record;s public.simulation_scenarios;c public.simulation_scenario_clock;processed integer:=0;blocked integer:=0;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'NOT_AUTHORIZED';end if;
 if not private.simulation_enabled() then return jsonb_build_object('processed',0);end if;
 for session_row in
  select p.scenario_id from private.simulation_event_sessions p join public.simulation_scenarios s on s.id=p.scenario_id
  where s.status='RUNNING' and exists(select 1 from private.simulation_event_instances e where e.scenario_id=s.id and e.state='PLANNED')
  order by p.last_scan_at nulls first,p.scenario_id limit 5 for update of p skip locked
 loop
  begin
   perform private.agent_locks(session_row.scenario_id);
   update private.simulation_event_sessions set last_scan_at=clock_timestamp() where scenario_id=session_row.scenario_id;
   select * into s from public.simulation_scenarios where id=session_row.scenario_id;
   select * into c from public.simulation_scenario_clock where scenario_id=s.id;
   if s.status<>'RUNNING' or not private.simulation_event_authority(s.id) then blocked:=blocked+1;continue;end if;
   for e in select event_id from private.simulation_event_instances
    where scenario_id=s.id and state='PLANNED' and private.simulation_event_eligible(s.id,definition,c.seconds)
    order by coalesce((definition#>>'{trigger,offset_seconds}')::bigint,c.seconds),ordinal limit 2
   loop
    perform private.simulation_event_execute(s.id,e.event_id,false,null);processed:=processed+1;
   end loop;
  exception when lock_not_available then blocked:=blocked+1;
  end;
 end loop;
 return jsonb_build_object('processed',processed,'blocked',blocked);
end; $$;

-- The ordinary DTO has no scheduled IDs, definitions, counts or future geometry.
create function public.simulation_scenario_events(p_organization_id uuid,p_incident_id uuid,p_instructor boolean default false) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare s public.simulation_scenarios;c public.simulation_scenario_clock;can_control boolean;rows_value jsonb;annotations_value jsonb;
begin
 if not private.incident_acting_member(p_organization_id) or not private.can_read_incident(p_incident_id) then raise exception 'NOT_AUTHORIZED';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 if not found then return null;end if;
 if not private.simulation_visible(p_incident_id,p_organization_id) and not private.simulation_controller(s.id,p_organization_id) then raise exception 'NOT_AUTHORIZED';end if;
 if not private.simulation_enabled() then raise exception 'NOT_AUTHORIZED';end if;
 can_control:=coalesce(private.simulation_template_editor(p_organization_id) and private.simulation_controller(s.id,p_organization_id),false);
 if p_instructor is null or p_instructor and not can_control then raise exception 'NOT_AUTHORIZED';end if;
 select * into c from public.simulation_scenario_clock where scenario_id=s.id;
 select coalesce(jsonb_agg(jsonb_build_object('id',e.event_id,'type',e.definition->>'type','title',e.definition->>'title','description',e.definition->>'description',
  'state',e.state,'version',e.version::text,'attempts',e.attempts,'result',e.result,'executed_at',e.executed_at,'simulation_seconds',e.simulation_seconds)
  ||case when p_instructor then jsonb_build_object('definition',e.definition,'ordinal',e.ordinal,
   'blocked_reason',case when e.state in ('EXECUTED','CANCELLED') then null
    when s.status<>'RUNNING' then s.status when not private.simulation_event_authority(s.id) then 'AUTHORITY_REVOKED'
    when e.definition#>>'{trigger,mode}'='AFTER_EVENT' and not private.simulation_event_eligible(s.id,e.definition,coalesce(c.seconds,0)) then 'DEPENDENCY_PENDING' end)
   else '{}'::jsonb end order by e.ordinal),'[]') into rows_value
 from private.simulation_event_instances e where e.scenario_id=s.id and (p_instructor or e.state='EXECUTED');
 select coalesce(jsonb_agg(jsonb_build_object('id',a.event_id,'title',a.title,'description',a.description,'type',a.kind,'version',a.version::text,
 'geometry',a.geometry,'revealed_at',a.revealed_at) order by a.event_id),'[]') into annotations_value
 from private.simulation_event_annotations a where a.scenario_id=s.id;
 return jsonb_build_object('can_control',can_control,'status',s.status,'seconds',coalesce(c.seconds,0),
 'last_runner_at',c.last_runner_at,'worker_stale',s.status='RUNNING' and (c.last_runner_at is null or c.last_runner_at<clock_timestamp()-interval '30 seconds'),
 'last_event_scan_at',(select last_scan_at from private.simulation_event_sessions where scenario_id=s.id),
 'events',rows_value,'annotations',annotations_value);
end; $$;
create function public.simulation_scenario_event_history(p_organization_id uuid,p_incident_id uuid,p_after bigint default 0) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare s public.simulation_scenarios;
begin
 select * into s from public.simulation_scenarios where incident_id=p_incident_id and organization_id=p_organization_id;
 if not found or not private.simulation_template_editor(p_organization_id) or not private.simulation_controller(s.id,p_organization_id) then raise exception 'NOT_AUTHORIZED';end if;
 return coalesce((select jsonb_agg(q.dto order by q.id) from(
 select h.id,jsonb_build_object('id',h.id::text,'event_id',h.event_id,'version',h.event_version::text,'operation_id',h.operation_id,
 'actor',h.actor,'origin',h.origin,'state',h.state,'seconds',h.simulation_seconds,'result',h.result,'recorded_at',h.recorded_at) dto
 from private.simulation_event_history h where h.scenario_id=s.id and h.id>greatest(coalesce(p_after,0),0) order by h.id limit 25) q),'[]');
end; $$;

create or replace function public.incident_timeline_page(p_incident_id uuid,p_acting_organization_id uuid,
 p_after_sequence bigint default 0,p_limit integer default 100)
returns jsonb language sql stable security definer set search_path='' as $$
 select case when public.incident_context(p_incident_id,p_acting_organization_id) is null then null else
 jsonb_build_object('contract_version',1,'incident_id',p_incident_id,
 'events',coalesce((select jsonb_agg(e.dto order by e.sequence) from (
  select it.sequence,jsonb_build_object('id',it.id,'sequence',it.sequence::text,'revision',it.revision::text,
   'operation_id',it.operation_id,'event_ordinal',it.event_ordinal,'event_code',it.event_code,
   'actor_user_id',it.actor_user_id,'actor_name',pr.display_name,'actor_organization_id',it.actor_organization_id,'actor_organization_name',o.name,
   'subject_name',coalesce(subject_org.name,assigned_profile.display_name,nominee.display_name),
   'participation_id',it.participation_id,'assignment_id',it.assignment_id,'recorded_at',it.recorded_at,'occurred_at',it.occurred_at,'data',it.data) dto
  from public.incident_timeline it left join public.profiles pr on pr.id=it.actor_user_id join public.organizations o on o.id=it.actor_organization_id
  left join public.incident_participants ip on ip.id=it.participation_id left join public.organizations subject_org on subject_org.id=ip.organization_id
  left join public.incident_role_assignments a on a.id=it.assignment_id left join public.profiles assigned_profile on assigned_profile.id=a.user_id
  left join public.profiles nominee on nominee.id::text=it.data->>'user_id'
  where it.incident_id=p_incident_id and it.sequence>greatest(coalesce(p_after_sequence,0),0)
  order by it.sequence limit least(greatest(coalesce(p_limit,100),1),200)) e),'[]'),
 'high_watermark',(select i.timeline_sequence::text from public.incidents i where i.id=p_incident_id)) end;
$$;
alter table private.simulation_event_plans enable row level security;
revoke all on private.simulation_event_plans from public,anon,authenticated,service_role;
create trigger simulation_event_plans_no_truncate before truncate on private.simulation_event_plans for each statement execute function private.audit_immutable();
alter table private.simulation_event_sessions enable row level security;
revoke all on private.simulation_event_sessions from public,anon,authenticated,service_role;
create trigger simulation_event_sessions_no_truncate before truncate on private.simulation_event_sessions for each statement execute function private.audit_immutable();
alter table private.simulation_event_instances enable row level security;
revoke all on private.simulation_event_instances from public,anon,authenticated,service_role;
create trigger simulation_event_instances_no_truncate before truncate on private.simulation_event_instances for each statement execute function private.audit_immutable();
alter table private.simulation_event_annotations enable row level security;
revoke all on private.simulation_event_annotations from public,anon,authenticated,service_role;
create trigger simulation_event_annotations_no_truncate before truncate on private.simulation_event_annotations for each statement execute function private.audit_immutable();
alter table private.simulation_event_history enable row level security;
revoke all on private.simulation_event_history from public,anon,authenticated,service_role;
create trigger simulation_event_history_no_truncate before truncate on private.simulation_event_history for each statement execute function private.audit_immutable();
revoke all on function private.validate_simulation_event_plan(jsonb,jsonb,boolean) from public,anon,authenticated,service_role;
revoke all on function private.simulation_event_plan_guard() from public,anon,authenticated,service_role;
revoke all on function private.simulation_event_instantiate() from public,anon,authenticated,service_role;
revoke all on function private.simulation_event_history_guard() from public,anon,authenticated,service_role;
revoke all on function private.simulation_event_timeline_guard() from public,anon,authenticated,service_role;
revoke all on function private.simulation_event_authority(uuid) from public,anon,authenticated,service_role;
revoke all on function private.simulation_event_eligible(uuid,jsonb,bigint) from public,anon,authenticated,service_role;
revoke all on function private.simulation_event_execute(uuid,text,boolean,uuid) from public,anon,authenticated,service_role;
revoke all on function public.simulation_scenario_event_command(uuid,uuid,uuid,text,bigint,text) from public,anon,authenticated,service_role;
grant execute on function public.simulation_scenario_event_command(uuid,uuid,uuid,text,bigint,text) to authenticated;
revoke all on function public.simulation_scenario_events(uuid,uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function public.simulation_scenario_events(uuid,uuid,boolean) to authenticated;
revoke all on function public.simulation_scenario_event_history(uuid,uuid,bigint) from public,anon,authenticated,service_role;
grant execute on function public.simulation_scenario_event_history(uuid,uuid,bigint) to authenticated;
revoke all on function public.simulation_scenario_event_batch() from public,anon,authenticated,service_role;
grant execute on function public.simulation_scenario_event_batch() to service_role;
revoke all on sequence private.simulation_event_history_id_seq from public,anon,authenticated,service_role;
commit;
