-- M8.4. Existing membership rows continue to mean current access; ending access
-- follows the established DELETE contract and retains its row in immutable history.
alter table public.hydrant_types add column names jsonb not null default '{}' check(jsonb_typeof(names)='object'),
 add column display_order integer not null default 0;
create table private.web_configuration_operators(user_id uuid primary key references public.profiles(id),active boolean not null default true);
revoke all on private.web_configuration_operators from public,anon,authenticated,service_role;
create function private.audit_web_configuration_operator() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform private.write_audit(null,coalesce(nullif(current_setting('gasilko.audit_actor',true),'')::uuid,'00000000-0000-0000-0000-000000000000'),
 'CONFIGURATION_OPERATOR_'||tg_op,'web_configuration_operators',new.user_id,case when tg_op='UPDATE' then to_jsonb(old) else null end,to_jsonb(new));
 return new;
end;
$$;
revoke all on function private.audit_web_configuration_operator() from public,anon,authenticated,service_role;
create trigger web_configuration_operator_audit after insert or update on private.web_configuration_operators for each row execute function private.audit_web_configuration_operator();
create trigger web_configuration_operator_no_delete before delete on private.web_configuration_operators for each row execute function private.audit_immutable();
create trigger web_configuration_operator_no_truncate before truncate on private.web_configuration_operators for each statement execute function private.audit_immutable();
create function private.web_operator() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.web_configuration_operators x join public.profiles p on p.id=x.user_id
 where x.user_id=auth.uid() and x.active and p.account_status='ACTIVE');
$$;
create function public.web_operator_access() returns boolean language sql stable security definer set search_path='' as $$ select private.web_operator(); $$;

create table public.membership_endings(
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id),
 user_id uuid not null references public.profiles(id),role text not null,started_at timestamptz not null,
 ended_at timestamptz not null default clock_timestamp(),ended_by uuid not null);
create index membership_endings_scope on public.membership_endings(organization_id,user_id,ended_at desc);
alter table public.membership_endings enable row level security;
revoke all on public.membership_endings from public,anon,authenticated,service_role;
create function private.retain_ended_membership() returns trigger language plpgsql security definer set search_path='' as $$
declare invitation record;
begin
 insert into public.membership_endings(organization_id,user_id,role,started_at,ended_by)
 values(old.organization_id,old.user_id,old.role,old.created_at,coalesce(auth.uid(),nullif(current_setting('gasilko.audit_actor',true),'')::uuid,'00000000-0000-0000-0000-000000000000'));
 update public.organization_member_positions set active=false,valid_to=greatest(clock_timestamp(),valid_from+interval '1 microsecond')
 where organization_id=old.organization_id and user_id=old.user_id and active;
 -- An outstanding older invitation must not silently restore deliberately ended access.
 for invitation in update public.organization_invitations set status='REVOKED',version=version+1,updated_at=clock_timestamp()
  where organization_id=old.organization_id and status='PENDING' and email=(select lower(email) from auth.users where id=old.user_id) returning id loop
  perform private.write_audit(old.organization_id,coalesce(auth.uid(),nullif(current_setting('gasilko.audit_actor',true),'')::uuid,'00000000-0000-0000-0000-000000000000'),
   'INVITATION_REVOKED_BY_MEMBERSHIP_END','organization_invitations',invitation.id,jsonb_build_object('status','PENDING'),jsonb_build_object('status','REVOKED'));
 end loop;
 return old;
end;
$$;
create trigger retain_ended_membership after delete on public.user_organizations for each row execute function private.retain_ended_membership();
create trigger membership_endings_immutable before update or delete on public.membership_endings for each row execute function private.audit_immutable();
create trigger membership_endings_no_truncate before truncate on public.membership_endings for each statement execute function private.audit_immutable();

-- Transaction-local, private capabilities for the two explicitly approved bootstrap cases.
-- No client can insert a capability or set a session flag to bypass the membership guard.
create table private.web_membership_grants(organization_id uuid not null,user_id uuid not null,role text not null,actor uuid not null,primary key(organization_id,user_id));
revoke all on private.web_membership_grants from public,anon,authenticated,service_role;
create or replace function private.guard_membership() returns trigger
language plpgsql volatile security definer set search_path='' as $$
declare org uuid:=coalesce(new.organization_id,old.organization_id);caller_role text;actor uuid:=auth.uid();bootstrap boolean:=false;
begin
 if tg_op='UPDATE' and (new.user_id<>old.user_id or new.organization_id<>old.organization_id) then raise exception 'Membership identity is immutable' using errcode='23514'; end if;
 perform private.lock_organization(org);
 if tg_op='INSERT' then select exists(select 1 from private.web_membership_grants g where g.organization_id=org and g.user_id=new.user_id and g.role=new.role and g.actor=actor) into bootstrap; end if;
 if current_setting('role',true) in ('authenticated','anon') then
  perform 1 from public.profiles where id=actor and account_status='ACTIVE' for share;
  if not found then raise exception 'Not authorized' using errcode='42501'; end if;
  select role into caller_role from public.user_organizations where user_id=actor and organization_id=org;
  if not bootstrap and (caller_role is null or (caller_role is distinct from 'ADMIN' and not(
   caller_role='MANAGER' and (tg_op='INSERT' or old.role='FIREFIGHTER') and (tg_op='DELETE' or new.role='FIREFIGHTER')))) then
   raise exception 'Not authorized' using errcode='42501';
  end if;
 end if;
 if tg_op<>'INSERT' and old.role='ADMIN' and (tg_op='DELETE' or new.role<>'ADMIN')
 and exists(select 1 from public.organizations where id=org and active)
 and not exists(select 1 from public.user_organizations where organization_id=org and role='ADMIN' and user_id<>old.user_id) then
  raise exception 'Last ADMIN cannot be removed or demoted' using errcode='23514';
 end if;
 if tg_op='DELETE' then return old; end if;return new;
