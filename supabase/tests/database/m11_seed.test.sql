begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(4);
-- CI executes the real seed twice after reset using psql in the database
-- container. pg_prove mounts only tests, so it cannot include ../../seed.sql.
select results_eq(
    $$select id::text, code::text from public.countries order by id$$,
    $$values ('10000000-0000-4000-8000-000000000001'::text, 'SI'::text),
             ('10000000-0000-4000-8000-000000000002'::text, 'AT'::text)$$,
    'seed preserves exactly the deterministic SI/AT identities');
select results_eq(
    $$select id::text, parent_id::text from public.administrative_areas order by id$$,
    $$values
      ('20000000-0000-4000-8000-000000000001'::text, null::text),
      ('20000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001'),
      ('20000000-0000-4000-8000-000000000003', '20000000-0000-4000-8000-000000000002'),
      ('20000000-0000-4000-8000-000000000011', null),
      ('20000000-0000-4000-8000-000000000012', '20000000-0000-4000-8000-000000000011'),
      ('20000000-0000-4000-8000-000000000013', '20000000-0000-4000-8000-000000000012'),
      ('20000000-0000-4000-8000-000000000014', '20000000-0000-4000-8000-000000000013')$$,
    'seed preserves exactly seven deterministic area identities and parent links');
select is((select count(*)::integer from public.organizations), 0, 'seed creates no organizations');
select is((select count(*)::integer from public.profiles), 0, 'seed creates no profiles');
select * from finish();
rollback;
