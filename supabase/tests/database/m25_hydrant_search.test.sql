begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
insert into auth.users(id) select ('e2500000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,6) n;
update public.profiles set account_status='ACTIVE' where id::text like 'e2500000%';
update public.profiles set account_status='PENDING_APPROVAL' where id='e2500000-0000-4000-8000-000000000004';
update public.profiles set account_status='SUSPENDED' where id='e2500000-0000-4000-8000-000000000005';
insert into public.organizations(id,name,code,type) values
('e2500000-0000-4000-8000-000000000011','Search A','M25-A','OTHER'),
('e2500000-0000-4000-8000-000000000012','Search B','M25-B','OTHER');
insert into public.user_organizations(user_id,organization_id,role)
select ('e2500000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
case when n=6 then 'e2500000-0000-4000-8000-000000000012'::uuid else 'e2500000-0000-4000-8000-000000000011'::uuid end,
case n when 1 then 'FIREFIGHTER' when 2 then 'MANAGER' else 'ADMIN' end from generate_series(1,6) n;
insert into public.hydrant_types(id,organization_id,code,name) values
('e2500000-0000-4000-8000-000000000021','e2500000-0000-4000-8000-000000000011','HISTORIC','Historical type');
insert into public.hydrants(id,organization_id,hydrant_type_id,address,location_description,status,active,created_by,updated_by) values
('e2510000-0000-4000-8000-000000000101','e2500000-0000-4000-8000-000000000011','30000000-0000-4000-8000-000000000001',E'Celovška 100%_ "gate", (east) \\ entrance',null,'NOT_WORKING',true,'e2500000-0000-4000-8000-000000000003','e2500000-0000-4000-8000-000000000003'),
('e2510000-0000-4000-8000-000000000102','e2500000-0000-4000-8000-000000000011','30000000-0000-4000-8000-000000000001',null,'North station','WORKING',true,'e2500000-0000-4000-8000-000000000003','e2500000-0000-4000-8000-000000000003'),
('e2510000-0000-4000-8000-000000000103','e2500000-0000-4000-8000-000000000011','30000000-0000-4000-8000-000000000001','Inactive',null,'NOT_WORKING',false,'e2500000-0000-4000-8000-000000000003','e2500000-0000-4000-8000-000000000003'),
('e2510000-0000-4000-8000-000000000104','e2500000-0000-4000-8000-000000000011','e2500000-0000-4000-8000-000000000021','Historical',null,'UNKNOWN',true,'e2500000-0000-4000-8000-000000000003','e2500000-0000-4000-8000-000000000003'),
('e2510000-0000-4000-8000-000000000105','e2500000-0000-4000-8000-000000000012','30000000-0000-4000-8000-000000000001','Celovška foreign',null,'NOT_WORKING',true,'e2500000-0000-4000-8000-000000000003','e2500000-0000-4000-8000-000000000003');
select private.assign_hydrant_code('e2500000-0000-4000-8000-000000000011','e2510000-0000-4000-8000-000000000101','e2500000-0000-4000-8000-000000000003');
update public.hydrant_types set active=false where id='e2500000-0000-4000-8000-000000000021';
insert into public.hydrants(id,organization_id,hydrant_type_id,address,created_by,updated_by)
select ('e2520000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'e2500000-0000-4000-8000-000000000011',
'30000000-0000-4000-8000-000000000001','Scale street '||n,'e2500000-0000-4000-8000-000000000003','e2500000-0000-4000-8000-000000000003' from generate_series(1,2100) n;
analyze public.hydrants;
select ok(not (select prosecdef from pg_proc where oid='public.search_hydrants(uuid,text,uuid,text,text,uuid,integer)'::regprocedure),'search uses invoker/RLS privileges');
set local role anon;
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011')$$,'42501',null,'anonymous search denied');
reset role;
set local role service_role;
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011')$$,'42501',null,'service role has no search grant');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e2500000-0000-4000-8000-000000000004","role":"authenticated"}',true);
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011')$$,'42501',null,'pending cannot search organization');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e2500000-0000-4000-8000-000000000005","role":"authenticated"}',true);
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011')$$,'42501',null,'suspended cannot search organization');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e2500000-0000-4000-8000-000000000006","role":"authenticated"}',true);
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011')$$,'42501',null,'foreign member cannot search organization');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e2500000-0000-4000-8000-000000000001","role":"authenticated"}',true);
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','  celovŠka  ')),1,'address case and trim');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','m25-a-h-000001')),1,'human code search');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','north STATION')),1,'description search');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','%' )),1,'literal percent');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','_')),1,'literal underscore');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','"gate", (east)')),1,'quotes punctuation literal');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','x'' OR true --')),0,'SQL-like input literal');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','',null,null,'inactive')),0,'firefighter inactive only empty');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','Inactive',null,null,'all')),0,'firefighter all cannot reveal inactive');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','Celovška',null,'WORKING')),0,'status AND text');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','Celovška','30000000-0000-4000-8000-000000000001','NOT_WORKING')),1,'combined filters');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','', 'e2500000-0000-4000-8000-000000000021')),1,'inactive type existing record findable');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','', 'e2500000-0000-4000-8000-999999999999')),0,'foreign unknown type has no matches');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011',E' \t\n ')),50,'blank defaults to bounded first page');
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000012','%')$$,'42501',null,'wildcard cannot bypass organization scope');
reset role;
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"e2500000-0000-4000-8000-000000000002","role":"authenticated"}',true);
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','',null,null,'inactive')),1,'manager inactive only');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','Inactive',null,null,'all')),1,'manager all includes inactive');
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011','',null,'FORGED')$$,'22023',null,'invalid query fails safely');
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011','',null,null,'FORGED')$$,'22023',null,'invalid query fails safely');
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011','',null,null,null)$$,'22023',null,'invalid query fails safely');
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011','',null,null,'active',null,0)$$,'22023',null,'invalid query fails safely');
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011','',null,null,'active',null,101)$$,'22023',null,'invalid query fails safely');
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011','',null,null,'active',null,null)$$,'22023',null,'invalid query fails safely');
select throws_ok($$select public.search_hydrants('e2500000-0000-4000-8000-000000000011',repeat('x',201))$$,'22023',null,'invalid query fails safely');
create temporary table search_pages(id uuid primary key);
do $$
declare cursor_id uuid; batch uuid[]; page_count integer := 0;
begin
 loop
  select array_agg(id order by id) into batch from public.search_hydrants('e2500000-0000-4000-8000-000000000011','Scale street',null,null,'active',cursor_id,50);
  exit when batch is null;
  if cardinality(batch)>50 then raise exception 'unbounded page'; end if;
  insert into search_pages select unnest(batch);
  cursor_id:=batch[cardinality(batch)]; page_count:=page_count+1;
 end loop;
 if page_count<>42 then raise exception 'incorrect page count'; end if;
end;
$$;
select is((select count(*)::integer from search_pages),2100,'42 stable pages cover 2100 hydrants with no duplicate or missing IDs');
select is((select count(*)::integer from public.search_hydrants('e2500000-0000-4000-8000-000000000011','Scale street',null,null,'active','ffffffff-ffff-ffff-ffff-ffffffffffff',50)),0,'last page empty');
select ok(not has_table_privilege('authenticated','public.hydrants','INSERT'),'direct writes remain denied');
reset role;
select * from finish();
rollback;
