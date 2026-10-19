-- M14.6C: bounded educational hazards, never real-world observations.
begin;
create table private.simulation_hazard_plans(
 version_id uuid primary key references public.simulation_scenario_template_versions(id),
 plan jsonb not null check(octet_length(plan::text)<=30000)
);
create table private.simulation_hazard_models(
 id uuid primary key default gen_random_uuid(), scenario_id uuid not null references public.simulation_scenarios(id),
 model_key text not null, model_version integer not null default 1 check(model_version=1),
 initial_configuration jsonb not null, configuration jsonb not null, state jsonb not null,
 revealed boolean not null, version bigint not null default 1 check(version between 1 and 10002), last_step bigint not null default 0 check(last_step between 0 and 5760),
 started_step bigint not null default 0, last_scan_at timestamptz, last_error text, processing_ms integer,
 unique(scenario_id,model_key), check(octet_length(state::text)<=200000)
);
create index simulation_hazard_fair on private.simulation_hazard_models(last_scan_at nulls first,scenario_id,id);
create table private.simulation_hazard_effects(
 id uuid primary key default gen_random_uuid(), model_id uuid not null references private.simulation_hazard_models(id),
 operation_id uuid not null, effective_step bigint not null check(effective_step between 0 and 5760),
 effect jsonb not null, actor uuid references public.profiles(id), origin text not null,
 event_id text, sequence bigint generated always as identity, created_at timestamptz not null default clock_timestamp(),
 unique(model_id,operation_id),check(origin in ('INSTRUCTOR','SCENARIO_EVENT','LIFECYCLE'))
);
create index simulation_hazard_effect_order on private.simulation_hazard_effects(model_id,effective_step,sequence);
create table private.simulation_hazard_history(
 model_id uuid not null references private.simulation_hazard_models(id), version bigint not null,
 step bigint not null, kind text not null, operation_id uuid, payload jsonb not null,
 recorded_at timestamptz not null default clock_timestamp(), primary key(model_id,version),
 unique(model_id,operation_id),check(octet_length(payload::text)<=200000)
);
create table private.simulation_hazard_snapshots(
 model_id uuid not null references private.simulation_hazard_models(id), version bigint not null, step bigint not null,
 state jsonb not null, configuration jsonb not null, revealed boolean not null,
 recorded_at timestamptz not null default clock_timestamp(),primary key(model_id,version)
);
-- No client (including service-role) table privileges. Only explicit RPCs below.
do $$ declare t text; begin
 foreach t in array array['simulation_hazard_plans','simulation_hazard_models','simulation_hazard_effects','simulation_hazard_history','simulation_hazard_snapshots'] loop
 execute format('alter table private.%I enable row level security',t);
 execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger %I before delete or truncate on private.%I for each statement execute function private.audit_immutable()',t||'_retain',t);
 end loop;
 foreach t in array array['simulation_hazard_effects','simulation_hazard_history','simulation_hazard_snapshots'] loop
 execute format('create trigger %I before update on private.%I for each row execute function private.audit_immutable()',t||'_immutable',t);
 end loop;
end $$;
revoke all on sequence private.simulation_hazard_effects_sequence_seq from public,anon,authenticated,service_role;

