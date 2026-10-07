-- Generic event envelope; recipient identity is resolved exclusively by trusted SQL.
create table private.notification_categories(code text primary key, default_enabled boolean not null, user_editable boolean not null default true);
insert into private.notification_categories(code,default_enabled) values('ASSIGNMENT',true),('ACTIVATION',true),('HYDRANT',false);
create table private.notification_events (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id),
 type text not null, category text not null, entity_type text not null, entity_id uuid not null,
 teams uuid[] not null default '{}', source_key text not null, created_at timestamptz not null default now(),
 resolved_at timestamptz, unique(type,source_key)
);
create table private.notification_devices (
 installation uuid primary key, user_id uuid not null references public.profiles(id), token text not null,
 active boolean not null default true, revision bigint not null default 1,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index notification_active_token on private.notification_devices(token) where active;
create index notification_devices_user on private.notification_devices(user_id) where active;
create table private.notification_preferences (
 user_id uuid not null references public.profiles(id), category text not null,
 enabled boolean not null, updated_at timestamptz not null default now(), primary key(user_id,category),
 foreign key(category) references private.notification_categories(code)
);
create table private.notification_deliveries (
 id uuid primary key default gen_random_uuid(), event_id uuid not null references private.notification_events(id),
 installation uuid not null references private.notification_devices(installation), user_id uuid not null references public.profiles(id),
 state text not null default 'PENDING' check(state in ('PENDING','LEASED','ACCEPTED','FAILED','SUPPRESSED')),
 attempts int not null default 0 check(attempts between 0 and 5), next_at timestamptz not null default now(),
 lease uuid, lease_until timestamptz, token_revision bigint, provider_id text, failure_code text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(event_id,installation,user_id)
);
create index notification_delivery_due on private.notification_deliveries(next_at) where state in ('PENDING','LEASED');
create index notification_event_unresolved on private.notification_events(created_at) where resolved_at is null;
alter table private.notification_categories enable row level security;
alter table private.notification_events enable row level security;
alter table private.notification_devices enable row level security;
alter table private.notification_preferences enable row level security;
alter table private.notification_deliveries enable row level security;
revoke all on private.notification_categories,private.notification_events,private.notification_devices,private.notification_preferences,private.notification_deliveries from public,anon,authenticated,service_role;

create function private.notification_recipient(e private.notification_events, person uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.user_organizations m join public.profiles p on p.id=m.user_id
 join public.organizations o on o.id=m.organization_id
 where m.user_id=person and m.organization_id=e.organization_id and p.account_status='ACTIVE' and o.active
 and coalesce((select enabled from private.notification_preferences where user_id=person and category=e.category),e.category<>'HYDRANT')
 and ((e.category='HYDRANT' and m.role in ('MANAGER','ADMIN')) or
 (e.category in ('ASSIGNMENT','ACTIVATION') and exists(select 1 from public.inspection_team_members tm
 join public.inspection_teams t on t.id=tm.team_id and t.organization_id=tm.organization_id
 join public.inspection_plan_teams pt on pt.team_id=t.id and pt.organization_id=t.organization_id
 join public.inspection_plans plan on plan.id=pt.plan_id and plan.organization_id=pt.organization_id
 where tm.user_id=person and tm.organization_id=e.organization_id and tm.active and t.active and pt.active
 and pt.plan_id=e.entity_id and plan.status in ('DRAFT','PLANNED','ACTIVE')
 and (cardinality(e.teams)=0 or tm.team_id=any(e.teams))))));
$$;
create function public.notification_preferences(request jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person uuid:=auth.uid(); k text; v jsonb;
begin
 if person is null or not exists(select 1 from public.profiles where id=person and account_status='ACTIVE') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 for k,v in select * from jsonb_each(request) loop
  if not exists(select 1 from private.notification_categories where code=k and user_editable) or jsonb_typeof(v)<>'boolean' then raise exception 'INVALID_PREFERENCE'; end if;
  insert into private.notification_preferences(user_id,category,enabled) values(person,k,v::boolean)
  on conflict(user_id,category) do update set enabled=excluded.enabled,updated_at=now();
 end loop;
 return (select jsonb_object_agg(c.code,coalesce(p.enabled,c.default_enabled)) from private.notification_categories c
 left join private.notification_preferences p on p.user_id=person and p.category=c.code where c.user_editable);
end;
$$;
create function public.register_notification_device(installation uuid, token text, enabled boolean default true) returns void
language plpgsql security definer set search_path='' as $$
declare person uuid:=auth.uid();
begin
 if person is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if not enabled then
  update private.notification_devices d set active=false,updated_at=now(),revision=revision+1 where d.installation=register_notification_device.installation and d.user_id=person;
  return;
 end if;
 if not exists(select 1 from public.profiles where id=person and account_status='ACTIVE') or char_length(token) not between 20 and 4096 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 -- Serialize registration/rotation for this opaque installation. It is not a hardware identifier.
 perform pg_advisory_xact_lock(hashtextextended(installation::text,0));
 update private.notification_devices d set active=false,updated_at=now(),revision=revision+1 where d.token=register_notification_device.token and d.installation<>register_notification_device.installation and d.active;
 insert into private.notification_devices(installation,user_id,token) values(installation,person,token)
 on conflict on constraint notification_devices_pkey do update set user_id=excluded.user_id,token=excluded.token,active=true,revision=notification_devices.revision+1,updated_at=now();
end;
$$;
create function private.capture_notification_event() returns trigger
language plpgsql security definer set search_path='' as $$
declare kind text; category text; entity uuid; teams uuid[]:='{}'; source text;
begin
 if tg_table_name='inspection_plan_teams' then
  if not new.active or (tg_op='UPDATE' and old.active) then return new; end if;
  kind:='PLAN_ASSIGNED';category:='ASSIGNMENT';entity:=new.plan_id;teams:=array[new.team_id];source:=new.plan_id::text||'/'||new.team_id::text||'/'||txid_current()::text;
 elsif tg_table_name='plan_reassignments' then
  kind:='PLAN_REASSIGNED';category:='ASSIGNMENT';entity:=new.plan_id;teams:=array[new.from_team_id,new.to_team_id];source:=new.id::text;
 elsif tg_table_name='inspection_plans' then
  if new.status<>'ACTIVE' or new.status=old.status then return new; end if;
  kind:='PLAN_ACTIVATED';category:='ACTIVATION';entity:=new.id;source:=new.id::text||'/'||new.version::text;
 else
  if new.status=old.status or new.status not in ('NOT_WORKING','NEEDS_INSPECTION') then return new; end if;
  kind:=case new.status when 'NOT_WORKING' then 'HYDRANT_NOT_WORKING' else 'HYDRANT_NEEDS_ATTENTION' end;
  category:='HYDRANT';entity:=new.id;source:=new.id::text||'/'||new.version::text;
 end if;
 insert into private.notification_events(organization_id,type,category,entity_type,entity_id,teams,source_key)
 values(new.organization_id,kind,category,case when category='HYDRANT' then 'HYDRANT' else 'PLAN' end,entity,teams,source) on conflict(type,source_key) do nothing;
 return new;
end;
$$;
create trigger notification_plan_team after insert or update of active on public.inspection_plan_teams for each row execute function private.capture_notification_event();
create trigger notification_reassignment after insert on public.plan_reassignments for each row execute function private.capture_notification_event();
create trigger notification_activation after update of status on public.inspection_plans for each row execute function private.capture_notification_event();
create trigger notification_hydrant after update of status on public.hydrants for each row execute function private.capture_notification_event();

create function public.claim_notification_deliveries() returns jsonb
language plpgsql security definer set search_path='' as $$
declare e private.notification_events; d private.notification_deliveries; device private.notification_devices; result jsonb:='[]'; lease_id uuid;
begin
 -- Bounded retention of delivery telemetry, not business/audit history. Event source keys remain durable.
 delete from private.notification_deliveries where id in (select id from private.notification_deliveries where updated_at<now()-interval '90 days' and state in ('ACCEPTED','FAILED','SUPPRESSED') limit 1000);
 for e in select * from private.notification_events where resolved_at is null order by created_at,id limit 25 for update skip locked loop
  if e.created_at>now()-interval '7 days' then
   insert into private.notification_deliveries(event_id,installation,user_id)
   select distinct e.id,x.installation,x.user_id
   from public.user_organizations m join public.profiles p on p.id=m.user_id and p.account_status='ACTIVE'
   join public.organizations o on o.id=m.organization_id and o.active
   join private.notification_devices x on x.user_id=m.user_id and x.active
   left join private.notification_preferences pref on pref.user_id=m.user_id and pref.category=e.category
   where m.organization_id=e.organization_id and coalesce(pref.enabled,e.category<>'HYDRANT')
   and ((e.category='HYDRANT' and m.role in ('MANAGER','ADMIN')) or
    (e.category in ('ASSIGNMENT','ACTIVATION') and m.user_id in (
     select tm.user_id from public.inspection_team_members tm
     join public.inspection_teams t on t.id=tm.team_id and t.organization_id=tm.organization_id and t.active
     join public.inspection_plan_teams pt on pt.team_id=t.id and pt.organization_id=t.organization_id and pt.active
     join public.inspection_plans plan on plan.id=pt.plan_id and plan.organization_id=pt.organization_id
     where tm.organization_id=e.organization_id and tm.active and pt.plan_id=e.entity_id
     and plan.status in ('DRAFT','PLANNED','ACTIVE') and (cardinality(e.teams)=0 or tm.team_id=any(e.teams)))))
   on conflict(event_id,installation,user_id) do nothing;
  end if;
  update private.notification_events set resolved_at=now() where id=e.id;
 end loop;
 for d in select * from private.notification_deliveries where (state='PENDING' and next_at<=now()) or (state='LEASED' and lease_until<now()) order by next_at,id limit 50 for update skip locked loop
  select * into e from private.notification_events where id=d.event_id;
  select * into device from private.notification_devices where installation=d.installation;
  if not device.active or device.user_id<>d.user_id or not private.notification_recipient(e,d.user_id) or e.created_at<now()-interval '7 days' or d.attempts>=5 then
   update private.notification_deliveries set state='SUPPRESSED',updated_at=now() where id=d.id;continue;
  end if;
  lease_id:=gen_random_uuid();
  update private.notification_deliveries set state='LEASED',attempts=attempts+1,lease=lease_id,lease_until=now()+interval '5 minutes',token_revision=device.revision,updated_at=now() where id=d.id;
  result:=result||jsonb_build_array(jsonb_build_object('id',d.id,'lease',lease_id,'token',device.token,'account',d.user_id,'event',e.id,'type',e.type,'category',e.category,'entity_type',e.entity_type,'entity',e.entity_id,'organization',e.organization_id));
 end loop;
 return result;
end;
$$;
create function public.finish_notification_delivery(delivery uuid, claim uuid, outcome text, provider text default null) returns void
language plpgsql security definer set search_path='' as $$
declare d private.notification_deliveries;
begin
 if outcome not in ('ACCEPTED','RETRY','INVALID_TOKEN','FAILED') then raise exception 'INVALID_OUTCOME'; end if;
 select * into d from private.notification_deliveries where id=delivery and lease=claim and state='LEASED' for update;
 if not found then return; end if;
 update private.notification_deliveries set state=case when outcome='ACCEPTED' then 'ACCEPTED' when outcome='RETRY' and attempts<5 then 'PENDING' else 'FAILED' end,
 next_at=now()+make_interval(secs=>least(3600,30*power(2,attempts)::int)),lease=null,lease_until=null,
 provider_id=case when outcome='ACCEPTED' then left(provider,200) end,failure_code=case when outcome<>'ACCEPTED' then outcome end,updated_at=now() where id=d.id;
 if outcome='INVALID_TOKEN' then update private.notification_devices set active=false,updated_at=now() where installation=d.installation and user_id=d.user_id and revision=d.token_revision; end if;
end;
$$;
revoke all on function private.notification_recipient(private.notification_events,uuid),private.capture_notification_event() from public,anon,authenticated,service_role;
revoke all on function public.notification_preferences(jsonb),public.register_notification_device(uuid,text,boolean),public.claim_notification_deliveries(),public.finish_notification_delivery(uuid,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.notification_preferences(jsonb),public.register_notification_device(uuid,text,boolean) to authenticated;
grant execute on function public.claim_notification_deliveries(),public.finish_notification_delivery(uuid,uuid,text,text) to service_role;
comment on table private.notification_deliveries is 'Bounded transport telemetry. ACCEPTED means FCM accepted, not delivered or read. Retry after an ambiguous timeout may deliver twice; clients replace the same event notification.';

-- NAVIGATE-only filtering; planned routing capacity and ordinary remaining-route semantics are unchanged.
create function public.prepare_navigation_route(organization uuid, request jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare prepared jsonb; items jsonb;
begin
 if request->>'team_id' is null then raise exception 'INVALID_PLAN' using errcode='22023'; end if;
 prepared:=public.prepare_plan_routes(organization,request);
 if coalesce((prepared->>'acknowledged')::boolean,false) then return prepared; end if;
 select coalesce(jsonb_agg(item order by item->>'hydrant'),'[]'::jsonb) into items
 from jsonb_array_elements(prepared->'input'->'items') item
 join public.inspection_plan_items i on i.id=(item->>'id')::uuid and i.organization_id=organization
 join public.hydrants h on h.id=i.hydrant_id and h.organization_id=organization
 where i.active and i.inspection_id is null and i.skipped_at is null and h.active;
 return jsonb_set(prepared,'{input,items}',items);
end;
$$;
revoke all on function public.prepare_navigation_route(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.prepare_navigation_route(uuid,jsonb) to authenticated;
