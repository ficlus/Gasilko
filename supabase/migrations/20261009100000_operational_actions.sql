-- M14.5A: declarative configuration, not tactical executable rules.
create function private.validate_action_parameters(p_defs jsonb,p_values jsonb default null) returns boolean
language plpgsql immutable set search_path='' as $$
declare d jsonb;v jsonb;k text;t text;option_value jsonb;
begin
 if jsonb_typeof(p_defs) is distinct from 'array' or octet_length(p_defs::text)>24000 then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
 if jsonb_array_length(p_defs)>10 then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
 if (select count(*)<>count(distinct e->>'code') from jsonb_array_elements(p_defs) e) then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
 if p_values is not null then
  if jsonb_typeof(p_values) is distinct from 'object' or octet_length(p_values::text)>8192 then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  if exists(select 1 from jsonb_object_keys(p_values) x where not exists(select 1 from jsonb_array_elements(p_defs) d where d->>'code'=x)) then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
 end if;
 for d in select value from jsonb_array_elements(p_defs) loop
  if jsonb_typeof(d) is distinct from 'object' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  if exists(select 1 from jsonb_object_keys(d) x where x not in ('code','label_sl','label_de','type','required','min','max','max_length','options','sort_order'))
   or coalesce(d->>'code','')!~'^[A-Z][A-Z0-9_-]{0,63}$'
   or jsonb_typeof(d->'required') is distinct from 'boolean'
   or jsonb_typeof(d->'sort_order') is distinct from 'number'
   or coalesce(d->>'sort_order','')!~'^[0-9]{1,3}$'
   or jsonb_typeof(d->'label_sl') is distinct from 'string' or length(btrim(d->>'label_sl')) not between 1 and 200
   or jsonb_typeof(d->'label_de') is distinct from 'string' or length(btrim(d->>'label_de')) not between 1 and 200
   then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  k:=d->>'code';t:=d->>'type';
  if t is null or t not in ('TEXT','INTEGER','DECIMAL','BOOLEAN','CHOICE') then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  if t in ('INTEGER','DECIMAL') then
   if d ? 'max_length' or d ? 'options' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
   if (d ? 'min' and jsonb_typeof(d->'min')<>'number') or (d ? 'max' and jsonb_typeof(d->'max')<>'number') then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
   if (d->>'min')::numeric>(d->>'max')::numeric then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
   if t='INTEGER' and (mod((d->>'min')::numeric,1)<>0 or mod((d->>'max')::numeric,1)<>0) then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  elsif d ? 'min' or d ? 'max' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  if t='TEXT' then
   if jsonb_typeof(d->'max_length') is distinct from 'number' or (d->>'max_length')::numeric not between 1 and 2000 or mod((d->>'max_length')::numeric,1)<>0 or d ? 'options' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  elsif d ? 'max_length' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  if t='CHOICE' then
   if jsonb_typeof(d->'options') is distinct from 'array' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
   if jsonb_array_length(d->'options') not between 1 and 20 or (select count(*)<>count(distinct e->>'code') from jsonb_array_elements(d->'options') e) then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
   for option_value in select value from jsonb_array_elements(d->'options') loop
    if jsonb_typeof(option_value) is distinct from 'object' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
    if exists(select 1 from jsonb_object_keys(option_value) x where x not in ('code','label_sl','label_de'))
     or coalesce(option_value->>'code','')!~'^[A-Z][A-Z0-9_-]{0,63}$'
     or jsonb_typeof(option_value->'label_sl') is distinct from 'string' or length(btrim(option_value->>'label_sl')) not between 1 and 200
     or jsonb_typeof(option_value->'label_de') is distinct from 'string' or length(btrim(option_value->>'label_de')) not between 1 and 200 then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
   end loop;
  elsif d ? 'options' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  if p_values is null then continue; end if;
  v:=p_values->k;
  if v is null then
   if (d->>'required')::boolean then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
   continue;
  end if;
  if t='TEXT' then
   if jsonb_typeof(v)<>'string' or length(v#>>'{}')>((d->>'max_length')::numeric)::integer or ((d->>'required')::boolean and length(btrim(v#>>'{}'))=0) then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  elsif t in ('INTEGER','DECIMAL') then
   if jsonb_typeof(v)<>'number' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
   if (t='INTEGER' and mod((v#>>'{}')::numeric,1)<>0) or (v#>>'{}')::numeric<(d->>'min')::numeric or (v#>>'{}')::numeric>(d->>'max')::numeric then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  elsif t='BOOLEAN' then
   if jsonb_typeof(v)<>'boolean' then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
  elsif jsonb_typeof(v)<>'string' or not exists(select 1 from jsonb_array_elements(d->'options') o where o->>'code'=v#>>'{}') then raise exception 'INVALID_ACTION_PARAMETERS'; end if;
 end loop;
 return true;
end; $$;
create table public.operational_action_definitions(
 id uuid primary key,owner_organization_id uuid references public.organizations(id),
 code text not null check(code~'^[A-Z][A-Z0-9_-]{0,63}$'),active boolean not null default true,current_version_id uuid not null,
 created_at timestamptz not null default clock_timestamp(),created_by uuid references public.profiles(id),
 updated_at timestamptz not null default clock_timestamp(),updated_by uuid references public.profiles(id),
 version bigint not null default 1 check(version>0),
 check(owner_organization_id is null or (created_by is not null and updated_by is not null)));
create unique index action_system_code on public.operational_action_definitions(code) where owner_organization_id is null;
create unique index action_org_code on public.operational_action_definitions(owner_organization_id,code) where owner_organization_id is not null;
create table public.operational_action_definition_versions(
 id uuid primary key,definition_id uuid not null references public.operational_action_definitions(id),version_number bigint not null check(version_number>0),
 native_behavior text not null check(native_behavior in ('NONE','MOVE_TO','HOLD_POSITION','WITHDRAW_TO','REQUEST_STATUS')),
 label_sl text not null check(length(btrim(label_sl)) between 1 and 200),label_de text not null check(length(btrim(label_de)) between 1 and 200),
 description_sl text check(length(description_sl)<=2000),description_de text check(length(description_de)<=2000),
 default_priority text not null check(default_priority in ('LOW','NORMAL','HIGH','CRITICAL')),requires_acknowledgement boolean not null,
 active_for_new_commands boolean not null,recipient_types text[] not null,target_types text[] not null,parameter_definitions jsonb not null default '[]',
 created_at timestamptz not null default clock_timestamp(),created_by uuid references public.profiles(id),
 unique(id,definition_id),unique(definition_id,version_number),
 check(cardinality(recipient_types) between 1 and 2 and recipient_types<@array['INCIDENT_UNIT','INCIDENT_CREW_MEMBER'] and array_position(recipient_types,null) is null),
 check(cardinality(target_types) between 1 and 5 and target_types<@array['NONE','HYDRANT','INCIDENT_MAP_OBJECT','INCIDENT_SECTOR','COORDINATE'] and array_position(target_types,null) is null),
 check(native_behavior not in ('MOVE_TO','WITHDRAW_TO') or target_types<@array['COORDINATE','HYDRANT','INCIDENT_MAP_OBJECT']),
 check(native_behavior<>'REQUEST_STATUS' or 'NONE'=any(target_types)),
 check(private.validate_action_parameters(parameter_definitions)));
alter table public.operational_action_definitions add constraint action_current_version_fk foreign key(current_version_id,id)
 references public.operational_action_definition_versions(id,definition_id) deferrable initially deferred;
create trigger action_version_immutable before update or delete on public.operational_action_definition_versions for each row execute function private.audit_immutable();
create trigger action_version_no_truncate before truncate on public.operational_action_definition_versions for each statement execute function private.audit_immutable();
create trigger action_no_delete before delete on public.operational_action_definitions for each row execute function private.audit_immutable();
create trigger action_no_truncate before truncate on public.operational_action_definitions for each statement execute function private.audit_immutable();
alter table public.operational_action_definitions enable row level security;
alter table public.operational_action_definition_versions enable row level security;
-- Only bounded, authorized RPC projections; no browser table access.
revoke all on public.operational_action_definitions,public.operational_action_definition_versions from public,anon,authenticated,service_role;
revoke all on function private.validate_action_parameters(jsonb,jsonb) from public,anon,authenticated,service_role;

-- System seed rows are configuration; no tactical dispatch branches elsewhere.
do $$
declare r record;d uuid;v uuid;
begin
 for r in select * from (values
 ('MOVE_TO','MOVE_TO','Premakni se na','Bewege dich zu'),
 ('HOLD_POSITION','HOLD_POSITION','Zadrži položaj','Position halten'),
 ('WITHDRAW_TO','WITHDRAW_TO','Umakni se na','Rückzug zu'),
 ('REQUEST_STATUS','REQUEST_STATUS','Sporoči stanje','Status melden'),
 ('RECON','NONE','Izvidovanje','Erkundung'),
 ('FIRE_SUPPRESSION','NONE','Gašenje','Brandbekämpfung'),
 ('SEARCH','NONE','Preiskovanje','Suche'),('RESCUE','NONE','Reševanje','Rettung'),
 ('ESTABLISH_WATER_SUPPLY','NONE','Vzpostavi vodno oskrbo','Wasserversorgung herstellen'),
 ('SECURE_AREA','NONE','Zavaruj območje','Bereich sichern'),
 ('LOGISTICS','NONE','Logistična naloga','Logistikauftrag')) x(code,behavior,sl,de) loop
  d:=gen_random_uuid();v:=gen_random_uuid();
  insert into public.operational_action_definitions(id,code,current_version_id) values(d,r.code,v);
  insert into public.operational_action_definition_versions(id,definition_id,version_number,native_behavior,label_sl,label_de,default_priority,requires_acknowledgement,active_for_new_commands,recipient_types,target_types)
   values(v,d,1,r.behavior,r.sl,r.de,case when r.behavior='WITHDRAW_TO' then 'CRITICAL' else 'NORMAL' end,true,true,
   array['INCIDENT_UNIT','INCIDENT_CREW_MEMBER'],case when r.behavior in ('MOVE_TO','WITHDRAW_TO') then array['COORDINATE','HYDRANT','INCIDENT_MAP_OBJECT']
   when r.behavior='REQUEST_STATUS' then array['NONE'] else array['NONE','HYDRANT','INCIDENT_MAP_OBJECT','INCIDENT_SECTOR','COORDINATE'] end);
 end loop;
end; $$;
