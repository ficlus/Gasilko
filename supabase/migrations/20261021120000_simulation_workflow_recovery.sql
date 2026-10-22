-- M14.6C.2: narrow recovery reads and forward-only validation diagnostics.
begin;
create function public.simulation_operation_resolve(p_organization_id uuid,p_name text,p_args jsonb) returns jsonb
language plpgsql stable security definer set search_path='' as $workflow$
declare op uuid;req jsonb;saved private.simulation_template_receipts;core private.incident_operation_receipts;incident uuid;
begin
 if not private.is_active_user() or not private.incident_acting_member(p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if jsonb_typeof(p_args) is distinct from 'object' or octet_length(p_args::text)>131072 then raise exception 'VALIDATION_FAILED';end if;
 op:=(p_args->>'p_operation')::uuid;
 if op is null then raise exception 'VALIDATION_FAILED';end if;
 if p_name in ('simulation_template_command','simulation_template_initialize') then
  if not private.simulation_template_editor(p_organization_id) or (p_args->>'p_organization_id')::uuid is distinct from p_organization_id then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  if p_name='simulation_template_command' then
   req:=jsonb_build_object('action',p_args->>'p_action','template',(p_args->>'p_template_id')::uuid,'expected',(p_args->>'p_expected_version')::bigint,'payload',p_args->'p_payload');
  else
   incident:=(p_args->>'p_incident_id')::uuid;
   if not private.simulation_visible(incident,p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
   req:=jsonb_build_object('action','INITIALIZE','incident',incident,'expected',(p_args->>'p_expected_version')::bigint,'incident_version',(p_args->>'p_incident_version')::bigint);
  end if;
  select * into saved from private.simulation_template_receipts where operation_id=op and actor=auth.uid() and organization_id=p_organization_id and request=req;
  if found then return jsonb_build_object('state','CONFIRMED','data',saved.result);end if;
 elsif p_name='simulation_command' then
  incident:=(p_args->>'p_incident_id')::uuid;
  if (p_args->>'p_acting_organization_id')::uuid is distinct from p_organization_id
   or not private.simulation_operator(p_organization_id) or not private.simulation_visible(incident,p_organization_id)
   or not exists(select 1 from public.simulation_scenarios where incident_id=incident and organization_id=p_organization_id)
   then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
  req:=jsonb_build_object('command','SIM_'||(p_args->>'p_action'),'org',p_organization_id,'incident',incident,'expected',(p_args->>'p_expected_version')::bigint,'payload',p_args->'p_payload');
  select * into core from private.incident_operation_receipts where operation_id=op and actor_user_id=auth.uid() and acting_organization_id=p_organization_id and incident_id=incident and command_code='SIM_'||(p_args->>'p_action') and request=req;
  if found then return jsonb_build_object('state','CONFIRMED','data',core.result);end if;
 else raise exception 'VALIDATION_FAILED';
 end if;
 return jsonb_build_object('state','OUTCOME_UNKNOWN');
end; $workflow$;
revoke all on function public.simulation_operation_resolve(uuid,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.simulation_operation_resolve(uuid,text,jsonb) to authenticated;
create or replace function private.validate_simulation_template(d jsonb,ready boolean) returns void
language plpgsql immutable set search_path='' as $workflow$
declare v jsonb;m jsonb:=d->'metadata';w jsonb:=d->'world';cfg jsonb:=d->'simulation_defaults';ids text[]:=array['center','incident','bounds','drawing'];g jsonb;
begin
 if d is null or octet_length(d::text)>48000 then raise exception 'VALIDATION_FAILED'; end if;
 perform private.sim_template_keys(d,array['schema_version','metadata','world','initial_objects','virtual_units','briefings','simulation_defaults']);
 if d->'schema_version' is distinct from '1'::jsonb then raise exception 'VALIDATION_FAILED'; end if;
 perform private.sim_template_keys(m,array['title','description','category','difficulty','objectives','duration_minutes','initial_situation']);
 perform private.sim_template_text(m->'title',200,true);perform private.sim_template_text(m->'description',2000);
 perform private.sim_template_text(m->'initial_situation',4000);
 if coalesce(m->>'category','') not in ('STRUCTURE_FIRE','WILDFIRE','TRAFFIC_ACCIDENT','SANDBOX')
 or coalesce(m->>'difficulty','') not in ('BEGINNER','INTERMEDIATE','ADVANCED')
 or jsonb_typeof(m->'duration_minutes') is distinct from 'number'
 or (m->>'duration_minutes')::numeric<>trunc((m->>'duration_minutes')::numeric)
 or not((m->>'duration_minutes')::numeric between 5 and 480)
 or jsonb_typeof(m->'objectives') is distinct from 'array' or jsonb_array_length(m->'objectives')>20 then raise exception 'VALIDATION_FAILED'; end if;
 for v in select value from jsonb_array_elements(m->'objectives') loop perform private.sim_template_text(v,500,true);end loop;
 perform private.sim_template_keys(w,array['center','incident_location','radius_m']);
 perform private.sim_template_position(w->'center',ready);perform private.sim_template_position(w->'incident_location',ready);
 if jsonb_typeof(w->'radius_m') is distinct from 'number' or (w->>'radius_m')::numeric<>trunc((w->>'radius_m')::numeric)
 or not((w->>'radius_m')::numeric between 10 and 5000) then raise exception 'VALIDATION_FAILED'; end if;
 perform private.sim_template_keys(d->'briefings',array['commander','instructor']);
 perform private.sim_template_text(d#>'{briefings,commander}',4000);perform private.sim_template_text(d#>'{briefings,instructor}',4000);
 perform private.sim_template_keys(cfg,array['clock_scale','automatic_execution','response_profile']);
 if cfg->'clock_scale' not in ('1'::jsonb,'5'::jsonb,'10'::jsonb) or cfg->'automatic_execution' is distinct from 'false'::jsonb
 or coalesce(cfg->>'response_profile','') not in ('NORMAL','SLOW_RESPONSE','NO_RESPONSE','BREAKDOWN','COMMUNICATION_LOSS','ROUTE_BLOCKED') then raise exception 'VALIDATION_FAILED'; end if;
 if jsonb_typeof(d->'initial_objects') is distinct from 'array' or jsonb_array_length(d->'initial_objects')>40
 or jsonb_typeof(d->'virtual_units') is distinct from 'array' or jsonb_array_length(d->'virtual_units')>30 then raise exception 'VALIDATION_FAILED'; end if;
 for v in select value from jsonb_array_elements(d->'initial_objects') loop
  perform private.sim_template_keys(v,array['id','kind','label','description','geometry']);
  if coalesce(v->>'id','') !~ '^[a-zA-Z0-9_-]{1,64}$' or v->>'id'=any(ids) then raise exception 'VALIDATION_FAILED'; end if;
  ids:=array_append(ids,v->>'id');perform private.sim_template_text(v->'label',200,true);perform private.sim_template_text(v->'description',2000);
  if coalesce(v->>'kind','') not in ('COMMAND_POST','STAGING','TRIAGE_POINT','WATER_SOURCE','ACCESS_POINT','NOTE','HAZARD','PERIMETER') then raise exception 'VALIDATION_FAILED'; end if;
  g:=v->'geometry';
  if g='null'::jsonb and not ready then continue;end if;
  perform private.sim_template_keys(g,array['type','coordinates']);
  -- Bound designer geometry more tightly than general COP.
  if g->>'type'='Polygon' and (jsonb_array_length(g->'coordinates')<>1 or jsonb_array_length(g#>'{coordinates,0}')>33)
   or g->>'type'='LineString' and jsonb_array_length(g->'coordinates')>32 then raise exception 'VALIDATION_FAILED';end if;
  perform private.validate_incident_geometry(g,case v->>'kind' when 'HAZARD' then array['Point','Polygon']
   when 'PERIMETER' then array['LineString','Polygon'] else array['Point'] end);

 end loop;
 for v in select value from jsonb_array_elements(d->'virtual_units') loop
  perform private.sim_template_keys(v,array['id','position','heading','kind']);
  if coalesce(v->>'id','') !~ '^[a-zA-Z0-9_-]{1,64}$' or v->>'id'=any(ids) or v->>'kind' is distinct from 'OTHER'
  or jsonb_typeof(v->'heading') is distinct from 'number' or not((v->>'heading')::numeric>=0 and (v->>'heading')::numeric<360) then raise exception 'VALIDATION_FAILED';end if;
  ids:=array_append(ids,v->>'id');perform private.sim_template_position(v->'position',ready);
 end loop;
exception when raise_exception or invalid_text_representation or numeric_value_out_of_range or invalid_parameter_value then
 raise exception 'INVALID_TEMPLATE';
end; $workflow$;
create or replace function private.validate_simulation_event_plan(p jsonb,d jsonb,ready boolean) returns void
language plpgsql immutable set search_path='' as $workflow$
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
exception when raise_exception or invalid_text_representation or numeric_value_out_of_range or invalid_parameter_value then
 raise exception 'INVALID_EVENT_PLAN';
end; $workflow$;
create or replace function private.validate_hazard_plan(p jsonb,events jsonb) returns void
language plpgsql immutable set search_path='' as $workflow$
declare m jsonb;o jsonb;z jsonb;e jsonb;xy jsonb;ids text[]:='{}';origin_ids text[];zone_ids text[];
 radius numeric;cell numeric;center jsonb;wildfires integer:=0;
begin
 perform private.sim_template_keys(p,array['schema_version','models']);
 if p->'schema_version' is distinct from '1'::jsonb or jsonb_typeof(p->'models') is distinct from 'array'
 or jsonb_array_length(p->'models')>4 or octet_length(p::text)>30000 then raise exception 'VALIDATION_FAILED';end if;
 for m in select value from jsonb_array_elements(p->'models') loop
  perform private.sim_template_keys(m,array['id','type','title','enabled','visibility','center','radius_m','cell_m','wind_direction','wind_speed','fuel','moisture','spread','decline_seconds','origins','blocked','zones','effects']);
  if jsonb_typeof(m->'id') is distinct from 'string' or (m->>'id')!~'^[a-zA-Z0-9_-]{1,64}$' or m->>'id'=any(ids)
   or coalesce(m->>'type','') not in ('STRUCTURE_FIRE','WILDFIRE')
   or coalesce(m->>'visibility','') not in ('START','HIDDEN') or jsonb_typeof(m->'enabled') is distinct from 'boolean' then raise exception 'VALIDATION_FAILED';end if;
  ids:=array_append(ids,m->>'id');perform private.sim_template_text(m->'title',100,true);
  center:=m->'center';perform private.sim_template_position(center,true);
  if abs((center->>1)::numeric)>75 or abs((center->>0)::numeric)>179 then raise exception 'VALIDATION_FAILED';end if;
  radius:=private.hazard_number(m->'radius_m',25,250);cell:=private.hazard_number(m->'cell_m',25,50);
  if cell not in (25,50) or radius/cell<>trunc(radius/cell) then raise exception 'VALIDATION_FAILED';end if;
  if m->>'type'='WILDFIRE' then wildfires:=wildfires+1;if wildfires>1 then raise exception 'VALIDATION_FAILED';end if;end if;
  perform private.hazard_number(m->'wind_direction',0,359.99);perform private.hazard_number(m->'wind_speed',0,20);
  perform private.hazard_number(m->'fuel',0.1,1);perform private.hazard_number(m->'moisture',0,1);
  perform private.hazard_number(m->'spread',0,2);perform private.hazard_number(m->'decline_seconds',0,28800);
  if jsonb_typeof(m->'origins') is distinct from 'array' or jsonb_array_length(m->'origins') not between 1 and 8
   or jsonb_typeof(m->'blocked') is distinct from 'array' or jsonb_array_length(m->'blocked')>441
   or jsonb_typeof(m->'zones') is distinct from 'array' or jsonb_array_length(m->'zones')>8
   or jsonb_typeof(m->'effects') is distinct from 'array' or jsonb_array_length(m->'effects')>40 then raise exception 'VALIDATION_FAILED';end if;
  origin_ids:='{}';
  for o in select value from jsonb_array_elements(m->'origins') loop
   perform private.sim_template_keys(o,array['id','position','intensity','initial']);
   if jsonb_typeof(o->'id') is distinct from 'string' or (o->>'id')!~'^[a-zA-Z0-9_-]{1,64}$' or o->>'id'=any(origin_ids)
    or jsonb_typeof(o->'initial') is distinct from 'boolean' then raise exception 'VALIDATION_FAILED';end if;
   origin_ids:=array_append(origin_ids,o->>'id');
   perform private.sim_template_position(o->'position',true);xy:=private.hazard_xy(o->'position',center);
   if sqrt(power((xy->>0)::numeric,2)+power((xy->>1)::numeric,2))>radius then raise exception 'VALIDATION_FAILED';end if;
   perform private.hazard_number(o->'intensity',0.05,1);
   if m->>'type'='WILDFIRE' and (sqrt(power(round((xy->>0)::numeric/cell),2)+power(round((xy->>1)::numeric/cell),2))*cell+cell/sqrt(2)>radius) then raise exception 'VALIDATION_FAILED';end if;
   if exists(select 1 from jsonb_array_elements(m->'blocked') b where b=jsonb_build_array(round((xy->>0)::numeric/cell),round((xy->>1)::numeric/cell))) then raise exception 'VALIDATION_FAILED';end if;
  end loop;
  for o in select value from jsonb_array_elements(m->'blocked') loop
   if jsonb_typeof(o) is distinct from 'array' or jsonb_array_length(o)<>2 then raise exception 'VALIDATION_FAILED';end if;
   perform private.hazard_number(o->0,-radius/cell,radius/cell);perform private.hazard_number(o->1,-radius/cell,radius/cell);
   if (o->>0)::numeric<>trunc((o->>0)::numeric) or (o->>1)::numeric<>trunc((o->>1)::numeric) then raise exception 'VALIDATION_FAILED';end if;
  end loop;
  zone_ids:='{}';
  for z in select value from jsonb_array_elements(m->'zones') loop
   perform private.sim_template_keys(z,array['id','kind','position','radius_m']);
   if jsonb_typeof(z->'id') is distinct from 'string' or (z->>'id')!~'^[a-zA-Z0-9_-]{1,64}$' or z->>'id'=any(zone_ids)
    or coalesce(z->>'kind','') not in ('HEAT_ZONE','SMOKE_ZONE','COLLAPSE_RISK','HAZARDOUS_MATERIAL','ACCESS_HAZARD') then raise exception 'VALIDATION_FAILED';end if;
   zone_ids:=array_append(zone_ids,z->>'id');perform private.sim_template_position(z->'position',true);
   xy:=private.hazard_xy(z->'position',center);
   if sqrt(power((xy->>0)::numeric,2)+power((xy->>1)::numeric,2))+private.hazard_number(z->'radius_m',5,250)>radius then raise exception 'VALIDATION_FAILED';end if;
  end loop;
  for e in select value from jsonb_array_elements(m->'effects') loop
   perform private.sim_template_keys(e,array['event_id','effect']);
   if jsonb_typeof(e->'event_id') is distinct from 'string' or not exists(select 1 from jsonb_array_elements(events->'events') ev where ev->>'id'=e->>'event_id') then raise exception 'VALIDATION_FAILED';end if;
   perform private.hazard_effect_valid(e->'effect',m);
  end loop;
  if exists(select 1 from jsonb_array_elements(m->'effects') as effect_row(value) group by effect_row.value->>'event_id' having count(*)>1) then raise exception 'VALIDATION_FAILED';end if;
 end loop;
exception when raise_exception or invalid_text_representation or numeric_value_out_of_range or invalid_parameter_value then
 raise exception 'INVALID_HAZARD_PLAN';
end; $workflow$;
create or replace function public.simulation_template_list(p_organization_id uuid,p_query text default '',p_category text default '',p_status text default '',p_after uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $workflow$
begin
 if not private.simulation_template_editor(p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if p_query is null or length(p_query)>100 or p_category is null or p_status is null or p_category not in ('','STRUCTURE_FIRE','WILDFIRE','TRAFFIC_ACCIDENT','SANDBOX')
 or p_status not in ('','BUILT_IN','ORGANIZATION','DRAFT','PUBLISHED','ARCHIVED') then raise exception 'VALIDATION_FAILED';end if;
 return coalesce((select jsonb_agg(q.dto order by q.id) from (
 select t.id,jsonb_build_object('id',t.id,'revision',t.revision::text,'builtin',t.organization_id is null,'archived',t.archived,
 'updated_at',t.updated_at,'organization_id',t.organization_id,'version_id',v.id,'version',v.version,'state',v.state,'title',v.definition#>>'{metadata,title}','category',v.definition#>>'{metadata,category}',
 'description',v.definition#>>'{metadata,description}') dto
 from public.simulation_scenario_templates t join lateral(select * from public.simulation_scenario_template_versions where template_id=t.id order by version desc limit 1) v on true
 where (t.organization_id is null or t.organization_id=p_organization_id) and (p_after is null or t.id>p_after)
 and (p_query='' or strpos(lower(v.definition#>>'{metadata,title}'),lower(p_query))>0)
 and (p_category='' or v.definition#>>'{metadata,category}'=p_category)
 and ((p_status='' and not t.archived) or p_status='ARCHIVED' and t.archived or not t.archived and
 (p_status='BUILT_IN' and t.organization_id is null or p_status='ORGANIZATION' and t.organization_id=p_organization_id or v.state=p_status))
 order by t.id limit 25) q),'[]');
end; $workflow$;
create or replace function public.simulation_template_initialization(p_organization_id uuid,p_incident_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $workflow$
declare s public.simulation_scenarios;p private.simulation_template_instances;i public.incidents;
begin
 if not private.simulation_enabled() or not private.simulation_visible(p_incident_id,p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 select * into p from private.simulation_template_instances where scenario_id=s.id;
 if not found then return null;end if;
 select * into i from public.incidents where id=p_incident_id;
 -- Intentionally no instructor briefing, objectives or full definition.
 return jsonb_build_object('state',p.state,'scenario_version',s.version::text,'incident_version',i.version::text,
 'source_version_id',p.source_version_id,'source_title',p.definition#>>'{metadata,title}','duration_minutes',p.definition#>'{metadata,duration_minutes}',
 'source_version',(select version from public.simulation_scenario_template_versions where id=p.source_version_id),
 'preview',(select published_at is null or published_at>p.created_at from public.simulation_scenario_template_versions where id=p.source_version_id),
 'incident_status',i.status,'simulation_status',s.status,'objects',jsonb_array_length(p.definition->'initial_objects'),'units',jsonb_array_length(p.definition->'virtual_units'),
 'clock_scale',case when p.organization_id=p_organization_id and private.simulation_template_editor(p_organization_id) then p.definition#>'{simulation_defaults,clock_scale}' end,
 'response_profile',case when p.organization_id=p_organization_id and private.simulation_template_editor(p_organization_id) then p.definition#>>'{simulation_defaults,response_profile}' end,
 'can_initialize',p.state='WAITING_COMMAND' and i.status in ('ACTIVE','STABILIZED') and s.status='DRAFT'
 and private.simulation_template_editor(p_organization_id) and private.simulation_controller(s.id,p_organization_id)
 and (jsonb_array_length(p.definition->'virtual_units')=0 or private.can_manage_incident_unit(i.id,p_organization_id,p_organization_id,null,'DEPLOY'))
 and (jsonb_array_length(p.definition->'initial_objects')=0 or private.has_incident_capability(i.id,p_organization_id,'MANAGE_COP')));
end; $workflow$;
create or replace function public.simulation_overview(p_acting_organization_id uuid,p_page integer,p_view text) returns jsonb
language plpgsql stable security definer set search_path='' as $workflow$
begin
 if not private.incident_acting_member(p_acting_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if p_view is null or p_view not in ('all','active','finished') then raise exception 'VALIDATION_FAILED';end if;
 if p_page is null or p_page not between 0 and 10000 then raise exception 'VALIDATION_FAILED'; end if;
 if not private.simulation_enabled() then return '[]'::jsonb; end if;
 return coalesce((select jsonb_agg(q.dto order by q.created_at desc,q.id) from(
 select s.id,s.created_at,jsonb_build_object('id',s.id,'incident_id',s.incident_id,'title',s.title,'reference_number',i.reference_number,'incident_status',i.status,'status',s.status,'updated_at',s.updated_at,
 'created_by',coalesce(p.display_name,s.created_by::text),'unit_count',(select count(*) from public.simulation_unit_positions pos where pos.scenario_id=s.id and pos.active)) dto
 from public.simulation_scenarios s join public.incidents i on i.id=s.incident_id join public.profiles p on p.id=s.created_by
 where (p_view='all' or p_view='finished' and (s.status='FINISHED' or i.status in ('CLOSED','CANCELLED')) or p_view='active' and s.status<>'FINISHED' and i.status not in ('CLOSED','CANCELLED')) and private.simulation_visible(s.incident_id,p_acting_organization_id) order by s.created_at desc,s.id limit 25 offset p_page*25) q),'[]');
end; $workflow$;
revoke all on function public.simulation_overview(uuid,integer,text) from public,anon,authenticated,service_role;
grant execute on function public.simulation_overview(uuid,integer,text) to authenticated;
create function public.simulation_hazard_history(p_organization_id uuid,p_incident_id uuid,p_model uuid,p_before bigint default null) returns jsonb
language plpgsql stable security definer set search_path='' as $workflow$
declare s public.simulation_scenarios;m private.simulation_hazard_models;controller boolean;first_visible bigint;
begin
 if not private.simulation_enabled() or not private.simulation_visible(p_incident_id,p_organization_id) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 select * into m from private.simulation_hazard_models where id=p_model and scenario_id=s.id;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 controller:=coalesce(private.simulation_template_editor(p_organization_id) and private.simulation_controller(s.id,p_organization_id),false);
 if not controller and (s.status='DRAFT' or not m.revealed) then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select min(version) into first_visible from private.simulation_hazard_snapshots where model_id=m.id and revealed;
 -- Deliberately omit payload/configuration/operations: these may contain instructor secrets.
 return coalesce((select jsonb_agg(q.dto order by q.version desc) from (
  select h.version,jsonb_build_object('version',h.version::text,'step',h.step,'kind',h.kind,'recorded_at',h.recorded_at) dto
  from private.simulation_hazard_history h where h.model_id=m.id and (p_before is null or h.version<p_before)
   and (controller or (h.version>=first_visible and coalesce((select snap.revealed from private.simulation_hazard_snapshots snap where snap.model_id=m.id and snap.version<=h.version order by snap.version desc limit 1),false))) order by h.version desc limit 25
 ) q),'[]'::jsonb);
end; $workflow$;
revoke all on function public.simulation_hazard_history(uuid,uuid,uuid,bigint) from public,anon,authenticated,service_role;
grant execute on function public.simulation_hazard_history(uuid,uuid,uuid,bigint) to authenticated;

-- Safe preparation state; retains the existing authorized model projection.
create or replace function public.simulation_hazards_read(p_organization_id uuid,p_incident_id uuid,p_instructor boolean default false) returns jsonb
language plpgsql volatile security definer set search_path='' as $hazard_read$
declare s public.simulation_scenarios;controller boolean;models jsonb;seconds_value bigint;result_value jsonb;
begin
 if not private.incident_acting_member(p_organization_id) or not private.can_read_incident(p_incident_id) then raise exception 'NOT_AUTHORIZED';end if;
 select * into s from public.simulation_scenarios where incident_id=p_incident_id;
 if not found then return null;end if;
 if not private.simulation_enabled() then raise exception 'NOT_AUTHORIZED';end if;
 controller:=coalesce(private.simulation_template_editor(p_organization_id) and private.simulation_controller(s.id,p_organization_id),false);
 if not private.simulation_visible(p_incident_id,p_organization_id) and not controller then raise exception 'NOT_AUTHORIZED';end if;
 if p_instructor is null or p_instructor and not controller then raise exception 'NOT_AUTHORIZED';end if;
 select seconds into seconds_value from public.simulation_scenario_clock where scenario_id=s.id;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'version',m.version::text,'title',m.configuration->>'title','type',m.configuration->>'type',
 'step',m.last_step,'features',private.hazard_features(m),'lag_steps',greatest(0,coalesce(seconds_value,0)/5-m.last_step),
 'last_scan_at',m.last_scan_at,'error',m.last_error,'enabled',m.configuration->'enabled',
 'wind_direction',m.configuration->'wind_direction','wind_speed',m.configuration->'wind_speed',
 'burning',(select count(*) from jsonb_array_elements(m.state) c where (c->>'intensity')::numeric>0))
 ||case when p_instructor then jsonb_build_object('configuration',m.configuration,'revealed',m.revealed,'processing_ms',m.processing_ms,
 'pending_effects',(select count(*) from private.simulation_hazard_effects e where e.model_id=m.id and not exists(select 1 from private.simulation_hazard_history h where h.model_id=m.id and h.operation_id=e.operation_id)))
 else '{}'::jsonb end order by m.id),'[]') into models
 from private.simulation_hazard_models m where m.scenario_id=s.id and (p_instructor or (s.status<>'DRAFT' and m.revealed));
 result_value:=jsonb_build_object('can_control',controller,'status',s.status,'seconds',coalesce(seconds_value,0),'models',models,'initialization_state',(select instance.state from private.simulation_template_instances instance where instance.scenario_id=s.id));
 if octet_length(result_value::text)>1500000 then raise exception 'SIM_LIMIT';end if;
 return result_value;
end; $hazard_read$;
commit;