create function private.hazard_number(v jsonb,lo numeric,hi numeric) returns numeric
language plpgsql immutable set search_path='' as $$
declare n numeric;
begin
 if jsonb_typeof(v) is distinct from 'number' then raise exception 'VALIDATION_FAILED';end if;
 n:=(v#>>'{}')::numeric;
 if n<lo or n>hi then raise exception 'VALIDATION_FAILED';end if;
 return n;
end $$;
-- Small local tangent/equirectangular grid, <=250m radius, |latitude|<=75.
-- R=6371008.8m. Definition coordinates stay WGS84; no degree-as-metre arithmetic.
create function private.hazard_xy(p jsonb,c jsonb) returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_build_array(
 ((p->>0)::float8-(c->>0)::float8)*pi()/180*6371008.8*cos((c->>1)::float8*pi()/180),
 ((p->>1)::float8-(c->>1)::float8)*pi()/180*6371008.8);
$$;
create function private.hazard_lonlat(x float8,y float8,c jsonb) returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_build_array(round(((c->>0)::numeric+(x/6371008.8/cos((c->>1)::float8*pi()/180)*180/pi())::numeric),7),
 round(((c->>1)::numeric+(y/6371008.8*180/pi())::numeric),7));
$$;
create function private.hazard_effect_valid(e jsonb,m jsonb) returns void
language plpgsql immutable set search_path='' as $$
begin
 perform private.sim_template_keys(e,array['type','value']);
 case e->>'type'
 when 'WIND' then
  perform private.sim_template_keys(e->'value',array['direction','speed']);
  perform private.hazard_number(e#>'{value,direction}',0,359.99);perform private.hazard_number(e#>'{value,speed}',0,20);
 when 'SPREAD' then perform private.hazard_number(e->'value',0,2);
 when 'BOOST' then perform private.hazard_number(e->'value',0,1);
 when 'IGNITE' then
  if jsonb_typeof(e->'value') is distinct from 'string' or not exists(select 1 from jsonb_array_elements(m->'origins') o where o->>'id'=e->>'value') then raise exception 'VALIDATION_FAILED';end if;
 when 'ENABLE' then if jsonb_typeof(e->'value') is distinct from 'boolean' then raise exception 'VALIDATION_FAILED';end if;
 when 'REVEAL' then if e->'value' is distinct from 'null'::jsonb then raise exception 'VALIDATION_FAILED';end if;
 when 'STOP' then if e->'value' is distinct from 'null'::jsonb then raise exception 'VALIDATION_FAILED';end if;
 else raise exception 'VALIDATION_FAILED';
 end case;
end $$;
create function private.validate_hazard_plan(p jsonb,events jsonb) returns void
language plpgsql immutable set search_path='' as $$
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
  if exists(select 1 from jsonb_array_elements(m->'effects') e group by e->>'event_id' having count(*)>1) then raise exception 'VALIDATION_FAILED';end if;
 end loop;
end $$;


create function private.hazard_initial(m jsonb) returns jsonb
language sql immutable set search_path='' as $$
 with cfg as(select (m->>'cell_m')::numeric cell,(m->>'radius_m')::numeric radius),
 origins as(select o,private.hazard_xy(o->'position',m->'center') xy from jsonb_array_elements(m->'origins') o),
 grid as(
 select x::numeric x,y::numeric y,x||':'||y id from cfg,generate_series(-10,10) x,generate_series(-10,10) y
 where sqrt(x*x+y*y)*cell+cell/sqrt(2)<=radius and m->>'type'='WILDFIRE'
 ), cells as(
 select g.id,g.x,g.y,case when exists(select 1 from jsonb_array_elements(m->'blocked') b where b=jsonb_build_array(g.x,g.y)) then 0 else (m->>'fuel')::numeric end fuel,
 coalesce((select max((o->>'intensity')::numeric) from origins where (o->>'initial')::boolean and round((xy->>0)::numeric/c.cell)=g.x and round((xy->>1)::numeric/c.cell)=g.y),0) intensity
 from grid g cross join cfg c
 union all
 select o->>'id',(xy->>0)::numeric/c.cell,(xy->>1)::numeric/c.cell,(m->>'fuel')::numeric,
 case when (o->>'initial')::boolean then (o->>'intensity')::numeric else 0 end from origins cross join cfg c where m->>'type'='STRUCTURE_FIRE'
 )
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'x',x,'y',y,'fuel',fuel,'intensity',intensity,'burned',0,'heat',0,'smoke',0,'dx',0,'dy',0) order by id),'[]') from cells;
$$;

-- Jacobi/synchronous update: every cell sees the same previous step, never a
-- partially updated neighbour. Fixed-point rounding makes replay deterministic.
create function private.hazard_step(m jsonb,state jsonb,age bigint) returns jsonb
language sql immutable set search_path='' as $$
 with cells as materialized(
 select * from jsonb_to_recordset(state) as c(id text,x numeric,y numeric,fuel numeric,intensity numeric,burned numeric,heat numeric,smoke numeric,dx numeric,dy numeric)
 ), cfg as(select (m->>'spread')::numeric spread,(m->>'moisture')::numeric moisture,(m->>'cell_m')::numeric cell,
 (m->>'wind_speed')::numeric wind,(m->>'wind_direction')::float8*pi()/180 direction,(m->>'radius_m')::numeric radius),
 influence as(
 select c.id,coalesce(sum(n.intensity*greatest(0.2,1+cfg.wind/10*
 (sin(cfg.direction)*(c.x-n.x)::float8+cos(cfg.direction)*(c.y-n.y)::float8)/sqrt(((c.x-n.x)^2+(c.y-n.y)^2)::float8))/8),0)::numeric fire,
 coalesce(sum(n.smoke*greatest(0.05,1+0.8*least(1,cfg.wind/10)*(sin(cfg.direction)*(c.x-n.x)::float8+cos(cfg.direction)*(c.y-n.y)::float8)/sqrt(((c.x-n.x)^2+(c.y-n.y)^2)::float8))/8),0)::numeric smoke_in
 from cells c cross join cfg left join cells n on n.x between c.x-1 and c.x+1 and n.y between c.y-1 and c.y+1 and n.id<>c.id and m->>'type'='WILDFIRE'
 group by c.id
 ), heat as(
 select c.*,cfg.*,least(2,c.heat+0.12*spread*(1-moisture)*c.fuel*i.fire*25/cell) next_heat,
 i.smoke_in from cells c join influence i using(id) cross join cfg
 ), fire as(
 select h.*,case
 when not (m->>'enabled')::boolean then intensity
 when fuel=0 or burned>=1 then 0
 when m->>'type'='STRUCTURE_FIRE' and (m->>'decline_seconds')::numeric>0 and age>=(m->>'decline_seconds')::numeric then greatest(0,intensity-0.025)
 when intensity>0 then least(1,intensity+0.02*spread*(1-moisture))
 when m->>'type'='WILDFIRE' and next_heat>=1 then 0.2 else 0 end next_intensity
 from heat h
 ), result as(
 select id,x,y,fuel,
 round(case when burned+0.005*next_intensity/greatest(0.1,fuel)>=1 then 0 else next_intensity end,6) intensity,
 round(case when (m->>'enabled')::boolean then least(1,burned+0.005*next_intensity/greatest(0.1,fuel)) else burned end,6) burned,
 round(case when (m->>'enabled')::boolean then next_heat else heat end,6) heat,
 round(least(1,greatest(0,case when m->>'type'='WILDFIRE' then 0.65*smoke+0.25*smoke_in else 0.9*smoke end+0.08*next_intensity)),6) smoke,
 round(case when m->>'type'='STRUCTURE_FIRE' and (smoke>0 or next_intensity>0) then greatest(-radius/2,least(radius/2,dx+(sin(direction)*wind*5)::numeric)) else 0 end,6) dx,
 round(case when m->>'type'='STRUCTURE_FIRE' and (smoke>0 or next_intensity>0) then greatest(-radius/2,least(radius/2,dy+(cos(direction)*wind*5)::numeric)) else 0 end,6) dy
 from fire
 )
 select case when (m->>'enabled')::boolean then jsonb_agg(to_jsonb(r) order by id) else state end from result r;
