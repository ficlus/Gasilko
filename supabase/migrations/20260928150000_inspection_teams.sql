-- M7.2: organization teams only; online audited management, no planning model.
create table public.inspection_teams (
    id uuid primary key,
    organization_id uuid not null references public.organizations(id) on delete restrict,
    name text not null check (char_length(btrim(name)) between 1 and 120),
    active boolean not null default true,
    created_by uuid not null references public.profiles(id) on delete restrict,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    unique (id,organization_id)
);
create index inspection_teams_org_idx on public.inspection_teams(organization_id,active,id);
create table public.inspection_team_members (
    team_id uuid not null,
    organization_id uuid not null,
    user_id uuid not null references public.profiles(id) on delete restrict,
    active boolean not null default true,
    added_by uuid not null references public.profiles(id) on delete restrict,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    primary key (team_id,user_id),
    foreign key (team_id,organization_id) references public.inspection_teams(id,organization_id) on delete restrict
);
create index inspection_team_members_org_idx on public.inspection_team_members(organization_id,team_id);
create index inspection_team_members_user_idx on public.inspection_team_members(user_id,organization_id);
alter table public.inspection_teams enable row level security;
alter table public.inspection_team_members enable row level security;
revoke all on public.inspection_teams,public.inspection_team_members from public,anon,authenticated,service_role;
grant select on public.inspection_teams,public.inspection_team_members to authenticated;
create policy inspection_teams_read on public.inspection_teams for select to authenticated using (
    private.is_organization_member(organization_id) and exists(select 1 from public.organizations o where o.id=organization_id and o.active));
create policy inspection_team_members_read on public.inspection_team_members for select to authenticated using (
    private.is_organization_member(organization_id) and exists(select 1 from public.organizations o where o.id=organization_id and o.active));

create function private.audit_team() returns trigger
language plpgsql security definer set search_path='' as $$
declare actor uuid; source text; before_data jsonb; after_data jsonb:=to_jsonb(new);
begin
    if current_setting('role',true)='authenticated' then actor:=auth.uid();source:='authenticated';
    else
        actor:=coalesce(nullif(current_setting('gasilko.audit_actor',true),'')::uuid,'00000000-0000-0000-0000-000000000000'::uuid);
        source:='trusted_database';
    end if;
    if tg_op='UPDATE' then before_data:=to_jsonb(old); end if;
    perform private.write_audit(new.organization_id,actor,'TEAM_'||tg_op,tg_table_name,
        coalesce((after_data->>'id')::uuid,(after_data->>'team_id')::uuid),before_data,
        after_data||jsonb_build_object('actor_source',source,'database_principal',session_user));
    return new;
end;
$$;
revoke all on function private.audit_team() from public,anon,authenticated,service_role;
create trigger inspection_teams_time before insert or update on public.inspection_teams for each row execute function public.maintain_record_timestamps();
create trigger inspection_team_members_time before insert or update on public.inspection_team_members for each row execute function public.maintain_record_timestamps();
create trigger inspection_teams_audit after insert or update on public.inspection_teams for each row execute function private.audit_team();
create trigger inspection_team_members_audit after insert or update on public.inspection_team_members for each row execute function private.audit_team();
create trigger inspection_teams_no_delete before delete on public.inspection_teams for each row execute function private.audit_immutable();
create trigger inspection_team_members_no_delete before delete on public.inspection_team_members for each row execute function private.audit_immutable();
create trigger inspection_teams_no_truncate before truncate on public.inspection_teams for each statement execute function private.audit_immutable();
create trigger inspection_team_members_no_truncate before truncate on public.inspection_team_members for each statement execute function private.audit_immutable();

-- A narrow scoped directory, not a general profiles API. No email or account secrets.
create function public.read_inspection_teams(organization uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
    if not private.is_organization_member(organization) or not exists (
        select 1 from public.organizations where id=organization and active) then
        raise exception 'NOT_AUTHORIZED' using errcode='42501';
    end if;
    return jsonb_build_object(
        'teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.name,t.id) from public.inspection_teams t where t.organization_id=organization),'[]'::jsonb),
        'members',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('display_name',p.display_name) order by m.team_id,m.user_id)
            from public.inspection_team_members m join public.profiles p on p.id=m.user_id where m.organization_id=organization),'[]'::jsonb),
        'people',case when private.has_organization_role(organization,array['MANAGER','ADMIN']::text[]) then
            coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name) order by p.display_name,p.id)
            from public.user_organizations u join public.profiles p on p.id=u.user_id
            where u.organization_id=organization and p.account_status='ACTIVE'),'[]'::jsonb) else '[]'::jsonb end);
end;
$$;