end;
$$;

create table public.organization_invitations(
 id uuid primary key,organization_id uuid not null references public.organizations(id),email text not null,
 role text not null check(role in ('FIREFIGHTER','MANAGER','ADMIN')),position_ids uuid[] not null default '{}',
 message text not null default '' check(length(message)<=2000),status text not null default 'PENDING' check(status in ('PENDING','ACCEPTED','REVOKED')),
 approved_by uuid not null references public.profiles(id),accepted_by uuid references public.profiles(id),accepted_at timestamptz,
 created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default clock_timestamp()+interval '7 days',version bigint not null default 1,
 check(email=lower(btrim(email)) and length(email)<=254 and email like '%_@_%._%'));
create unique index organization_invitations_pending on public.organization_invitations(organization_id,email) where status='PENDING';
create index organization_invitations_email on public.organization_invitations(email,status,expires_at);
create index organization_invitations_list on public.organization_invitations(organization_id,created_at desc,id);
alter table public.organization_invitations enable row level security;
revoke all on public.organization_invitations from public,anon,authenticated,service_role;
create trigger invitations_no_delete before delete on public.organization_invitations for each row execute function private.audit_immutable();
create trigger invitations_no_truncate before truncate on public.organization_invitations for each statement execute function private.audit_immutable();

create function private.web_administration_scope(root uuid) returns setof uuid language sql stable security definer set search_path='' as $$
 select private.web_subtree(root)
 union select o.id from public.organizations o where private.is_active_user() and exists(
 select 1 from public.user_organizations m where m.organization_id=o.id and m.user_id=auth.uid() and m.role='ADMIN')
 and o.id=root;
$$;
-- Inactive organizations are manageable only by their own explicit ADMIN, never by inheritance.
create function private.web_exact_admin(org uuid, allow_inactive boolean default false) returns uuid language plpgsql volatile security definer set search_path='' as $$
begin
 perform private.lock_organization(org);
 perform 1 from public.profiles where id=auth.uid() and account_status='ACTIVE' for share;
 if not found or not private.has_organization_role(org,array['ADMIN']::text[]) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from public.organizations where id=org and (active or allow_inactive) for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return auth.uid();
end;
$$;
create function private.web_revision(data jsonb) returns text language sql immutable set search_path='' as $$ select md5(coalesce(data,'null')::text); $$;
create function private.web_member_snapshot(org uuid,person uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('membership',(select to_jsonb(m) from public.user_organizations m where m.organization_id=org and m.user_id=person),
 'latest_ending',(select to_jsonb(e) from public.membership_endings e where e.organization_id=org and e.user_id=person order by e.ended_at desc,e.id limit 1),
 'positions',(select coalesce(jsonb_agg(to_jsonb(p) order by p.id),'[]') from public.organization_member_positions p where p.organization_id=org and p.user_id=person));
$$;

create function public.web_administration_context(root uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from private.web_administration_scope(root)) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('organizations',(select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'active',o.active,
 'admin',private.has_organization_role(o.id,array['ADMIN']::text[])) order by o.name,o.id),'[]') from public.organizations o where o.id in(select private.web_administration_scope(root))),
 'operator',private.web_operator());
end;
$$;

