-- M14.3: bounded WGS84 GeoJSON without extensions. Helpers are not client APIs.
create function private.incident_segments_intersect(a numeric[],b numeric[],c numeric[],d numeric[]) returns boolean
language plpgsql immutable set search_path='' as $$
declare ab_c numeric; ab_d numeric; cd_a numeric; cd_b numeric;
begin
 if greatest(a[1],b[1])<least(c[1],d[1]) or greatest(c[1],d[1])<least(a[1],b[1])
 or greatest(a[2],b[2])<least(c[2],d[2]) or greatest(c[2],d[2])<least(a[2],b[2]) then return false; end if;
 ab_c:=(b[1]-a[1])*(c[2]-a[2])-(b[2]-a[2])*(c[1]-a[1]);
 ab_d:=(b[1]-a[1])*(d[2]-a[2])-(b[2]-a[2])*(d[1]-a[1]);
 cd_a:=(d[1]-c[1])*(a[2]-c[2])-(d[2]-c[2])*(a[1]-c[1]);
 cd_b:=(d[1]-c[1])*(b[2]-c[2])-(d[2]-c[2])*(b[1]-c[1]);
 return ab_c*ab_d<=0 and cd_a*cd_b<=0;
end; $$;

create function private.validate_incident_geometry(geometry_value jsonb,allowed_types text[]) returns boolean
language plpgsql immutable set search_path='' as $$
declare geometry_type text; paths jsonb; path_value jsonb; point_value jsonb; previous_point jsonb;
 ring_count integer; point_count integer:=0; path_size integer; i integer; j integer; r integer; s integer;
 x numeric; y numeric; area numeric; a numeric[]; b numeric[]; c numeric[]; d numeric[]; ring_points numeric[][];
 other_points numeric[][]; other_path jsonb; inside boolean;