create function public.manage_inspection_team(organization uuid, team uuid, operation text,
    team_name text default null, enabled boolean default null, member uuid default null, initial_members uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare actor uuid; t public.inspection_teams; person uuid;
begin
    actor:=private.authorize_hydrant_write(organization,array['MANAGER','ADMIN']::text[]);
    if team is null or operation is null or operation not in ('CREATE','RENAME','ACTIVE','ADD','REMOVE') then
        raise exception 'INVALID_TEAM' using errcode='22023';
    end if;
    select * into t from public.inspection_teams where id=team and organization_id=organization for update;
    if operation='CREATE' then
        if team_name is null or char_length(btrim(team_name)) not between 1 and 120 or coalesce(cardinality(initial_members),0)<1 then
            raise exception 'TEAM_NAME_AND_MEMBERS_REQUIRED' using errcode='22023';
        end if;
        if found then
            -- A lost response may retry the same client UUID, never create a duplicate.
            if t.created_by<>actor or t.name<>btrim(team_name) or not t.active or
                (select array_agg(user_id order by user_id) from public.inspection_team_members where team_id=team and active)
                is distinct from (select array_agg(distinct u order by u) from unnest(initial_members) u) then
                raise exception 'TEAM_UUID_REUSED' using errcode='23505';
            end if;
            return public.read_inspection_teams(organization);
        end if;
        foreach person in array initial_members loop
            perform 1 from public.profiles p join public.user_organizations u on u.user_id=p.id
                where p.id=person and p.account_status='ACTIVE' and u.organization_id=organization for share of p;
            if not found then raise exception 'INVALID_TEAM_MEMBER' using errcode='22023'; end if;
        end loop;
        insert into public.inspection_teams(id,organization_id,name,created_by) values(team,organization,btrim(team_name),actor);
        insert into public.inspection_team_members(team_id,organization_id,user_id,added_by)
            select team,organization,u,actor from (select distinct unnest(initial_members) u) members;
    else
        if not found then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
        if operation='RENAME' then
            if team_name is null or char_length(btrim(team_name)) not between 1 and 120 then
                raise exception 'INVALID_TEAM_NAME' using errcode='22023';
            end if;
            update public.inspection_teams set name=btrim(team_name) where id=team and name<>btrim(team_name);
        elsif operation='ACTIVE' then
            if enabled is null then raise exception 'INVALID_TEAM' using errcode='22023'; end if;
            if enabled and not exists(select 1 from public.inspection_team_members where team_id=team and active) then
                raise exception 'TEAM_MEMBER_REQUIRED' using errcode='22023';
            end if;
            update public.inspection_teams set active=enabled where id=team and active<>enabled;
        elsif operation='ADD' then
            perform 1 from public.profiles p join public.user_organizations u on u.user_id=p.id
                where p.id=member and p.account_status='ACTIVE' and u.organization_id=organization for share of p;
            if not found then raise exception 'INVALID_TEAM_MEMBER' using errcode='22023'; end if;
            insert into public.inspection_team_members(team_id,organization_id,user_id,added_by)
                values(team,organization,member,actor)
                on conflict(team_id,user_id) do update set active=true where not inspection_team_members.active;
        else
            if member is null then raise exception 'INVALID_TEAM_MEMBER' using errcode='22023'; end if;
            if exists(select 1 from public.inspection_team_members where team_id=team and user_id=member and active)
                and not exists(select 1 from public.inspection_team_members where team_id=team and user_id<>member and active) then
                raise exception 'TEAM_MEMBER_REQUIRED' using errcode='22023';
            end if;
            update public.inspection_team_members set active=false where team_id=team and user_id=member and active;
        end if;
    end if;
    return public.read_inspection_teams(organization);
end;
$$;

-- Revoking organization membership/account access also revokes assignment eligibility.
-- History is kept; a now-empty team becomes inactive and can be repaired by adding a member.
create function private.revoke_team_eligibility() returns trigger
language plpgsql security definer set search_path='' as $$
declare target uuid; org uuid;
begin
    if tg_table_name='profiles' then
        if new.account_status='ACTIVE' or new.account_status=old.account_status then return new; end if;
        target:=new.id;
        for org in select distinct organization_id from public.inspection_team_members where user_id=target and active order by organization_id loop
            perform private.lock_organization(org);
            update public.inspection_team_members set active=false where organization_id=org and user_id=target and active;
            update public.inspection_teams t set active=false where t.organization_id=org and t.active and
                not exists(select 1 from public.inspection_team_members m where m.team_id=t.id and m.active);
        end loop;
        return new;
    end if;
    target:=old.user_id;org:=old.organization_id;
    perform private.lock_organization(org);
    update public.inspection_team_members set active=false where organization_id=org and user_id=target and active;
    update public.inspection_teams t set active=false where t.organization_id=org and t.active and
        not exists(select 1 from public.inspection_team_members m where m.team_id=t.id and m.active);
    return old;
end;
$$;
revoke all on function private.revoke_team_eligibility() from public,anon,authenticated,service_role;
create trigger team_membership_revoked after delete on public.user_organizations for each row execute function private.revoke_team_eligibility();
create trigger team_account_revoked after update of account_status on public.profiles for each row execute function private.revoke_team_eligibility();
alter function public.read_inspection_teams(uuid) owner to postgres;
alter function public.manage_inspection_team(uuid,uuid,text,text,boolean,uuid,uuid[]) owner to postgres;
alter function private.audit_team() owner to postgres;
alter function private.revoke_team_eligibility() owner to postgres;
revoke all on function public.read_inspection_teams(uuid),public.manage_inspection_team(uuid,uuid,text,text,boolean,uuid,uuid[]) from public,anon,authenticated,service_role;
grant execute on function public.read_inspection_teams(uuid),public.manage_inspection_team(uuid,uuid,text,text,boolean,uuid,uuid[]) to authenticated;