create function public.web_administration_list(root uuid,kind text,filters jsonb default '{}',page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;scope uuid[];needle text:=lower(left(coalesce(filters->>'search',''),200));
begin
 select array_agg(x) into scope from private.web_administration_scope(root) x;
 if coalesce(cardinality(scope),0)=0 and not(root is null and kind in('types','organizations','relationships') and private.web_operator()) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if nullif(filters->>'organization','') is not null then scope:=array(select x from unnest(scope) x where x=(filters->>'organization')::uuid); end if;
 if kind='users' then
  with people as materialized(
   select m.user_id,m.organization_id,m.role,true active,m.created_at from public.user_organizations m where m.organization_id=any(scope)
   union all select e.user_id,e.organization_id,e.role,false,e.started_at from(
    select distinct on(organization_id,user_id) * from public.membership_endings where organization_id=any(scope) order by organization_id,user_id,ended_at desc,id) e
   where not exists(select 1 from public.user_organizations m where m.organization_id=e.organization_id and m.user_id=e.user_id)),
  filtered as materialized(select m.*,p.display_name,p.email,p.account_status,o.name organization_name from people m join public.profiles p on p.id=m.user_id join public.organizations o on o.id=m.organization_id
   where (needle='' or position(needle in lower(coalesce(p.display_name,'')||' '||coalesce(p.email,'')))>0)
   and (coalesce(filters->>'role','')='' or m.role=filters->>'role')
   and (coalesce(filters->>'state','')='' or m.active=(filters->>'state'='active'))
   and (nullif(filters->>'position','') is null or exists(select 1 from public.organization_member_positions mp where mp.organization_id=m.organization_id and mp.user_id=m.user_id and mp.position_id=(filters->>'position')::uuid and mp.active and mp.valid_from<=now() and (mp.valid_to is null or mp.valid_to>now())))
   order by p.display_name nulls last,m.user_id,m.organization_id limit 51 offset least(greatest(page,0),20000)*50),
  position_rows as materialized(select mp.*,row_number() over(partition by mp.organization_id,mp.user_id order by mp.active desc,mp.updated_at desc,mp.id) n
   from public.organization_member_positions mp join filtered f on f.organization_id=mp.organization_id and f.user_id=mp.user_id),
  position_sets as(select mp.organization_id,mp.user_id,jsonb_agg(to_jsonb(mp)-'n' order by mp.id) snapshot,
   jsonb_agg((to_jsonb(mp)-'n')||jsonb_build_object('names',p.names) order by mp.n) filter(where mp.n<=50) preview,count(*)>50 more
   from position_rows mp join public.organization_positions p on p.id=mp.position_id group by mp.organization_id,mp.user_id),
  ending_rows as materialized(select e.*,row_number() over(partition by e.organization_id,e.user_id order by e.ended_at desc,e.id) n
   from public.membership_endings e join filtered f on f.organization_id=e.organization_id and f.user_id=e.user_id),
  ending_sets as(select organization_id,user_id,(jsonb_agg(to_jsonb(e)-'n') filter(where n=1))->0 latest,
   jsonb_agg(to_jsonb(e)-'n' order by n) filter(where n<=50) preview,count(*)>50 more from ending_rows e group by organization_id,user_id)
  select coalesce(jsonb_agg(to_jsonb(f)||jsonb_build_object('revision',private.web_revision(jsonb_build_object('membership',to_jsonb(m),
   'positions',coalesce(ps.snapshot,'[]'),'latest_ending',es.latest)),
   'positions',coalesce(ps.preview,'[]'),'endings',coalesce(es.preview,'[]'),'history_more',coalesce(ps.more,false) or coalesce(es.more,false))
   order by f.display_name nulls last,f.user_id,f.organization_id),'[]') into rows from filtered f
   left join public.user_organizations m on m.organization_id=f.organization_id and m.user_id=f.user_id
   left join position_sets ps on ps.organization_id=f.organization_id and ps.user_id=f.user_id
   left join ending_sets es on es.organization_id=f.organization_id and es.user_id=f.user_id;
 elsif kind='invitations' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]') into rows from(
   select i.*,o.name organization_name,case when i.status='PENDING' and i.expires_at<=now() then 'EXPIRED' else i.status end effective_status
   from public.organization_invitations i join public.organizations o on o.id=i.organization_id where i.organization_id=any(scope)
   and (needle='' or position(needle in i.email)>0) and (coalesce(filters->>'state','')='' or
    (case when i.status='PENDING' and i.expires_at<=now() then 'EXPIRED' else i.status end)=filters->>'state')
   order by i.created_at desc,i.id limit 51 offset least(greatest(page,0),20000)*50)x;
 elsif kind='requests' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.requested_at desc,x.id),'[]') into rows from(
   select r.*,p.display_name,p.email,o.name organization_name from public.organization_access_requests r join public.profiles p on p.id=r.user_id join public.organizations o on o.id=r.organization_id
   where r.organization_id=any(scope) and (needle='' or position(needle in lower(coalesce(p.email,'')||' '||coalesce(p.display_name,'')))>0)
   order by r.requested_at desc,r.id limit 51 offset least(greatest(page,0),20000)*50)x;
 elsif kind='organizations' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.name,x.id),'[]') into rows from(
   select o.*,t.names type_names,coalesce(t.country_id,a.country_id) country_id,c.name country_name,c.code country_code,private.web_revision(to_jsonb(o)) revision,
    (select count(*) from public.user_organizations where organization_id=o.id) member_count,
    (select count(*) from public.user_organizations m join public.profiles p on p.id=m.user_id where m.organization_id=o.id and m.role='ADMIN' and p.account_status='ACTIVE') admin_count
   from public.organizations o join public.organization_types t on t.id=o.organization_type_id left join public.administrative_areas a on a.id=o.administrative_area_id
   left join public.countries c on c.id=coalesce(t.country_id,a.country_id) where (o.id=any(scope) or (root is null and private.web_operator()))
   and (needle='' or position(needle in lower(o.name||' '||o.code))>0) and (coalesce(filters->>'state','')='' or o.active=(filters->>'state'='active'))
   order by o.name,o.id limit 51 offset least(greatest(page,0),20000)*50)x;
 elsif kind='relationships' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]') into rows from(
   select e.*,p.name parent_name,c.name child_name,t.names type_names,private.web_revision(to_jsonb(e)) revision
   from public.organization_relationships e join public.organizations p on p.id=e.parent_organization_id join public.organizations c on c.id=e.child_organization_id
   join public.organization_relationship_types t on t.code=e.relationship_type where
   (((e.parent_organization_id=any(scope) or e.child_organization_id=any(scope))
    and (private.web_read(e.parent_organization_id) or private.has_organization_role(e.parent_organization_id,array['ADMIN']::text[]))
    and (private.web_read(e.child_organization_id) or private.has_organization_role(e.child_organization_id,array['ADMIN']::text[]))) or (root is null and private.web_operator()))
   and (needle='' or position(needle in lower(p.name||' '||c.name||' '||t.names::text))>0)
   order by e.created_at desc,e.id limit 51 offset least(greatest(page,0),20000)*50)x;
 elsif kind='types' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.display_order,x.name,x.id),'[]') into rows from(
   select t.*,o.name organization_name,private.web_revision(to_jsonb(t)) revision,
   (select count(*) from public.hydrants h where h.hydrant_type_id=t.id and (private.web_operator() or h.organization_id=any(scope))) usage_count
   from public.hydrant_types t left join public.organizations o on o.id=t.organization_id where (t.organization_id is null or t.organization_id=any(scope))
   and (needle='' or position(needle in lower(t.name||' '||t.code))>0) order by t.display_order,t.name,t.id limit 51 offset least(greatest(page,0),20000)*50)x;
 else raise exception 'INVALID_QUERY' using errcode='22023'; end if;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(value order by n),'[]') from jsonb_array_elements(rows) with ordinality a(value,n) where n<=50),'more',jsonb_array_length(rows)>50);
end;
$$;