$$;

create function private.hazard_record(p_model uuid,p_kind text,p_operation uuid,p_payload jsonb,p_snapshot boolean) returns void
language plpgsql security definer set search_path='' as $$
declare m private.simulation_hazard_models;
begin
 select * into m from private.simulation_hazard_models where id=p_model;
 insert into private.simulation_hazard_history(model_id,version,step,kind,operation_id,payload)
 values(m.id,m.version,m.last_step,p_kind,p_operation,p_payload||jsonb_build_object('state_hash',md5(m.state::text),'model_version',m.model_version));
 if p_snapshot then
 insert into private.simulation_hazard_snapshots(model_id,version,step,state,configuration,revealed)
 values(m.id,m.version,m.last_step,m.state,m.configuration,m.revealed);
 end if;
end $$;
create function private.hazard_instantiate() returns trigger
language plpgsql security definer set search_path='' as $$
declare p jsonb;m jsonb;model_id uuid;events jsonb;
begin
 select plan into p from private.simulation_hazard_plans where version_id=new.source_version_id;
 if p is null then return new;end if;
 select plan into events from private.simulation_event_plans where version_id=new.source_version_id;
 perform private.validate_hazard_plan(p,coalesce(events,'{"schema_version":1,"events":[]}'));
 for m in select value from jsonb_array_elements(p->'models') loop
  insert into private.simulation_hazard_models(scenario_id,model_key,initial_configuration,configuration,state,revealed)
  values(new.scenario_id,m->>'id',m,m,private.hazard_initial(m),m->>'visibility'='START') returning id into model_id;
  perform private.hazard_record(model_id,'INITIAL',null,jsonb_build_object('seed',0,'configuration',m),true);
 end loop;
 return new;
end $$;
create trigger simulation_hazard_instantiate after insert on private.simulation_template_instances for each row execute function private.hazard_instantiate();

-- Queue effects at the next authoritative boundary. No reordering past work:
-- all intervening steps are processed before the effect becomes visible.
create function private.hazard_enqueue(p_model uuid,p_operation uuid,p_effect jsonb,p_actor uuid,p_origin text,p_event text default null) returns void
language plpgsql security definer set search_path='' as $$
declare m private.simulation_hazard_models;seconds_value bigint;
begin
 select * into m from private.simulation_hazard_models where id=p_model for update;
 if not found then raise exception 'VALIDATION_FAILED';end if;
 if m.version>=9980 then raise exception 'SIM_LIMIT';end if;
 if exists(select 1 from private.simulation_hazard_effects where model_id=m.id and operation_id=p_operation) then return;end if;
 if (select count(*) from private.simulation_hazard_effects where model_id=m.id)>=200 then raise exception 'SIM_LIMIT';end if;
 if p_effect->>'type'<>'RESET' then perform private.hazard_effect_valid(p_effect,m.configuration);end if;
 select seconds into seconds_value from public.simulation_scenario_clock where scenario_id=m.scenario_id;
 if coalesce(seconds_value,0)>28800 then raise exception 'SIM_LIMIT';end if;
 insert into private.simulation_hazard_effects(model_id,operation_id,effective_step,effect,actor,origin,event_id)
 values(m.id,p_operation,ceil(coalesce(seconds_value,0)/5.0),p_effect,p_actor,p_origin,p_event);
