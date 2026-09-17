-- Transactional, idempotent provisioning. Never copy authorization metadata.
create function private.provision_profile(identity_id uuid)
returns void language sql security definer set search_path = '' as $$
    insert into public.profiles(id, email, display_name, preferred_language,
        account_status, start_screen, inspection_mode)
    select u.id, u.email,
        case when jsonb_typeof(u.raw_user_meta_data->'display_name') = 'string'
            then nullif(left(btrim(u.raw_user_meta_data->>'display_name'), 120), '') end,
        case when u.raw_user_meta_data->>'preferred_language' in ('sl','de')
            then u.raw_user_meta_data->>'preferred_language' else 'sl' end,
        'PENDING_APPROVAL', 'DASHBOARD', 'GUIDED'
    from auth.users u where u.id = identity_id
    on conflict (id) do nothing;
$$;
alter function private.provision_profile(uuid) owner to postgres;
revoke all on function private.provision_profile(uuid) from public, anon, authenticated;

create function private.on_auth_user_created()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    perform private.provision_profile(new.id);
    return new;
end;
$$;
alter function private.on_auth_user_created() owner to postgres;
revoke all on function private.on_auth_user_created() from public, anon, authenticated;
create trigger provision_application_profile after insert on auth.users
    for each row execute function private.on_auth_user_created();
-- Preserve existing application state; repair only identities without profiles.
select private.provision_profile(id) from auth.users;

-- Narrow status contract for all signed-in account states. Existing M1.2 table
-- policies stay intact: inactive users still cannot SELECT profiles or org data.
create function public.get_my_account_status()
returns text language sql stable security definer set search_path = '' as $$
    select p.account_status from public.profiles p where p.id = (select auth.uid());
$$;
alter function public.get_my_account_status() owner to postgres;
revoke all on function public.get_my_account_status() from public, anon, authenticated;
grant execute on function public.get_my_account_status() to authenticated;
comment on function public.get_my_account_status() is 'Caller-only status for auth routing. No target-user parameter, profile details, membership or mutation.';
