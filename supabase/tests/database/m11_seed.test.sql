begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(4);
create temporary table seed_snapshot as
select 'countries' as kind, jsonb_agg(to_jsonb(c) order by id) as records from public.countries c
union all
select 'areas', jsonb_agg(to_jsonb(a) order by id) from public.administrative_areas a;

-- psql paths are relative to this test file. Execute the real seed twice.
\ir ../../seed.sql
\ir ../../seed.sql

select is((select jsonb_agg(to_jsonb(c) order by id) from public.countries c),
          (select records from seed_snapshot where kind='countries'), 're-running seed preserves countries');
select is((select jsonb_agg(to_jsonb(a) order by id) from public.administrative_areas a),
          (select records from seed_snapshot where kind='areas'), 're-running seed preserves administrative areas');
select is((select count(*)::integer from public.countries), 2, 'seed contains only SI and AT');
select is((select count(*)::integer from public.administrative_areas), 7, 'seed is deliberately small');
select * from finish();
rollback;