-- A separate recovery entry point does not make inactive organizations usable by domain APIs.
create function public.web_administration_roots() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('operator',private.web_operator(),'organizations',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'active',o.active) order by o.name,o.id)
 from public.organizations o where private.is_active_user() and exists(select 1 from public.user_organizations m where m.user_id=auth.uid() and m.organization_id=o.id and m.role='ADMIN')),'[]'));
$$;

-- Configuration records are not a personnel directory. Each selector/editor is still paginated.
create function public.web_administration_configuration(kind text,search text default '',page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare tab text;rows jsonb;
begin
 if not private.is_active_user() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if kind='organization_targets' then
  select coalesce(jsonb_agg(to_jsonb(x) order by x.name,x.id),'[]') into rows from(
   select o.id,o.name,o.active from public.organizations o where o.active and
    (private.web_operator() or private.has_organization_role(o.id,array['ADMIN']::text[]))
    and (search='' or position(lower(left(search,200)) in lower(o.name||' '||o.code))>0)
   order by o.name,o.id limit 51 offset least(greatest(page,0),20000)*50)x;
  return jsonb_build_object('rows',(select coalesce(jsonb_agg(value order by n),'[]') from jsonb_array_elements(rows) with ordinality a(value,n) where n<=50),'more',jsonb_array_length(rows)>50);
 end if;
 tab:=case kind when 'countries' then 'countries' when 'organization_types' then 'organization_types'
 when 'relationship_types' then 'organization_relationship_types' when 'rules' then 'organization_type_relationship_rules'
 when 'positions' then 'organization_positions' end;
 if tab is null then raise exception 'INVALID_QUERY' using errcode='22023'; end if;
 execute format('select coalesce(jsonb_agg(d order by d->>''code'',d->>''id''),''[]'') from
 (select to_jsonb(t)||jsonb_build_object(''revision'',private.web_revision(to_jsonb(t))) d from public.%I t
 where ($1='''' or position(lower($1) in lower(to_jsonb(t)::text))>0) order by to_jsonb(t)->>''code'',to_jsonb(t)->>''id'' limit 51 offset $2) q',tab)
 into rows using left(search,200),least(greatest(page,0),20000)*50;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(value order by n),'[]') from jsonb_array_elements(rows) with ordinality a(value,n) where n<=50),'more',jsonb_array_length(rows)>50);
end;
$$;

-- Redact recursively: audit is not a credential or private Storage URL transport.
create function private.web_audit_payload(data jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb;
begin
 if jsonb_typeof(data)='object' then
  select coalesce(jsonb_object_agg(key,private.web_audit_payload(value)),'{}') into result from jsonb_each(data)
   where key !~* '(password|token|secret|credential|authorization|storage_path|url|geometry|photo_bytes)';return result;
 elsif jsonb_typeof(data)='array' then
  select coalesce(jsonb_agg(private.web_audit_payload(value) order by n),'[]') into result from jsonb_array_elements(data) with ordinality a(value,n) where n<=100;return result;
 end if;return data;
end;
$$;
create function public.web_administration_audit(root uuid,filters jsonb default '{}',page integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare scope uuid[];rows jsonb;
begin
 select array_agg(x) into scope from private.web_administration_scope(root) x;
 if root is null then if not private.web_operator() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 elsif coalesce(cardinality(scope),0)=0 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]') into rows from(
 select a.id,a.organization_id,o.name organization_name,a.user_id,p.display_name actor,a.action,a.entity_type,a.entity_id,a.created_at,
 private.web_audit_payload(a.old_data) old_data,private.web_audit_payload(a.new_data) new_data,
 coalesce(a.new_data->>'reason',a.new_data->'request'->>'reason') reason,
 case when a.entity_type='web_administration_operations' then a.entity_id::text else a.new_data->>'operation_id' end operation_id
 from public.audit_log a left join public.profiles p on p.id=a.user_id left join public.organizations o on o.id=a.organization_id
 where ((root is null and a.organization_id is null) or a.organization_id=any(scope))
 and (nullif(filters->>'organization','') is null or a.organization_id=(filters->>'organization')::uuid)
 and (coalesce(filters->>'descendants','true')<>'false' or a.organization_id=root)
 and (nullif(filters->>'from','') is null or a.created_at>=(filters->>'from')::timestamptz)
 and (nullif(filters->>'to','') is null or a.created_at<=(filters->>'to')::timestamptz)
 and (nullif(filters->>'actor','') is null or a.user_id=(filters->>'actor')::uuid)
 and (coalesce(filters->>'action','')='' or position(upper(left(filters->>'action',100)) in a.action)>0)
 and (coalesce(filters->>'entity_type','')='' or a.entity_type=filters->>'entity_type')
 and (nullif(filters->>'entity_id','') is null or a.entity_id=(filters->>'entity_id')::uuid)
 and (coalesce(filters->>'security','false')<>'true' or a.action~'(MEMBER|ROLE|INVIT|ACCESS|ORGANIZATION|POSITION|CONFIGURATION)')
 order by a.created_at desc,a.id limit 51 offset least(greatest(page,0),20000)*50)x;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(value order by n),'[]') from jsonb_array_elements(rows) with ordinality a(value,n) where n<=50),'more',jsonb_array_length(rows)>50);
end;
$$;
create function public.web_administration_dashboard(root uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare scope uuid[];
begin
 select array_agg(x) into scope from private.web_administration_scope(root) x;
 if coalesce(cardinality(scope),0)=0 then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('invitations',(select count(*) from(select 1 from public.organization_invitations where organization_id=any(scope) and status='PENDING' and expires_at>now() limit 1000)x),
 'requests',(select count(*) from(select 1 from public.organization_access_requests where organization_id=any(scope) and status='PENDING' limit 1000)x),
 'ended',(select count(*) from(select distinct e.organization_id,e.user_id from public.membership_endings e where e.organization_id=any(scope) and not exists(select 1 from public.user_organizations m where m.organization_id=e.organization_id and m.user_id=e.user_id) limit 1000)x),
 'no_admin',(select count(*) from(select 1 from public.organizations o where o.id=any(scope) and o.active and not exists(select 1 from public.user_organizations m join public.profiles p on p.id=m.user_id and p.account_status='ACTIVE' where m.organization_id=o.id and m.role='ADMIN') limit 1000)x),
 'recent',(public.web_administration_audit(root,jsonb_build_object('security',true),0)->'rows')->0);
end;
$$;

create unique index audit_administration_receipt on public.audit_log(entity_id) where entity_type='web_administration_operations';
create function public.web_administration_write(organization uuid,operation uuid,action text,request jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare actor uuid:=auth.uid();receipt public.audit_log%rowtype;before_data jsonb;after_data jsonb;result jsonb;
 entity uuid:=(request->>'id')::uuid;person uuid;org uuid;target_role text;tab text;cols text;keycol text;display_names jsonb;
 inv public.organization_invitations%rowtype;edge public.organization_relationships%rowtype;
begin
 if operation is null or request is null or jsonb_typeof(request)<>'object' or octet_length(request::text)>20000 then raise exception 'INVALID_REQUEST' using errcode='22023'; end if;
 -- Match the existing graph lock: all structural authorization checks see a stable graph.
 update private.organization_structure_lock set revision=revision+1 where id;
 perform pg_advisory_xact_lock(hashtextextended(operation::text,842));
 if action='CONFIGURATION' or (action='TYPE' and organization is null) or (action='CHILD' and organization is null) then
  if not private.web_operator() then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform 1 from public.profiles where id=actor and account_status='ACTIVE' for share;
  if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform 1 from private.web_configuration_operators where user_id=actor and active for share;
  if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 elsif action='RELATIONSHIP' and private.web_operator() then
  perform 1 from public.profiles where id=actor and account_status='ACTIVE' for share;
  if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  perform 1 from private.web_configuration_operators where user_id=actor and active for share;
  if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 else perform private.web_exact_admin(organization,action='ORGANIZATION'); end if;
 select * into receipt from public.audit_log where entity_type='web_administration_operations' and entity_id=operation;
 if found then
  if receipt.user_id<>actor or receipt.organization_id is distinct from organization or receipt.new_data->>'action'<>action or receipt.new_data->'request' is distinct from request then raise exception 'CONFLICT' using errcode='40001'; end if;
  return receipt.new_data->'result';
 end if;
 if action in('MEMBERSHIP','ORGANIZATION','RELATIONSHIP','TYPE') and jsonb_typeof(request->'active') is distinct from 'boolean' then raise exception 'INVALID_STATE' using errcode='22023'; end if;
 if action='TYPE' or (action='CONFIGURATION' and request->>'kind' in('organization_types','relationship_types','positions')) then
  display_names:=case when action='TYPE' then request->'names' else request->'data'->'names' end;
  if jsonb_typeof(display_names) is distinct from 'object' then raise exception 'INVALID_NAMES' using errcode='22023'; end if;
  if coalesce(btrim(display_names->>'sl'),'')='' or coalesce(btrim(display_names->>'de'),'')='' or exists(select 1 from jsonb_each(display_names) where jsonb_typeof(value)<>'string' or length(value#>>'{}')>254) then raise exception 'INVALID_NAMES' using errcode='22023'; end if;
 end if;
 if action in ('MEMBERSHIP','POSITION','END_POSITION') then
  person:=nullif(request->>'user_id','')::uuid;
  if person is null and action='MEMBERSHIP' then
   select p.id into person from auth.users u join public.profiles p on p.id=u.id where lower(u.email)=lower(btrim(request->>'email')) and u.email_confirmed_at is not null and p.account_status='ACTIVE';
  end if;
  if person is null then raise exception 'ACTIVE_USER_REQUIRED' using errcode='23514'; end if;
  before_data:=private.web_member_snapshot(organization,person);
  if coalesce(request->>'revision','')='' then
   if action<>'MEMBERSHIP' or before_data->'membership'<>'null'::jsonb or before_data->'latest_ending'<>'null'::jsonb then raise exception 'CONFLICT' using errcode='40001'; end if;
  elsif request->>'revision'<>private.web_revision(before_data) then raise exception 'CONFLICT' using errcode='40001'; end if;
  if action='MEMBERSHIP' then
   target_role:=request->>'role';
   if target_role is null or target_role not in('FIREFIGHTER','MANAGER','ADMIN') then raise exception 'INVALID_ROLE' using errcode='22023'; end if;
   if before_data->'membership'->>'role'='ADMIN' and (target_role<>'ADMIN' or not (request->>'active')::boolean) and not exists(
    select 1 from public.user_organizations m join public.profiles p on p.id=m.user_id and p.account_status='ACTIVE' where m.organization_id=organization and m.role='ADMIN' and m.user_id<>person) then raise exception 'LAST_ADMIN' using errcode='23514'; end if;
   if (request->>'active')::boolean then
    perform 1 from public.profiles where id=person and account_status='ACTIVE' for share;
    if not found then raise exception 'ACTIVE_USER_REQUIRED' using errcode='23514'; end if;
    insert into public.user_organizations(user_id,organization_id,role) values(person,organization,target_role)
     on conflict(user_id,organization_id) do update set role=excluded.role;
   else delete from public.user_organizations where user_id=person and organization_id=organization; end if;
  elsif action='POSITION' then
   insert into public.organization_member_positions(id,organization_id,user_id,position_id,valid_from,valid_to)
   values(entity,organization,person,(request->>'position_id')::uuid,coalesce(nullif(request->>'valid_from','')::timestamptz,clock_timestamp()),nullif(request->>'valid_to','')::timestamptz);
  else
   update public.organization_member_positions set active=false,valid_to=greatest(clock_timestamp(),valid_from+interval '1 microsecond') where id=entity and organization_id=organization and user_id=person and active;
   if not found then raise exception 'CONFLICT' using errcode='40001'; end if;
  end if;
  after_data:=private.web_member_snapshot(organization,person);entity:=person;
 elsif action='ORGANIZATION' then
  select to_jsonb(o) into before_data from public.organizations o where id=organization for update;
  if request->>'revision' is distinct from private.web_revision(before_data) then raise exception 'CONFLICT' using errcode='40001'; end if;
  if not (before_data->>'active')::boolean and not coalesce((request->>'active')::boolean,false) then raise exception 'REACTIVATE_FIRST' using errcode='23514'; end if;
  if (request->>'active')::boolean and not exists(select 1 from public.organization_types t where t.id=(request->>'organization_type_id')::uuid and t.active and (t.country_id is null or exists(select 1 from public.countries where id=t.country_id and active))) then raise exception 'INVALID_TYPE' using errcode='23514'; end if;
  if coalesce((request->>'active')::boolean,false) and not exists(select 1 from public.user_organizations m join public.profiles p on p.id=m.user_id and p.account_status='ACTIVE' where m.organization_id=organization and m.role='ADMIN') then raise exception 'LAST_ADMIN' using errcode='23514'; end if;
  update public.organizations set name=btrim(request->>'name'),code=request->>'code',organization_type_id=(request->>'organization_type_id')::uuid,
   type=(select legacy_type from public.organization_types where id=(request->>'organization_type_id')::uuid),active=(request->>'active')::boolean,
   default_language=request->>'default_language',inspection_interval_months=(request->>'inspection_interval_months')::integer where id=organization returning to_jsonb(organizations.*) into after_data;entity:=organization;
 elsif action='CHILD' then
  if exists(select 1 from public.organizations where id=entity) then raise exception 'CONFLICT' using errcode='40001'; end if;
  insert into public.organizations(id,name,code,type,organization_type_id,default_language)
   select entity,btrim(request->>'name'),request->>'code',legacy_type,id,request->>'default_language' from public.organization_types t where id=(request->>'organization_type_id')::uuid and active and (t.country_id is null or exists(select 1 from public.countries where id=t.country_id and active));
  if not found then raise exception 'INVALID_TYPE' using errcode='23514'; end if;
  if organization is not null then
   if request->>'confirmed' is distinct from 'true' then raise exception 'CONFIRM_REQUIRED' using errcode='22023'; end if;
   insert into public.organization_relationships(id,parent_organization_id,child_organization_id,relationship_type)
   values((request->>'relationship_id')::uuid,organization,entity,request->>'relationship_type');
  end if;
  insert into private.web_membership_grants values(entity,actor,'ADMIN',actor);
  insert into public.user_organizations(user_id,organization_id,role) values(actor,entity,'ADMIN');
  delete from private.web_membership_grants where organization_id=entity and user_id=actor;
  select to_jsonb(o) into after_data from public.organizations o where id=entity;
 elsif action='RELATIONSHIP' then
  if request->>'confirmed' is distinct from 'true' then raise exception 'CONFIRM_REQUIRED' using errcode='22023'; end if;
  select * into edge from public.organization_relationships where id=entity for update;before_data:=case when found then to_jsonb(edge) else null end;
  if request->>'revision' is distinct from case when before_data is null then null else private.web_revision(before_data) end then raise exception 'CONFLICT' using errcode='40001'; end if;
  -- Validate ALL old and new endpoints, even when moving an existing edge.
  for org in select distinct x from unnest(array[edge.parent_organization_id,edge.child_organization_id,(request->>'parent_organization_id')::uuid,(request->>'child_organization_id')::uuid]) x where x is not null order by x loop
   if not private.web_operator() then perform private.web_exact_admin(org); else
    perform private.lock_organization(org);
    perform 1 from public.organizations where id=org and active for share;
    if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
   end if;
  end loop;
  if organization is distinct from (request->>'parent_organization_id')::uuid then raise exception 'INVALID_SCOPE' using errcode='22023'; end if;
  if before_data is not null then
   update public.organization_relationships set active=false,valid_to=greatest(clock_timestamp(),valid_from+interval '1 microsecond') where id=entity;
  end if;
  if (request->>'active')::boolean then
   if exists(select 1 from public.organizations o join public.organization_types t on t.id=o.organization_type_id where o.id in((request->>'parent_organization_id')::uuid,(request->>'child_organization_id')::uuid) and (not t.active or (t.country_id is not null and not exists(select 1 from public.countries where id=t.country_id and active)))) then raise exception 'INVALID_TYPE' using errcode='23514'; end if;
   entity:=coalesce((request->>'replacement_id')::uuid,entity);
   insert into public.organization_relationships(id,parent_organization_id,child_organization_id,relationship_type,valid_from,valid_to)
   values(entity,(request->>'parent_organization_id')::uuid,(request->>'child_organization_id')::uuid,request->>'relationship_type',
    coalesce(nullif(request->>'valid_from','')::timestamptz,clock_timestamp()),nullif(request->>'valid_to','')::timestamptz);
  end if;
  select to_jsonb(e) into after_data from public.organization_relationships e where id=entity;
 elsif action='TYPE' then
  select to_jsonb(t) into before_data from public.hydrant_types t where id=entity for update;
  if request->>'revision' is distinct from case when before_data is null then null else private.web_revision(before_data) end then raise exception 'CONFLICT' using errcode='40001'; end if;
  if before_data is not null and (before_data->>'organization_id')::uuid is distinct from organization then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
  insert into public.hydrant_types(id,organization_id,code,name,names,display_order,active) values(entity,organization,request->>'code',btrim(request->>'name'),request->'names',(request->>'display_order')::integer,(request->>'active')::boolean)
   on conflict(id) do update set name=excluded.name,names=excluded.names,display_order=excluded.display_order,active=excluded.active returning to_jsonb(hydrant_types.*) into after_data;
 elsif action in('INVITE','RESEND','REVOKE') then
  select * into inv from public.organization_invitations where id=entity for update;
  before_data:=case when found then to_jsonb(inv) else null end;
  if action='INVITE' then
   if before_data is not null then raise exception 'CONFLICT' using errcode='40001'; end if;
   insert into public.organization_invitations(id,organization_id,email,role,position_ids,message,approved_by)
   values(entity,organization,lower(btrim(request->>'email')),request->>'role',array(select value::uuid from jsonb_array_elements_text(coalesce(request->'position_ids','[]'))),coalesce(request->>'message',''),actor);
  else
   if inv.organization_id is distinct from organization or inv.status<>'PENDING' or inv.version is distinct from (request->>'version')::bigint then raise exception 'CONFLICT' using errcode='40001'; end if;
   update public.organization_invitations set status=case when action='REVOKE' then 'REVOKED' else status end,
    expires_at=case when action='RESEND' then clock_timestamp()+interval '7 days' else expires_at end,approved_by=actor,version=version+1,updated_at=clock_timestamp() where id=entity;
  end if;
  select to_jsonb(i) into after_data from public.organization_invitations i where id=entity;
  if action<>'REVOKE' and exists(select 1 from unnest(array(select value::uuid from jsonb_array_elements_text(after_data->'position_ids'))) x where not exists(
   select 1 from public.organization_positions p join public.organizations o on o.id=organization join public.organization_types t on t.id=o.organization_type_id left join public.administrative_areas a on a.id=o.administrative_area_id
   where p.id=x and p.active and (p.organization_type_id is null or p.organization_type_id=o.organization_type_id) and (p.country_id is null or p.country_id=coalesce(t.country_id,a.country_id)))) then raise exception 'INVALID_POSITION' using errcode='23514'; end if;
 elsif action='CONFIGURATION' then
  if request->>'confirmed' is distinct from 'true' then raise exception 'CONFIRM_REQUIRED' using errcode='22023'; end if;
  -- Only fixed configuration tables/columns. No client-chosen SQL identifiers.
  case request->>'kind'
   when 'countries' then tab:='countries';cols:='id,code,name,active';
   when 'organization_types' then tab:='organization_types';cols:='id,country_id,code,names,display_order,legacy_type,active,system_managed';
   when 'relationship_types' then tab:='organization_relationship_types';cols:='code,names,inherits_read,hierarchical,path_priority,active';
   when 'rules' then tab:='organization_type_relationship_rules';cols:='id,parent_type_id,child_type_id,relationship_type,active';
   when 'positions' then tab:='organization_positions';cols:='id,country_id,organization_type_id,code,names,classification,suggested_role,active,system_managed';
   else raise exception 'INVALID_CONFIGURATION' using errcode='22023';
  end case;
  keycol:=case when tab='organization_relationship_types' then 'code' else 'id' end;
  execute format('select to_jsonb(t) from public.%I t where %I::text=$1 for update',tab,keycol) into before_data using request->'data'->>keycol;
  if request->>'revision' is distinct from case when before_data is null then null else private.web_revision(before_data) end then raise exception 'CONFLICT' using errcode='40001'; end if;
  if tab='countries' and before_data is not null and before_data->>'code' is distinct from request->'data'->>'code' then raise exception 'IMMUTABLE_CODE' using errcode='23514'; end if;
  execute format('insert into public.%I(%s) select %s from jsonb_populate_record(null::public.%I,$1)
   on conflict(%I) do update set (%s)=(%s) returning to_jsonb(%I.*)',tab,cols,cols,tab,keycol,cols,
   (select string_agg('excluded.'||c,',') from unnest(string_to_array(cols,',')) c),tab)
   into after_data using request->'data';
 else raise exception 'INVALID_ACTION' using errcode='22023'; end if;
 result:=jsonb_build_object('id',entity,'acknowledged',true);
 perform private.write_audit(organization,actor,'ADMINISTRATION_'||action,'web_administration_operations',operation,before_data,
  jsonb_build_object('action',action,'request',request,'after',after_data,'result',result));
 return result;
end;
$$;

create function public.web_invitation_delivery(invitation uuid) returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare i public.organization_invitations%rowtype;
begin
 select * into i from public.organization_invitations where id=invitation;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform private.web_exact_admin(i.organization_id);
 select * into i from public.organization_invitations where id=invitation for share;
 if i.status<>'PENDING' or i.expires_at<=clock_timestamp() then raise exception 'INVITATION_CLOSED' using errcode='23514'; end if;
 return jsonb_build_object('email',i.email,'existing',exists(select 1 from auth.users where lower(email)=i.email));
end;
$$;
create function public.web_my_invitations(page integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare email_address text;rows jsonb;
begin
 select lower(u.email) into email_address from auth.users u join public.profiles p on p.id=u.id
 where u.id=auth.uid() and u.email_confirmed_at is not null and p.account_status in('ACTIVE','PENDING_APPROVAL');
 if email_address is null then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id),'[]') into rows from(
 select i.id,i.role,i.message,i.version,i.expires_at,i.created_at,o.name organization_name,
 case when i.status='PENDING' and i.expires_at<=now() then 'EXPIRED' else i.status end effective_status
 from public.organization_invitations i join public.organizations o on o.id=i.organization_id
 where i.email=email_address order by i.created_at desc,i.id limit 51 offset least(greatest(page,0),20000)*50)x;
 return jsonb_build_object('rows',(select coalesce(jsonb_agg(value order by n),'[]') from jsonb_array_elements(rows) with ordinality a(value,n) where n<=50),'more',jsonb_array_length(rows)>50);
end;
$$;
create function public.web_accept_invitation(invitation uuid,expected_version bigint) returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare i public.organization_invitations%rowtype;actor uuid:=auth.uid();email_address text;state text;existing_role text;pos uuid;
begin
 update private.organization_structure_lock set revision=revision+1 where id;
 select lower(email) into email_address from auth.users where id=actor and email_confirmed_at is not null;
 select account_status into state from public.profiles where id=actor for update;
 if email_address is null or state is null or state not in('ACTIVE','PENDING_APPROVAL') then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into i from public.organization_invitations where id=invitation;
 if not found or i.email<>email_address then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform private.lock_organization(i.organization_id);
 select * into i from public.organization_invitations where id=invitation for update;
 if i.status='ACCEPTED' and i.accepted_by=actor then return jsonb_build_object('acknowledged',true); end if;
 if i.status<>'PENDING' or i.expires_at<=clock_timestamp() or i.version is distinct from expected_version then raise exception 'CONFLICT' using errcode='40001'; end if;
 perform 1 from public.organizations where id=i.organization_id and active for share;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform 1 from public.profiles p join public.user_organizations m on m.user_id=p.id
 where p.id=i.approved_by and p.account_status='ACTIVE' and m.organization_id=i.organization_id and m.role='ADMIN' for share of p,m;
 if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select role into existing_role from public.user_organizations where organization_id=i.organization_id and user_id=actor;
 if existing_role is not null and existing_role<>i.role then raise exception 'MEMBERSHIP_CONFLICT' using errcode='40001'; end if;
 if state='PENDING_APPROVAL' then
  update public.profiles set account_status='ACTIVE' where id=actor;
  perform private.write_audit(i.organization_id,actor,'ACCOUNT_APPROVED_BY_INVITATION','profiles',actor,jsonb_build_object('account_status',state),jsonb_build_object('account_status','ACTIVE','invitation_id',i.id,'approved_by',i.approved_by));
 end if;
 if existing_role is null then
  insert into private.web_membership_grants values(i.organization_id,actor,i.role,actor);
  insert into public.user_organizations(user_id,organization_id,role) values(actor,i.organization_id,i.role);
  delete from private.web_membership_grants where organization_id=i.organization_id and user_id=actor;
 end if;
 foreach pos in array i.position_ids loop
  insert into public.organization_member_positions(organization_id,user_id,position_id) values(i.organization_id,actor,pos)
   on conflict(organization_id,user_id,position_id) where active do nothing;
 end loop;
 update public.organization_invitations set status='ACCEPTED',accepted_by=actor,accepted_at=clock_timestamp(),updated_at=clock_timestamp(),version=version+1 where id=i.id;
 perform private.write_audit(i.organization_id,actor,'INVITATION_ACCEPTED','organization_invitations',i.id,to_jsonb(i),jsonb_build_object('status','ACCEPTED','approved_by',i.approved_by));
 return jsonb_build_object('acknowledged',true);
end;
$$;

-- Explicit execute privileges, including functions which PostgreSQL otherwise grants to PUBLIC.
do $$ declare f record;begin
 for f in select p.oid::regprocedure signature,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in('public','private') and (p.proname like 'web_administration_%' or p.proname in(
 'web_operator','web_operator_access','web_exact_admin','web_revision','web_member_snapshot','web_audit_payload',
 'retain_ended_membership','web_invitation_delivery','web_my_invitations','web_accept_invitation')) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
  if f.nspname='public' then execute format('grant execute on function %s to authenticated',f.signature); end if;
 end loop;
end $$;

-- Append presentation metadata to the existing read projection. No hydrant/inspection data changes.
create or replace view private.web_hydrant_rows as
 select h.*,o.name organization_name,t.name type_name,t.code type_code,t.organization_id type_organization_id,
 latest.completed_at last_inspection_at,latest.id last_inspection_id,
 due.next_due,
 case when due.next_due is null then 'NEVER_INSPECTED' when due.next_due<statement_timestamp() then 'OVERDUE'
 when due.next_due<=statement_timestamp()+interval '30 days' then 'DUE_SOON' else 'CURRENT' end due_state,
 photo.storage_path preview_path,t.names type_names
 from public.hydrants h join public.organizations o on o.id=h.organization_id
 join public.hydrant_types t on t.id=h.hydrant_type_id
 left join lateral(select i.id,i.completed_at from public.inspections i where i.organization_id=h.organization_id
 and i.hydrant_id=h.id and i.result<>'NOT_INSPECTED' order by i.completed_at desc,i.id desc limit 1) latest on true
 cross join lateral(select latest.completed_at + make_interval(months=>coalesce(h.inspection_interval_months,o.inspection_interval_months)) next_due) due
 left join lateral(select p.storage_path from public.hydrant_photos p where p.organization_id=h.organization_id
 and p.hydrant_id=h.id and p.active and p.uploaded_at is not null order by p.captured_at desc,p.id desc limit 1) photo on true;
create or replace function public.web_hydrant_context(root uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 return jsonb_build_object('organizations',(select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,
 'writable',private.can_manage_organization(o.id)) order by o.name,o.id),'[]') from public.organizations o where o.id in(select private.web_subtree(root))),
 'types',(select coalesce(jsonb_agg(to_jsonb(t) order by t.display_order,t.name,t.id),'[]') from public.hydrant_types t
 where t.organization_id is null or t.organization_id in(select private.web_subtree(root))));
end;
$$;
