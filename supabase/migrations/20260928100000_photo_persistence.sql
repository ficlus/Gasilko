-- M6.1: private immutable photo reservations plus a separate Storage acknowledgement.
-- Storage bytes are written ONLY through the Storage API, never through SQL.
create function private.photo_path(org uuid, hydrant uuid, photo uuid, inspection uuid, mime text)
returns text language sql immutable set search_path = '' as $$
    select 'hydrants/' || org::text || '/' || hydrant::text || '/' ||
        case when inspection is null then 'main/' else 'inspections/' || inspection::text || '/' end ||
        photo::text || case mime when 'image/jpeg' then '.jpg' when 'image/webp' then '.webp' end;
$$;
alter function private.photo_path(uuid,uuid,uuid,uuid,text) owner to postgres;
revoke all on function private.photo_path(uuid,uuid,uuid,uuid,text) from public,anon,authenticated,service_role;

alter table public.inspections add constraint inspections_photo_parent_key unique(id,hydrant_id,organization_id);

create table public.hydrant_photos (
    id uuid primary key,
    organization_id uuid not null references public.organizations(id) on delete restrict,
    hydrant_id uuid not null,
    inspection_id uuid,
    category text not null default 'HYDRANT' check (category = 'HYDRANT'),
    mime_type text not null check (mime_type in ('image/jpeg','image/webp')),
    byte_size bigint not null check (byte_size between 1 and 5242880),
    sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
    captured_at timestamptz not null check (isfinite(captured_at) and captured_at >= '1970-01-01T00:00:00Z'
        and captured_at < '10000-01-01T00:00:00Z'),
    created_by uuid not null references public.profiles(id) on delete restrict,
    created_at timestamptz not null default clock_timestamp(),
    active boolean not null default true,
    uploaded_at timestamptz,
    storage_path text generated always as (private.photo_path(organization_id,hydrant_id,id,inspection_id,mime_type)) stored unique,
    is_primary boolean not null default false,
    constraint hydrant_photos_no_inspection check (inspection_id is null),
    constraint hydrant_photos_hydrant_fk foreign key (hydrant_id,organization_id)
        references public.hydrants(id,organization_id) on delete restrict
);
create index hydrant_photos_scope_idx on public.hydrant_photos(organization_id,hydrant_id,id);

alter table public.hydrant_photos enable row level security;
revoke all on public.hydrant_photos from public,anon,authenticated,service_role;
grant select on public.hydrant_photos to authenticated;

create table public.inspection_photos (
    id uuid primary key,
    organization_id uuid not null references public.organizations(id) on delete restrict,
    hydrant_id uuid not null,
    inspection_id uuid not null,
    category text not null default 'INSPECTION' check (category = 'INSPECTION'),
    mime_type text not null check (mime_type in ('image/jpeg','image/webp')),
    byte_size bigint not null check (byte_size between 1 and 5242880),
    sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
    captured_at timestamptz not null check (isfinite(captured_at) and captured_at >= '1970-01-01T00:00:00Z'
        and captured_at < '10000-01-01T00:00:00Z'),
    created_by uuid not null references public.profiles(id) on delete restrict,
    created_at timestamptz not null default clock_timestamp(),
    active boolean not null default true,
    uploaded_at timestamptz,
    storage_path text generated always as (private.photo_path(organization_id,hydrant_id,id,inspection_id,mime_type)) stored unique,
    constraint inspection_photos_inspection_fk foreign key (inspection_id,hydrant_id,organization_id)
        references public.inspections(id,hydrant_id,organization_id) on delete restrict,
    constraint inspection_photos_hydrant_fk foreign key (hydrant_id,organization_id)
        references public.hydrants(id,organization_id) on delete restrict
);
create index inspection_photos_scope_idx on public.inspection_photos(organization_id,hydrant_id,id);
create index inspection_photos_inspection_idx on public.inspection_photos(inspection_id);
alter table public.inspection_photos enable row level security;
revoke all on public.inspection_photos from public,anon,authenticated,service_role;
grant select on public.inspection_photos to authenticated;