begin
 if geometry_value is null or jsonb_typeof(geometry_value)<>'object' then raise exception 'INVALID_GEOMETRY'; end if;
 if octet_length(geometry_value::text)>65536 then raise exception 'GEOMETRY_TOO_LARGE'; end if;
 if exists(select 1 from jsonb_object_keys(geometry_value) k where k not in ('type','coordinates'))
 or not (geometry_value ? 'type' and geometry_value ? 'coordinates') then raise exception 'UNSUPPORTED_GEOMETRY'; end if;
 geometry_type:=geometry_value->>'type';
 if geometry_type is null or not(geometry_type=any(allowed_types)) or geometry_type not in ('Point','LineString','Polygon') then raise exception 'UNSUPPORTED_GEOMETRY'; end if;
 if jsonb_typeof(geometry_value->'coordinates')<>'array' then raise exception 'INVALID_GEOMETRY'; end if;
 paths:=case geometry_type when 'Point' then jsonb_build_array(jsonb_build_array(geometry_value->'coordinates'))
 when 'LineString' then jsonb_build_array(geometry_value->'coordinates') else geometry_value->'coordinates' end;
 ring_count:=jsonb_array_length(paths);
 if ring_count=0 then raise exception 'INVALID_GEOMETRY'; end if;
 -- Every coordinate is checked before any arithmetic/segment comparison.
 for path_value in select value from jsonb_array_elements(paths) loop
  if jsonb_typeof(path_value)<>'array' then raise exception 'INVALID_GEOMETRY'; end if;
  path_size:=jsonb_array_length(path_value);
  if (geometry_type='LineString' and path_size<2) or (geometry_type='Polygon' and path_size<4) then raise exception 'INVALID_GEOMETRY'; end if;
  point_count:=point_count+path_size;
  if point_count>2000 then raise exception 'GEOMETRY_TOO_LARGE'; end if;
  previous_point:=null;
  for point_value in select value from jsonb_array_elements(path_value) loop
   if jsonb_typeof(point_value)<>'array' then raise exception 'INVALID_GEOMETRY'; end if;
   if jsonb_array_length(point_value)<>2 or jsonb_typeof(point_value->0)<>'number' or jsonb_typeof(point_value->1)<>'number' then raise exception 'INVALID_GEOMETRY'; end if;
   x:=(point_value->>0)::numeric; y:=(point_value->>1)::numeric;
   if not(x between -180 and 180 and y between -90 and 90) then raise exception 'INVALID_GEOMETRY'; end if;
   if previous_point is not null then
    if abs(x-(previous_point->>0)::numeric)>180 then raise exception 'UNSUPPORTED_GEOMETRY'; end if;
    if point_value=previous_point then raise exception 'INVALID_GEOMETRY'; end if;
   end if;
   previous_point:=point_value;
  end loop;
  if geometry_type='Polygon' and path_value->0<>path_value->(path_size-1) then raise exception 'INVALID_GEOMETRY'; end if;
 end loop;
 if geometry_type<>'Polygon' then return true; end if;
 -- O(N^2), N <= 2000 across ALL rings; exact numeric orientation, no tolerance,
 -- simplification or longitude wrapping. Adjacent edges may share only their end.
 for r in 0..ring_count-1 loop
  path_value:=paths->r; path_size:=jsonb_array_length(path_value);
  select array_agg(array[(p.value->>0)::numeric,(p.value->>1)::numeric] order by p.ordinality)
   into ring_points from jsonb_array_elements(path_value) with ordinality p(value,ordinality);
  area:=0;
  for i in 1..path_size-1 loop
   a:=array[ring_points[i][1],ring_points[i][2]]; b:=array[ring_points[i+1][1],ring_points[i+1][2]];
   area:=area+a[1]*b[2]-b[1]*a[2];
   -- Adjacent collinear reversal/overlap is malformed too.
   j:=case when i=path_size-1 then 2 else i+2 end;
   c:=array[ring_points[j][1],ring_points[j][2]];
   if (b[1]-a[1])*(c[2]-b[2])=(b[2]-a[2])*(c[1]-b[1])
    and (a[1]-b[1])*(c[1]-b[1])+(a[2]-b[2])*(c[2]-b[2])>0 then raise exception 'INVALID_GEOMETRY'; end if;
   for j in i+1..path_size-1 loop
    if j=i+1 or (i=1 and j=path_size-1) then continue; end if;
    c:=array[ring_points[j][1],ring_points[j][2]]; d:=array[ring_points[j+1][1],ring_points[j+1][2]];
    if private.incident_segments_intersect(a,b,c,d) then raise exception 'INVALID_GEOMETRY'; end if;
   end loop;
  end loop;
  if area=0 then raise exception 'INVALID_GEOMETRY'; end if;
  for s in 0..r-1 loop
   other_path:=paths->s;
   select array_agg(array[(p.value->>0)::numeric,(p.value->>1)::numeric] order by p.ordinality)
    into other_points from jsonb_array_elements(other_path) with ordinality p(value,ordinality);
   for i in 1..path_size-1 loop
    a:=array[ring_points[i][1],ring_points[i][2]]; b:=array[ring_points[i+1][1],ring_points[i+1][2]];
    for j in 1..jsonb_array_length(other_path)-1 loop
     c:=array[other_points[j][1],other_points[j][2]]; d:=array[other_points[j+1][1],other_points[j+1][2]];
     if private.incident_segments_intersect(a,b,c,d) then raise exception 'INVALID_GEOMETRY'; end if;
    end loop;
   end loop;
   -- A hole must be inside the outer ring, and not inside another hole.
   inside:=false; x:=ring_points[1][1]; y:=ring_points[1][2];
   for j in 1..jsonb_array_length(other_path)-1 loop
    if (other_points[j][2]>y)<>(other_points[j+1][2]>y) then
     if x<(other_points[j+1][1]-other_points[j][1])*(y-other_points[j][2])/(other_points[j+1][2]-other_points[j][2])+other_points[j][1] then inside:=not inside; end if;
    end if;
   end loop;
   if (s=0 and not inside) or (s>0 and inside) then raise exception 'INVALID_GEOMETRY'; end if;
   if s>0 then
    inside:=false; x:=other_points[1][1]; y:=other_points[1][2];
    for j in 1..path_size-1 loop
     if (ring_points[j][2]>y)<>(ring_points[j+1][2]>y) then
      if x<(ring_points[j+1][1]-ring_points[j][1])*(y-ring_points[j][2])/(ring_points[j+1][2]-ring_points[j][2])+ring_points[j][1] then inside:=not inside; end if;
     end if;
    end loop;
    if inside then raise exception 'INVALID_GEOMETRY'; end if;
   end if;
  end loop;
 end loop;
 return true;
end; $$;
revoke all on function private.incident_segments_intersect(numeric[],numeric[],numeric[],numeric[]),private.validate_incident_geometry(jsonb,text[]) from public,anon,authenticated,service_role;