end $$;

-- The existing B event transition remains the exactly-once trigger; hidden
-- model parameters never enter the commander event result or normal timeline.
create function private.hazard_event_effect(p_scenario uuid,p_event text,p_operation uuid,p_actor uuid) returns void
language plpgsql security definer set search_path='' as $$
declare m private.simulation_hazard_models;e jsonb;
begin
 for m in select * from private.simulation_hazard_models where scenario_id=p_scenario order by id loop
  for e in select value from jsonb_array_elements(m.initial_configuration->'effects') where value->>'event_id'=p_event loop
   perform private.hazard_enqueue(m.id,p_operation,e->'effect',p_actor,'SCENARIO_EVENT',p_event);
  end loop;
 end loop;
end $$;

create function private.hazard_lifecycle() returns trigger
language plpgsql security definer set search_path='' as $$
declare m private.simulation_hazard_models;
begin
 for m in select * from private.simulation_hazard_models where scenario_id=new.scenario_id order by id for update loop
  if m.version>=9980 and new.event_type<>'SIMULATION_FINISHED' then
   if m.last_error is distinct from 'HAZARD_HISTORY_LIMIT' then
    update private.simulation_hazard_models set version=version+1,last_error='HAZARD_HISTORY_LIMIT' where id=m.id;
    perform private.hazard_record(m.id,'LIMIT',null,'{"error":"HAZARD_HISTORY_LIMIT"}',true);
   end if;
   continue;
  end if;
  if new.event_type='SIMULATION_RESET' then
   perform private.hazard_enqueue(m.id,new.operation_id,'{"type":"RESET","value":null}',new.actor_user_id,'LIFECYCLE');
  end if;
  update private.simulation_hazard_models set version=version+1 where id=m.id;
  perform private.hazard_record(m.id,new.event_type,null,jsonb_build_object('operation_id',new.operation_id,'actor',new.actor_user_id),new.event_type='SIMULATION_FINISHED');
 end loop;
 return new;
end $$;
create trigger simulation_hazard_lifecycle after insert on public.simulation_events for each row
 when(new.event_type in ('SIMULATION_STARTED','SIMULATION_PAUSED','SIMULATION_RESUMED','SIMULATION_RESET','SIMULATION_FINISHED'))
 execute function private.hazard_lifecycle();