-- Live role/account/organization visibility, including inactive-hydrant conventions.
create function private.photo_visible(org uuid, hydrant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
    select private.is_organization_member(org)
        and exists(select 1 from public.organizations o where o.id=org and o.active)
        and exists(select 1 from public.hydrants h where h.id=hydrant and h.organization_id=org
            and (h.active or private.has_organization_role(org,array['MANAGER','ADMIN']::text[])));
$$;
alter function private.photo_visible(uuid,uuid) owner to postgres;
revoke all on function private.photo_visible(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function private.photo_visible(uuid,uuid) to authenticated;

create policy hydrant_photos_read on public.hydrant_photos for select to authenticated using (
    private.photo_visible(organization_id,hydrant_id)
    and (uploaded_at is not null or created_by=(select auth.uid()))
);

create policy inspection_photos_read on public.inspection_photos for select to authenticated using (
    private.photo_visible(organization_id,hydrant_id)
    and (uploaded_at is not null or created_by=(select auth.uid()))
);

-- Internal lookup, never a public UUID enumeration endpoint.
create function private.photo_record(photo uuid) returns jsonb
language sql stable set search_path = '' as $$
    select to_jsonb(p) from public.hydrant_photos p where p.id=photo
    union all select to_jsonb(p) from public.inspection_photos p where p.id=photo;
$$;
alter function private.photo_record(uuid) owner to postgres;
revoke all on function private.photo_record(uuid) from public,anon,authenticated,service_role;

-- Only acknowledgement metadata may change in M6.1; no business-record deletion.
create function private.photo_receipt_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
    if tg_op <> 'UPDATE' then raise exception 'PHOTO_IMMUTABLE' using errcode='42501'; end if;
    -- AFTER-row guard sees generated storage_path; raising still rolls back the transaction.
    if (to_jsonb(new)-'uploaded_at') is distinct from (to_jsonb(old)-'uploaded_at')
        or old.uploaded_at is not null or new.uploaded_at is null then
        raise exception 'PHOTO_IMMUTABLE' using errcode='42501';
    end if;
    return new;
end;
$$;
alter function private.photo_receipt_guard() owner to postgres;
revoke all on function private.photo_receipt_guard() from public,anon,authenticated,service_role;
create trigger hydrant_photos_guard after update or delete on public.hydrant_photos
    for each row execute function private.photo_receipt_guard();
create trigger hydrant_photos_no_truncate before truncate on public.hydrant_photos
    for each statement execute function private.photo_receipt_guard();
create trigger inspection_photos_guard after update or delete on public.inspection_photos
    for each row execute function private.photo_receipt_guard();
create trigger inspection_photos_no_truncate before truncate on public.inspection_photos
    for each statement execute function private.photo_receipt_guard();

create function public.reserve_photo(photo jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
    org uuid := (photo->>'organization_id')::uuid;
    hydrant uuid := (photo->>'hydrant_id')::uuid;
    photo_id uuid := (photo->>'id')::uuid;
    inspection uuid := (photo->>'inspection_id')::uuid;
    category text := photo->>'category';
    mime text := photo->>'mime_type';
    size bigint := (photo->>'byte_size')::bigint;
    digest text := photo->>'sha256';
    captured timestamptz := (photo->>'captured_at')::timestamptz;
    actor uuid; receipt jsonb; target text; h public.hydrants;
begin
    actor := private.authorize_hydrant_write(org,array['FIREFIGHTER','MANAGER','ADMIN']::text[]);
    select * into h from public.hydrants where id=hydrant and organization_id=org for share;
    if not found or (not h.active and not private.has_organization_role(org,array['MANAGER','ADMIN']::text[])) then
        raise exception 'NOT_AUTHORIZED' using errcode='42501';
    end if;
    if photo_id is null or category is null or category not in ('HYDRANT','INSPECTION')
        or (category='HYDRANT' and inspection is not null) or (category='INSPECTION' and inspection is null)
        or mime is null or mime not in ('image/jpeg','image/webp') or size is null or size not between 1 and 5242880
        or digest is null or digest !~ '^[0-9a-f]{64}$' or captured is null or not isfinite(captured)
        or captured < '1970-01-01T00:00:00Z' or captured >= '10000-01-01T00:00:00Z'
        or (photo->>'created_by') is distinct from actor::text
        or (photo->>'storage_path') is distinct from private.photo_path(org,hydrant,photo_id,inspection,mime) then
        raise exception 'INVALID_PHOTO' using errcode='22023';
    end if;
    if inspection is not null and not exists(select 1 from public.inspections i
        where i.id=inspection and i.hydrant_id=hydrant and i.organization_id=org) then
        raise exception 'NOT_AUTHORIZED' using errcode='42501';
    end if;
    -- One canonical UUID across both categories, including concurrent retries.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(photo_id::text,6101));
    receipt := private.photo_record(photo_id);
    if receipt is not null then
        if (receipt->>'organization_id')::uuid <> org or (receipt->>'hydrant_id')::uuid <> hydrant
            or (receipt->>'created_by')::uuid <> actor or receipt->>'category' <> category
            or (receipt->>'inspection_id')::uuid is distinct from inspection
            or receipt->>'mime_type' <> mime or (receipt->>'byte_size')::bigint <> size
            or receipt->>'sha256' <> digest or (receipt->>'captured_at')::timestamptz <> captured then
            raise exception 'PHOTO_UUID_REUSED' using errcode='23505';
        end if;
        return receipt;
    end if;
    target := case category when 'HYDRANT' then 'hydrant_photos' else 'inspection_photos' end;
    execute format('insert into public.%I(id,organization_id,hydrant_id,inspection_id,category,mime_type,byte_size,sha256,captured_at,created_by)
        values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)',target)
        using photo_id,org,hydrant,inspection,category,mime,size,digest,captured,actor;
    perform private.write_audit(org,actor,'PHOTO_RESERVED',target,photo_id,null,
        jsonb_build_object('hydrant_id',hydrant,'inspection_id',inspection,'category',category));
    return private.photo_record(photo_id);
end;
$$;

-- A missing object is a still-pending reservation, not a success.
-- Only Storage-owned metadata is read; no Storage rows are inserted/updated here.
create function public.confirm_photo(organization uuid, photo_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare actor uuid; receipt jsonb; object_meta jsonb; target text; h public.hydrants;
begin
    actor := private.authorize_hydrant_write(organization,array['FIREFIGHTER','MANAGER','ADMIN']::text[]);
    receipt := private.photo_record(photo_id);
    if receipt is null or (receipt->>'organization_id')::uuid <> organization
        or (receipt->>'created_by')::uuid <> actor then
        raise exception 'NOT_AUTHORIZED' using errcode='42501';
    end if;
    select * into h from public.hydrants where id=(receipt->>'hydrant_id')::uuid and organization_id=organization for share;
    if not found or (not h.active and not private.has_organization_role(organization,array['MANAGER','ADMIN']::text[])) then
        raise exception 'NOT_AUTHORIZED' using errcode='42501';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(photo_id::text,6101));
    receipt := private.photo_record(photo_id);
    if receipt->>'uploaded_at' is not null then return receipt; end if;
    select o.metadata into object_meta from storage.objects o
        where o.bucket_id='hydrant-photos' and o.name=receipt->>'storage_path';
    if not found then return receipt; end if;
    if (object_meta->>'size')::bigint is distinct from (receipt->>'byte_size')::bigint
        or object_meta->>'mimetype' is distinct from receipt->>'mime_type' then
        raise exception 'PHOTO_OBJECT_MISMATCH' using errcode='22023';
    end if;
    target := case receipt->>'category' when 'HYDRANT' then 'hydrant_photos' else 'inspection_photos' end;
    execute format('update public.%I set uploaded_at=clock_timestamp() where id=$1 and uploaded_at is null',target) using photo_id;
    perform private.write_audit(organization,actor,'PHOTO_UPLOADED',target,photo_id,null,
        jsonb_build_object('hydrant_id',h.id,'category',receipt->>'category'));
    return private.photo_record(photo_id);
end;
$$;
alter function public.reserve_photo(jsonb) owner to postgres;
alter function public.confirm_photo(uuid,uuid) owner to postgres;
revoke all on function public.reserve_photo(jsonb),public.confirm_photo(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.reserve_photo(jsonb),public.confirm_photo(uuid,uuid) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('hydrant-photos','hydrant-photos',false,5242880,array['image/jpeg','image/webp']);

create function private.photo_object_read(object_path text) returns boolean
language sql stable security definer set search_path = '' as $$
    select exists(
        select 1 from public.hydrant_photos p where p.storage_path=object_path
            and private.photo_visible(p.organization_id,p.hydrant_id)
            and (p.uploaded_at is not null or p.created_by=(select auth.uid()))
        union all
        select 1 from public.inspection_photos p where p.storage_path=object_path
            and private.photo_visible(p.organization_id,p.hydrant_id)
            and (p.uploaded_at is not null or p.created_by=(select auth.uid()))
    );
$$;

-- Exact reserved path lookup, not trust in a caller-controlled folder name.
create function private.photo_object_insert(object_path text) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare org uuid; hydrant uuid; actor uuid; h public.hydrants;
begin
    select p.organization_id,p.hydrant_id into org,hydrant from (
        select organization_id,hydrant_id,storage_path,created_by,uploaded_at,active from public.hydrant_photos
        union all select organization_id,hydrant_id,storage_path,created_by,uploaded_at,active from public.inspection_photos
    ) p where p.storage_path=object_path and p.created_by=auth.uid() and p.uploaded_at is null and p.active;
    if not found then return false; end if;
    actor := private.authorize_hydrant_write(org,array['FIREFIGHTER','MANAGER','ADMIN']::text[]);
    select * into h from public.hydrants where id=hydrant and organization_id=org for share;
    return found and (h.active or private.has_organization_role(org,array['MANAGER','ADMIN']::text[]));
end;
$$;
alter function private.photo_object_read(text) owner to postgres;
alter function private.photo_object_insert(text) owner to postgres;
revoke all on function private.photo_object_read(text),private.photo_object_insert(text) from public,anon,authenticated,service_role;
grant execute on function private.photo_object_read(text),private.photo_object_insert(text) to authenticated;
create policy photo_objects_read on storage.objects for select to authenticated
    using (bucket_id='hydrant-photos' and private.photo_object_read(name));
create policy photo_objects_insert on storage.objects for insert to authenticated
    with check (bucket_id='hydrant-photos' and private.photo_object_insert(name));
-- No UPDATE/DELETE policy: retries never upsert, move, overwrite or delete evidence.