create table public.incident_sectors (
 id uuid primary key, incident_id uuid not null references public.incidents(id),
 code text not null check(code ~ '^[A-Z0-9][A-Z0-9_-]{0,63}$'), name text not null check(length(btrim(name)) between 1 and 200),
 geometry jsonb check(geometry is null or private.validate_incident_geometry(geometry,array['Polygon'])),
 active boolean not null default true, created_by uuid not null references public.profiles(id), updated_by uuid not null references public.profiles(id),
 created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),
 version bigint not null default 1 check(version>0),changed_revision bigint not null check(changed_revision>0),
 unique(id,incident_id),unique(incident_id,code)
);
create table public.incident_map_objects (
 id uuid primary key,incident_id uuid not null references public.incidents(id),
 kind text not null check(kind in ('COMMAND_POST','STAGING','HAZARD','WATER_SOURCE','ACCESS_POINT','PERIMETER','NOTE')),
 label text not null check(length(btrim(label)) between 1 and 200),description text not null default '' check(length(description)<=4000),
 geometry jsonb not null,sector_id uuid,
 active boolean not null default true,created_by uuid not null references public.profiles(id),updated_by uuid not null references public.profiles(id),
 created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),
 version bigint not null default 1 check(version>0),changed_revision bigint not null check(changed_revision>0),
 unique(id,incident_id),foreign key(sector_id,incident_id) references public.incident_sectors(id,incident_id),
 check(private.validate_incident_geometry(geometry,case kind when 'HAZARD' then array['Point','Polygon'] when 'PERIMETER' then array['LineString','Polygon'] else array['Point'] end))
);
create table public.incident_hydrant_links (
 id uuid primary key,incident_id uuid not null references public.incidents(id),hydrant_id uuid not null references public.hydrants(id),
 purpose text not null check(purpose in ('WATER_SUPPLY','REFERENCE')),active boolean not null default true,
 created_by uuid not null references public.profiles(id),updated_by uuid not null references public.profiles(id),
 created_at timestamptz not null default clock_timestamp(),updated_at timestamptz not null default clock_timestamp(),
 version bigint not null default 1 check(version>0),changed_revision bigint not null check(changed_revision>0),unique(id,incident_id)
);
create index incident_sectors_active_idx on public.incident_sectors(incident_id,active,id);
create index incident_map_objects_active_idx on public.incident_map_objects(incident_id,active,changed_revision,id);
create index incident_map_objects_sector_idx on public.incident_map_objects(sector_id,incident_id);
create unique index incident_hydrant_links_active_unique on public.incident_hydrant_links(incident_id,hydrant_id,purpose) where active;
create index incident_hydrant_links_incident_idx on public.incident_hydrant_links(incident_id,active,id);
create index incident_hydrant_links_hydrant_idx on public.incident_hydrant_links(hydrant_id);
alter table public.incident_sectors enable row level security;
alter table public.incident_map_objects enable row level security;
alter table public.incident_hydrant_links enable row level security;
revoke all on public.incident_sectors,public.incident_map_objects,public.incident_hydrant_links from public,anon,authenticated,service_role;
create trigger incident_sectors_no_delete before delete on public.incident_sectors for each row execute function private.audit_immutable();
create trigger incident_sectors_no_truncate before truncate on public.incident_sectors for each statement execute function private.audit_immutable();
create trigger incident_map_objects_no_delete before delete on public.incident_map_objects for each row execute function private.audit_immutable();
create trigger incident_map_objects_no_truncate before truncate on public.incident_map_objects for each statement execute function private.audit_immutable();
create trigger incident_hydrant_links_no_delete before delete on public.incident_hydrant_links for each row execute function private.audit_immutable();
create trigger incident_hydrant_links_no_truncate before truncate on public.incident_hydrant_links for each statement execute function private.audit_immutable();

alter table public.incident_role_assignments add column sector_id uuid,
 add constraint incident_role_sector_fk foreign key(sector_id,incident_id) references public.incident_sectors(id,incident_id),
 add constraint incident_role_sector_scope check((role='SECTOR_COMMANDER')=(sector_id is not null));
alter table public.incident_role_assignments drop constraint incident_role_assignments_role_check;
alter table public.incident_role_assignments add constraint incident_role_assignments_role_check
 check(role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER','AGENCY_COMMANDER','OPERATOR','RESPONDER','SECTOR_COMMANDER'));
create unique index incident_roles_sector_unique on public.incident_role_assignments(sector_id) where status='ACTIVE' and role='SECTOR_COMMANDER';
alter table private.incident_command_consents add column sector_id uuid,
 add constraint incident_consent_sector_fk foreign key(sector_id,incident_id) references public.incident_sectors(id,incident_id),
 add constraint incident_consent_sector_scope check((offered_role='SECTOR_COMMANDER' and sector_id is not null) or (coalesce(offered_role,'')<>'SECTOR_COMMANDER' and sector_id is null));
alter table private.incident_command_consents drop constraint incident_command_consents_offered_role_check;
alter table private.incident_command_consents add constraint incident_command_consents_offered_role_check check(offered_role in ('INCIDENT_COMMANDER','DEPUTY_COMMANDER','AGENCY_COMMANDER','SECTOR_COMMANDER'));
-- A legal 64KiB geometry also needs its command envelope and labels in the SAME receipt.
alter table private.incident_operation_receipts drop constraint incident_operation_receipts_request_check;
alter table private.incident_operation_receipts add constraint incident_operation_receipts_request_check check(octet_length(request::text)<=98304);