create function private.hazard_apply(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare m private.simulation_hazard_models;e private.simulation_hazard_effects;o jsonb;xy jsonb;v jsonb;cfg jsonb;
begin
 select * into m from private.simulation_hazard_models where id=p_id for update;
 for e in select q.* from private.simulation_hazard_effects q
 where q.model_id=m.id and q.effective_step<=m.last_step
 and not exists(select 1 from private.simulation_hazard_history h where h.model_id=m.id and h.operation_id=q.operation_id)
 order by q.effective_step,q.sequence limit 4 loop
  cfg:=m.configuration;v:=m.state;
  case e.effect->>'type'
  when 'WIND' then cfg:=cfg||jsonb_build_object('wind_direction',e.effect#>'{value,direction}','wind_speed',e.effect#>'{value,speed}');
  when 'SPREAD' then cfg:=cfg||jsonb_build_object('spread',e.effect->'value');
  when 'ENABLE' then cfg:=cfg||jsonb_build_object('enabled',e.effect->'value');
  when 'REVEAL' then m.revealed:=true;
  when 'RESET' then cfg:=m.initial_configuration;v:=private.hazard_initial(cfg);m.started_step:=m.last_step;m.revealed:=cfg->>'visibility'='START';
  when 'STOP' then
   select jsonb_agg(c||jsonb_build_object('intensity',0,'heat',0,'burned',case when (c->>'intensity')::numeric>0 then 1 else (c->>'burned')::numeric end) order by c->>'id') into v from jsonb_array_elements(v) c;
  when 'BOOST' then
   select jsonb_agg(c||jsonb_build_object('intensity',case when (c->>'intensity')::numeric>0 then least(1,(c->>'intensity')::numeric+(e.effect->>'value')::numeric) else 0 end) order by c->>'id') into v from jsonb_array_elements(v) c;
  when 'IGNITE' then
   select value into o from jsonb_array_elements(cfg->'origins') where value->>'id'=e.effect->>'value';
   xy:=private.hazard_xy(o->'position',cfg->'center');
   cfg:=jsonb_set(cfg,'{origins}',(select jsonb_agg(case when a.value->>'id'=o->>'id' then a.value||jsonb_build_object('initial',true) else a.value end order by a.ordinality) from jsonb_array_elements(cfg->'origins') with ordinality a));
   select jsonb_agg(case when (cfg->>'type'='STRUCTURE_FIRE' and c->>'id'=o->>'id') or
    (cfg->>'type'='WILDFIRE' and (c->>'x')::numeric=round((xy->>0)::numeric/(cfg->>'cell_m')::numeric) and (c->>'y')::numeric=round((xy->>1)::numeric/(cfg->>'cell_m')::numeric))
    then c||jsonb_build_object('intensity',o->'intensity','burned',0,'heat',0,'dx',0,'dy',0) else c end order by c->>'id') into v from jsonb_array_elements(v) c;
  else raise exception 'VALIDATION_FAILED';
  end case;
  update private.simulation_hazard_models set configuration=cfg,state=v,revealed=m.revealed,started_step=m.started_step,version=version+1 where id=m.id returning * into m;
  perform private.hazard_record(m.id,'EFFECT',e.operation_id,jsonb_build_object('effect',e.effect,'origin',e.origin,'actor',e.actor,'event_id',e.event_id,'effective_step',e.effective_step),true);
 end loop;
end $$;

create function public.simulation_hazard_batch() returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='100ms' as $$
declare q record;m private.simulation_hazard_models;s public.simulation_scenarios;
 target bigint;n integer;steps integer:=0;failed integer:=0;v jsonb;started timestamptz:=clock_timestamp();one timestamptz;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'NOT_AUTHORIZED';end if;
 if not private.simulation_enabled() then return jsonb_build_object('steps',0);end if;
 -- Locks are acquired in the same order as agents/events. No model lock before
 -- agent_locks; concurrent invocations recheck the durable cursor after waiting.
 for q in select m.id,m.scenario_id from private.simulation_hazard_models m
 join public.simulation_scenarios s on s.id=m.scenario_id
 where s.status='RUNNING' and m.last_error is null and m.last_step<5760
 order by m.last_scan_at nulls first,m.id limit 4 loop
  exit when clock_timestamp()-started>interval '2 seconds';
  one:=clock_timestamp();
  begin
   perform private.agent_locks(q.scenario_id);
   select * into s from public.simulation_scenarios where id=q.scenario_id;
   update private.simulation_hazard_models set last_scan_at=clock_timestamp() where id=q.id;
   if s.status<>'RUNNING' or not private.simulation_event_authority(s.id)
    or not exists(select 1 from private.simulation_template_instances where scenario_id=s.id and state='READY') then continue;end if;
   select * into m from private.simulation_hazard_models where id=q.id for update;
   if m.last_error is not null then continue;end if;
   if m.version>=9980 then
    update private.simulation_hazard_models set version=version+1,last_error='HAZARD_HISTORY_LIMIT' where id=m.id;
    perform private.hazard_record(m.id,'LIMIT',null,'{"error":"HAZARD_HISTORY_LIMIT"}',true);continue;
   end if;
   select least(5760,seconds/5) into target from public.simulation_scenario_clock where scenario_id=s.id;
   perform private.hazard_apply(m.id);
   for n in 1..10 loop
    select * into m from private.simulation_hazard_models where id=q.id;
    exit when m.last_step>=target or m.version>=9980 or clock_timestamp()-started>interval '2 seconds' or exists(
     select 1 from private.simulation_hazard_effects e where e.model_id=m.id and e.effective_step<=m.last_step
     and not exists(select 1 from private.simulation_hazard_history h where h.model_id=m.id and h.operation_id=e.operation_id));
    v:=private.hazard_step(m.configuration,m.state,(m.last_step+1-m.started_step)*5);
    if m.state is distinct from v then
     update private.simulation_hazard_models set last_step=last_step+1,version=version+1,state=v where id=m.id returning * into m;
    else
     update private.simulation_hazard_models set last_step=last_step+1,version=version+1 where id=m.id returning * into m;
    end if;
    perform private.hazard_record(m.id,'STEP',null,jsonb_build_object('burning',(select count(*) from jsonb_array_elements(v) c where (c->>'intensity')::numeric>0)),m.last_step%60=0 or m.last_step=5760);
    perform private.hazard_apply(m.id);steps:=steps+1;
   end loop;
   update private.simulation_hazard_models set last_scan_at=clock_timestamp(),processing_ms=round(extract(epoch from clock_timestamp()-one)*1000) where id=q.id;
  exception
   when lock_not_available or deadlock_detected or serialization_failure then failed:=failed+1;
   when others then
    -- This subtransaction rolls back its state/effect/history together.
    update private.simulation_hazard_models set last_error='HAZARD_PROCESSING_FAILED',last_scan_at=clock_timestamp(),version=version+1 where id=q.id;
    perform private.hazard_record(q.id,'ERROR',null,jsonb_build_object('error','HAZARD_PROCESSING_FAILED'),false);
    failed:=failed+1;
  end;
 end loop;
 return jsonb_build_object('steps',steps,'failed',failed,'duration_ms',round(extract(epoch from clock_timestamp()-started)*1000));
end $$;

create function public.simulation_hazard_command(p_organization_id uuid,p_incident_id uuid,p_operation uuid,p_model uuid,p_expected_version bigint,p_effect jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.simulation_scenarios;m private.simulation_hazard_models;r private.simulation_template_receipts;req jsonb;result_value jsonb;
begin
 if auth.uid() is null or p_operation is null or p_expected_version is null then raise exception 'VALIDATION_FAILED';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,146));
 select * into s from public.simulation_scenarios where incident_id=p_incident_id and organization_id=p_organization_id;
 if not found then raise exception 'NOT_AUTHORIZED';end if;
 perform private.agent_locks(s.id);
 if not private.simulation_template_editor(p_organization_id) or not private.simulation_controller(s.id,p_organization_id) then raise exception 'NOT_AUTHORIZED';end if;
 req:=jsonb_build_object('incident',p_incident_id,'model',p_model,'version',p_expected_version,'effect',p_effect);
 select * into r from private.simulation_template_receipts where operation_id=p_operation;
 if found then
  if r.actor<>auth.uid() or r.organization_id<>p_organization_id or r.request is distinct from req then raise exception 'OPERATION_REUSED';end if;
  return r.result;
 end if;
 select * into s from public.simulation_scenarios where id=s.id;
 select * into m from private.simulation_hazard_models where id=p_model and scenario_id=s.id for update;
 if not found then raise exception 'NOT_AUTHORIZED';end if;
 if m.version<>p_expected_version then raise exception 'STALE_VERSION';end if;
 if m.version>=9980 then raise exception 'SIM_LIMIT';end if;
 if s.status not in ('RUNNING','PAUSED') then raise exception 'INVALID_TRANSITION';end if;
 perform private.sim_template_keys(p_effect,array['type','value']);
 if p_effect->>'type'='RETRY' then
  if p_effect->'value' is distinct from 'null'::jsonb or m.last_error is null then raise exception 'VALIDATION_FAILED';end if;
  update private.simulation_hazard_models set last_error=null,version=version+1 where id=m.id;
  perform private.hazard_record(m.id,'RETRY',p_operation,jsonb_build_object('actor',auth.uid()),false);
 else
  perform private.hazard_effect_valid(p_effect,m.configuration);
  perform private.hazard_enqueue(m.id,p_operation,p_effect,auth.uid(),'INSTRUCTOR');
  update private.simulation_hazard_models set version=version+1 where id=m.id;
  perform private.hazard_record(m.id,'QUEUED',null,jsonb_build_object('operation_id',p_operation,'actor',auth.uid()),false);
 end if;
 result_value:=jsonb_build_object('queued',true);
 insert into private.simulation_template_receipts(operation_id,actor,organization_id,request,result) values(p_operation,auth.uid(),p_organization_id,req,result_value);
 return result_value;
end $$;


create function private.hazard_polygon(c jsonb,x numeric,y numeric,r numeric,square boolean,bound numeric) returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_build_object('type','Polygon','coordinates',jsonb_build_array(jsonb_agg(
 private.hazard_lonlat(greatest(-bound,least(bound,x+case when square then case when k in(0,3,4) then -r else r end else r*cos(k*pi()/8) end)),
 greatest(-bound,least(bound,y+case when square then case when k in(0,1,4) then -r else r end else r*sin(k*pi()/8) end)),c) order by k)))
 from generate_series(0,case when square then 4 else 16 end) k;
$$;
create function private.hazard_features(m private.simulation_hazard_models) returns jsonb
language sql stable set search_path='' as $$
 with cells as(select * from jsonb_to_recordset(m.state) as c(id text,x numeric,y numeric,intensity numeric,burned numeric,smoke numeric,dx numeric,dy numeric)),
 cfg as(select m.configuration c,(m.configuration->>'cell_m')::numeric cell,(m.configuration->>'radius_m')::numeric radius),
 features as(
 select c.id||':fire' id,'FIRE' kind,c.intensity intensity,
 private.hazard_polygon(cfg.c->'center',c.x*cell,c.y*cell,case when cfg.c->>'type'='WILDFIRE' then cell/2 else 5+15*c.intensity end,cfg.c->>'type'='WILDFIRE',radius) geometry,
 case when c.intensity=0 then 'EXTINGUISHED' when cfg.c->>'type'='STRUCTURE_FIRE' and (cfg.c->>'decline_seconds')::numeric>0 and (m.last_step-m.started_step)*5>=(cfg.c->>'decline_seconds')::numeric then 'DECLINING' when c.intensity<0.25 then 'INITIAL' when c.intensity<0.7 then 'DEVELOPING' else 'INTENSE' end phase
 from cells c cross join cfg where c.intensity>0
 union all
 select c.id||':burned','BURNED',c.burned,private.hazard_polygon(cfg.c->'center',c.x*cell,c.y*cell,cell/2,true,radius),'BURNED'
 from cells c cross join cfg where c.burned>=1 and cfg.c->>'type'='WILDFIRE'
 union all
 select c.id||':smoke','SMOKE',c.smoke,private.hazard_polygon(cfg.c->'center',c.x*cell+case when cfg.c->>'type'='STRUCTURE_FIRE' then c.dx else 0 end,
 c.y*cell+case when cfg.c->>'type'='STRUCTURE_FIRE' then c.dy else 0 end,case when cfg.c->>'type'='WILDFIRE' then cell/2 else 10+40*c.smoke end,cfg.c->>'type'='WILDFIRE',radius),'SMOKE'
 from cells c cross join cfg where c.smoke>=0.01
 union all
 select c.id||':heat','HEAT_ZONE',c.intensity,private.hazard_polygon(cfg.c->'center',c.x*cell,c.y*cell,case when cfg.c->>'type'='WILDFIRE' then cell/2 else 10+30*c.intensity end,cfg.c->>'type'='WILDFIRE',radius),'DYNAMIC'
 from cells c cross join cfg where c.intensity>=0.7
 union all
 select z->>'id',z->>'kind',1,private.hazard_polygon(cfg.c->'center',(private.hazard_xy(z->'position',cfg.c->'center')->>0)::numeric,
 (private.hazard_xy(z->'position',cfg.c->'center')->>1)::numeric,(z->>'radius_m')::numeric,false,radius),'INSTRUCTOR'
 from cfg,jsonb_array_elements(cfg.c->'zones') z
 union all
 select 'origin:'||(o->>'id'),'ORIGIN',(o->>'intensity')::numeric,jsonb_build_object('type','Point','coordinates',o->'position'),'SIM'
 from cfg,jsonb_array_elements(cfg.c->'origins') o
 where (o->>'initial')::boolean and exists(select 1 from cells c where c.intensity>0 and
 ((cfg.c->>'type'='STRUCTURE_FIRE' and c.id=o->>'id') or (cfg.c->>'type'='WILDFIRE' and c.x=round((private.hazard_xy(o->'position',cfg.c->'center')->>0)::numeric/cell) and c.y=round((private.hazard_xy(o->'position',cfg.c->'center')->>1)::numeric/cell))))
 )
 select coalesce(jsonb_agg(jsonb_build_object('type','Feature','id',m.id::text||':'||id,'geometry',geometry,
 'properties',jsonb_build_object('model_id',m.id,'kind',kind,'phase',phase,'intensity',intensity,'source','SIMULATED','title',m.configuration->>'title')) order by id),'[]') from features;
$$;
create function public.simulation_hazards_read(p_organization_id uuid,p_incident_id uuid,p_instructor boolean default false) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
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
 result_value:=jsonb_build_object('can_control',controller,'status',s.status,'seconds',coalesce(seconds_value,0),'models',models);
 if octet_length(result_value::text)>1500000 then raise exception 'SIM_LIMIT';end if;
 return result_value;
end $$;

create function private.hazard_plan_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare v public.simulation_scenario_template_versions;events jsonb;
begin
 select * into v from public.simulation_scenario_template_versions where id=new.version_id for update;
 if v.state is distinct from 'DRAFT' or tg_op='UPDATE' and new.version_id<>old.version_id then raise exception 'INVALID_TRANSITION';end if;
 select plan into events from private.simulation_event_plans where version_id=v.id;
 perform private.validate_hazard_plan(new.plan,coalesce(events,'{"schema_version":1,"events":[]}'));
 return new;
end $$;
create trigger simulation_hazard_plan_guard before insert or update on private.simulation_hazard_plans for each row execute function private.hazard_plan_guard();

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
 'version_id',v.id,'version',v.version,'state',v.state,'definition',v.definition,'hazard_plan',coalesce((select plan from private.simulation_hazard_plans where version_id=v.id),'{"schema_version":1,"models":[]}'::jsonb),'event_plan',coalesce((select plan from private.simulation_event_plans where version_id=v.id),'{"schema_version":1,"events":[]}'::jsonb));
