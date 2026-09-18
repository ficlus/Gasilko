-- LOCAL development fixtures only. Stable UUIDs keep repeated resets reproducible.
-- Global reference types; configurable codes, never an enum limited to these four.
insert into public.hydrant_types(id, code, name) values
    ('30000000-0000-4000-8000-000000000001', 'ABOVE_GROUND', 'Nadzemni'),
    ('30000000-0000-4000-8000-000000000002', 'UNDERGROUND', 'Podzemni'),
    ('30000000-0000-4000-8000-000000000003', 'WALL', 'Zidni'),
    ('30000000-0000-4000-8000-000000000004', 'OTHER', 'Drugi')
on conflict (id) do update set code = excluded.code, name = excluded.name, active = true;

-- No users or organizations are seeded. These are representative sample areas,
-- not an authoritative administrative/geographic dataset; boundaries are unset.
insert into public.countries (id, code, name) values
    ('10000000-0000-4000-8000-000000000001', 'SI', 'Slovenia'),
    ('10000000-0000-4000-8000-000000000002', 'AT', 'Austria')
on conflict (id) do update set code = excluded.code, name = excluded.name, active = true;

-- Insert parent levels first: the hierarchy has no fixed depth.
insert into public.administrative_areas (id, country_id, parent_id, name, area_type) values
    ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', null, 'Osrednjeslovenska (development sample)', 'REGION'),
    ('20000000-0000-4000-8000-000000000011', '10000000-0000-4000-8000-000000000002', null, 'Steiermark (development sample)', 'BUNDESLAND')
on conflict (id) do update set country_id = excluded.country_id, parent_id = excluded.parent_id, name = excluded.name, area_type = excluded.area_type, active = true;

insert into public.administrative_areas (id, country_id, parent_id, name, area_type) values
    ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', 'Ljubljana (development sample)', 'MUNICIPALITY'),
    ('20000000-0000-4000-8000-000000000012', '10000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000011', 'Graz-Umgebung (development sample)', 'BEZIRK')
on conflict (id) do update set country_id = excluded.country_id, parent_id = excluded.parent_id, name = excluded.name, area_type = excluded.area_type, active = true;

insert into public.administrative_areas (id, country_id, parent_id, name, area_type) values
    ('20000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000002', 'Sample fire department SI', 'FIRE_DEPARTMENT'),
    ('20000000-0000-4000-8000-000000000013', '10000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000012', 'Gratkorn (development sample)', 'GEMEINDE')
on conflict (id) do update set country_id = excluded.country_id, parent_id = excluded.parent_id, name = excluded.name, area_type = excluded.area_type, active = true;

insert into public.administrative_areas (id, country_id, parent_id, name, area_type) values
    ('20000000-0000-4000-8000-000000000014', '10000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000013', 'Sample fire department AT', 'FEUERWEHR')
on conflict (id) do update set country_id = excluded.country_id, parent_id = excluded.parent_id, name = excluded.name, area_type = excluded.area_type, active = true;