end; $$;
create or replace function public.simulation_template_command(
 p_organization_id uuid,p_operation uuid,p_action text,p_template_id uuid,p_expected_version bigint,p_payload jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.simulation_scenario_templates;v public.simulation_scenario_template_versions;
 saved private.simulation_template_receipts;req jsonb;result_value jsonb;new_id uuid;new_version uuid;d jsonb;core jsonb;
 scenario uuid;allowed text[];plan_value jsonb;hazard_value jsonb;
begin
 if auth.uid() is null or p_operation is null or p_expected_version is null or p_action is null
 or p_action not in ('CREATE','COPY','REVISE','SAVE','PUBLISH','ARCHIVE','START') or jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>115000 then raise exception 'VALIDATION_FAILED';end if;
 allowed:=case p_action when 'CREATE' then array['definition'] when 'SAVE' then array['definition','version_id']
 when 'COPY' then array['version_id'] when 'START' then array['version_id','incident_type_id'] else array[]::text[] end;
 if p_action in ('CREATE','SAVE') and p_payload?'event_plan' then allowed:=array_append(allowed,'event_plan');end if;
 if p_action in ('CREATE','SAVE') and p_payload?'hazard_plan' then allowed:=array_append(allowed,'hazard_plan');end if;
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
 hazard_value:=coalesce((select plan from private.simulation_hazard_plans where version_id=v.id),'{"schema_version":1,"models":[]}'::jsonb);
 if p_action in ('CREATE','SAVE') then hazard_value:=coalesce(p_payload->'hazard_plan',hazard_value);end if;
 perform private.validate_hazard_plan(hazard_value,plan_value);
 if p_action in ('CREATE','COPY') then
  perform private.validate_simulation_template(d,false);
  new_id:=gen_random_uuid();new_version:=gen_random_uuid();
  insert into public.simulation_scenario_templates(id,organization_id,created_by) values(new_id,p_organization_id,auth.uid());
  insert into public.simulation_scenario_template_versions(id,template_id,version,state,definition,created_by)
   values(new_version,new_id,1,'DRAFT',d,auth.uid());
  insert into private.simulation_event_plans(version_id,plan) values(new_version,plan_value);
  insert into private.simulation_hazard_plans(version_id,plan) values(new_version,hazard_value);
  result_value:=public.simulation_template_read(p_organization_id,new_id);
 elsif p_action='REVISE' then
  if v.state<>'PUBLISHED' then raise exception 'INVALID_TRANSITION';end if;
  new_version:=gen_random_uuid();
  insert into public.simulation_scenario_template_versions(id,template_id,version,state,definition,created_by)
   values(new_version,t.id,v.version+1,'DRAFT',d,auth.uid());
  insert into private.simulation_event_plans(version_id,plan) values(new_version,plan_value);
  insert into private.simulation_hazard_plans(version_id,plan) values(new_version,hazard_value);
 elsif p_action='SAVE' then
  if v.state<>'DRAFT' then raise exception 'INVALID_TRANSITION';end if;
  d:=p_payload->'definition';perform private.validate_simulation_template(d,false);
  update public.simulation_scenario_template_versions set definition=d where id=v.id;
  insert into private.simulation_event_plans(version_id,plan) values(v.id,plan_value)
   on conflict(version_id) do update set plan=excluded.plan;
  insert into private.simulation_hazard_plans(version_id,plan) values(v.id,hazard_value) on conflict(version_id) do update set plan=excluded.plan;
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

create or replace function private.simulation_event_execute(p_scenario uuid,p_event text,p_manual boolean,p_actor uuid) returns jsonb
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
 perform private.hazard_event_effect(s.id,e.event_id,e.operation_id,p_actor);
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
revoke all on function private.hazard_number(jsonb,numeric,numeric) from public,anon,authenticated,service_role;
revoke all on function private.hazard_xy(jsonb,jsonb) from public,anon,authenticated,service_role;
revoke all on function private.hazard_lonlat(double precision,double precision,jsonb) from public,anon,authenticated,service_role;
revoke all on function private.hazard_effect_valid(jsonb,jsonb) from public,anon,authenticated,service_role;
revoke all on function private.validate_hazard_plan(jsonb,jsonb) from public,anon,authenticated,service_role;
revoke all on function private.hazard_initial(jsonb) from public,anon,authenticated,service_role;
revoke all on function private.hazard_step(jsonb,jsonb,bigint) from public,anon,authenticated,service_role;
revoke all on function private.hazard_record(uuid,text,uuid,jsonb,boolean) from public,anon,authenticated,service_role;
revoke all on function private.hazard_instantiate() from public,anon,authenticated,service_role;
revoke all on function private.hazard_enqueue(uuid,uuid,jsonb,uuid,text,text) from public,anon,authenticated,service_role;
revoke all on function private.hazard_event_effect(uuid,text,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.hazard_lifecycle() from public,anon,authenticated,service_role;
revoke all on function private.hazard_apply(uuid) from public,anon,authenticated,service_role;
revoke all on function private.hazard_polygon(jsonb,numeric,numeric,numeric,boolean,numeric) from public,anon,authenticated,service_role;
revoke all on function private.hazard_features(private.simulation_hazard_models) from public,anon,authenticated,service_role;
revoke all on function private.hazard_plan_guard() from public,anon,authenticated,service_role;
revoke all on function public.simulation_hazard_batch() from public,anon,authenticated,service_role;
grant execute on function public.simulation_hazard_batch() to service_role;
revoke all on function public.simulation_hazard_command(uuid,uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.simulation_hazard_command(uuid,uuid,uuid,uuid,bigint,jsonb) to authenticated;
revoke all on function public.simulation_hazards_read(uuid,uuid,boolean) from public,anon,authenticated,service_role;
grant execute on function public.simulation_hazards_read(uuid,uuid,boolean) to authenticated;
commit;
