begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

select results_eq(
 $$select id::text,code,name from public.hydrant_types order by id$$,
 $$values ('30000000-0000-4000-8000-000000000001'::text,'ABOVE_GROUND'::text,'Nadzemni'::text),
 ('30000000-0000-4000-8000-000000000002','UNDERGROUND','Podzemni'),
 ('30000000-0000-4000-8000-000000000003','WALL','Zidni'),
 ('30000000-0000-4000-8000-000000000004','OTHER','Drugi')$$,
 'repeat seed preserves exactly four global reference identities');
select is((select count(*)::integer from public.hydrants),0,'no production hydrants seeded');
insert into auth.users(id) values ('e2100000-0000-4000-8000-000000000001'),('e2100000-0000-4000-8000-000000000002');
insert into public.organizations(id,name,code,type) values
 ('e2100000-0000-4000-8000-000000000011','Fixture A','M21-A','OTHER'),
 ('e2100000-0000-4000-8000-000000000012','Fixture B','M21-B','OTHER'),
 ('e2100000-0000-4000-8000-000000000013','Fixture C','M21-C','OTHER');
create function pg_temp.new_hydrant(changes jsonb default '{}'::jsonb) returns uuid
language plpgsql as $$
declare result uuid;
begin
 insert into public.hydrants select r.* from jsonb_populate_record(null::public.hydrants,
 jsonb_build_object('id',gen_random_uuid(),'organization_id','e2100000-0000-4000-8000-000000000011',
 'hydrant_type_id','30000000-0000-4000-8000-000000000001','address','Test address','status','UNKNOWN',
 'active',true,'version',1,'created_by','e2100000-0000-4000-8000-000000000001',
 'updated_by','e2100000-0000-4000-8000-000000000001',
 'created_at',statement_timestamp(),'updated_at',statement_timestamp()) || changes) r returning id into result;
 return result;
end;
$$;
select lives_ok($$insert into public.hydrant_types(code,name) values('FUTURE_TYPE','Future')$$,'new global codes need no migration');
select lives_ok($$insert into public.hydrant_types(id,organization_id,code,name) values
 ('e2100000-0000-4000-8000-000000000021','e2100000-0000-4000-8000-000000000011','WALL','Local wall'),
 ('e2100000-0000-4000-8000-000000000022','e2100000-0000-4000-8000-000000000012','WALL','Other wall')$$,'same code allowed in distinct scopes');
select throws_ok($$insert into public.hydrant_types(code,name) values('WALL','Duplicate')$$,'23505',null,'global type codes unique');
select throws_ok($$insert into public.hydrant_types(organization_id,code,name) values('e2100000-0000-4000-8000-000000000011','WALL','Duplicate')$$,'23505',null,'organization type codes unique');
select throws_ok($$update public.hydrant_types set organization_id=null where id='e2100000-0000-4000-8000-000000000021'$$,'23514',null,'type ownership immutable');
select throws_ok($$update public.hydrant_types set id=gen_random_uuid() where id='e2100000-0000-4000-8000-000000000021'$$,'23514',null,'type identity immutable');
select throws_ok($$insert into public.hydrant_types(code,name) values('lowercase','Name')$$,'23514',null,'canonical type code');
select throws_ok($$insert into public.hydrant_types(code,name) values('BLANK',E' \t\n')$$,'23514',null,'blank type name rejected');
select lives_ok($$select pg_temp.new_hydrant('{"address":null,"latitude":46.123456,"longitude":14.654321}'::jsonb)$$,'coordinate-only location');
select lives_ok($$select pg_temp.new_hydrant('{"address":null,"latitude":-90,"longitude":-180}'::jsonb)$$,'negative coordinate boundaries');
select lives_ok($$select pg_temp.new_hydrant('{"address":null,"latitude":90,"longitude":180}'::jsonb)$$,'positive coordinate boundaries');
select lives_ok($$select pg_temp.new_hydrant('{"address":null,"latitude":0,"longitude":0}'::jsonb)$$,'zero coordinates usable');
select lives_ok($$select pg_temp.new_hydrant('{}'::jsonb)$$,'address-only location');
select lives_ok($$select pg_temp.new_hydrant('{"address":null,"location_description":"Beside station"}'::jsonb)$$,'description-only location');
select lives_ok($$select pg_temp.new_hydrant('{"latitude":45,"longitude":14}'::jsonb)$$,'coordinates and address');
select throws_ok($$select pg_temp.new_hydrant('{"latitude":45}'::jsonb)$$,'23514',null,'latitude without longitude even with address');
select throws_ok($$select pg_temp.new_hydrant('{"longitude":14}'::jsonb)$$,'23514',null,'longitude without latitude even with address');
select throws_ok($$select pg_temp.new_hydrant('{"latitude":90.000001,"longitude":14}'::jsonb)$$,'23514',null,'latitude over upper bound');
select throws_ok($$select pg_temp.new_hydrant('{"latitude":-90.000001,"longitude":14}'::jsonb)$$,'23514',null,'latitude under lower bound');
select throws_ok($$select pg_temp.new_hydrant('{"latitude":45,"longitude":180.000001}'::jsonb)$$,'23514',null,'longitude over upper bound');
select throws_ok($$select pg_temp.new_hydrant('{"latitude":45,"longitude":-180.000001}'::jsonb)$$,'23514',null,'longitude under lower bound');
select throws_ok($$select pg_temp.new_hydrant('{"latitude":"NaN","longitude":14}'::jsonb)$$,'23514',null,'NaN latitude rejected');
select throws_ok($$select pg_temp.new_hydrant('{"address":null}'::jsonb)$$,'23514',null,'missing location rejected');
select throws_ok($$select pg_temp.new_hydrant('{"address":" \t\n","location_description":" \r\n"}'::jsonb)$$,'23514',null,'whitespace is not a location');
select throws_ok($$select pg_temp.new_hydrant('{"address":"","location_description":""}'::jsonb)$$,'23514',null,'empty strings not a location');
select lives_ok($$select pg_temp.new_hydrant('{"inspection_interval_months":null}'::jsonb)$$,'null interval uses organization default');
select lives_ok($$select pg_temp.new_hydrant('{"inspection_interval_months":1}'::jsonb)$$,'positive interval override');
select throws_ok($$select pg_temp.new_hydrant('{"inspection_interval_months":0}'::jsonb)$$,'23514',null,'zero interval rejected');
select throws_ok($$select pg_temp.new_hydrant('{"inspection_interval_months":-1}'::jsonb)$$,'23514',null,'negative interval rejected');
select lives_ok($$select pg_temp.new_hydrant('{"status":"WORKING"}'::jsonb)$$,'WORKING status valid');
select lives_ok($$select pg_temp.new_hydrant('{"status":"NOT_WORKING"}'::jsonb)$$,'NOT_WORKING status valid');
select lives_ok($$select pg_temp.new_hydrant('{"status":"NEEDS_INSPECTION"}'::jsonb)$$,'NEEDS_INSPECTION status valid');
select lives_ok($$select pg_temp.new_hydrant('{"status":"UNKNOWN"}'::jsonb)$$,'UNKNOWN status valid');
select throws_ok($$select pg_temp.new_hydrant('{"status":"OVERDUE"}'::jsonb)$$,'23514',null,'OVERDUE cannot be stored');
select throws_ok($$select pg_temp.new_hydrant('{"status":"INVALID"}'::jsonb)$$,'23514',null,'unknown status rejected');
select lives_ok($$select pg_temp.new_hydrant('{"hydrant_type_id":"e2100000-0000-4000-8000-000000000021"}'::jsonb)$$,'own organization type allowed');
select throws_ok($$select pg_temp.new_hydrant('{"hydrant_type_id":"e2100000-0000-4000-8000-000000000022"}'::jsonb)$$,'23514',null,'foreign organization type rejected');
select throws_ok($$select pg_temp.new_hydrant('{"hydrant_type_id":"e2100000-0000-4000-8000-000000000099"}'::jsonb)$$,'23503',null,'missing type rejected');
select throws_ok($$select pg_temp.new_hydrant('{"organization_id":"e2100000-0000-4000-8000-000000000099"}'::jsonb)$$,'23503',null,'missing organization rejected');
select throws_ok($$select pg_temp.new_hydrant('{"created_by":"e2100000-0000-4000-8000-000000000099"}'::jsonb)$$,'23503',null,'creator FK required');
select throws_ok($$select pg_temp.new_hydrant('{"updated_by":"e2100000-0000-4000-8000-000000000099"}'::jsonb)$$,'23503',null,'updater FK required');
select throws_ok($$select pg_temp.new_hydrant('{"created_by":null}'::jsonb)$$,'23502',null,'creator not null');
select throws_ok($$select pg_temp.new_hydrant('{"updated_by":null}'::jsonb)$$,'23502',null,'updater not null');
select throws_ok($$select pg_temp.new_hydrant('{"code":"M21-A-H-000123"}'::jsonb)$$,'23514',null,'direct insert cannot preassign a code');

select pg_temp.new_hydrant('{"id":"e2100000-0000-4000-8000-000000000031","version":999,"created_at":"2000-01-01","updated_at":"2000-01-01"}');
select is((select version from public.hydrants where id='e2100000-0000-4000-8000-000000000031'),1::bigint,'server fixes insert version');
select ok((select created_at>'2000-01-02' and created_at=updated_at and code is null and active and status='UNKNOWN'
 from public.hydrants where id='e2100000-0000-4000-8000-000000000031'),'server timestamps and offline null code');
create temporary table before_hydrant as select * from public.hydrants where id='e2100000-0000-4000-8000-000000000031';
update public.hydrants set version=765,created_at='2000-01-01',updated_at='2000-01-01',
 updated_by='e2100000-0000-4000-8000-000000000002' where id='e2100000-0000-4000-8000-000000000031';
select results_eq($$select version,created_at,updated_at,updated_by from public.hydrants where id='e2100000-0000-4000-8000-000000000031'$$,
 $$select version,created_at,updated_at,updated_by from before_hydrant$$,'metadata-only update preserves version timestamps and actor');
update public.hydrants set notes='Changed',version=999,updated_at='2000-01-01',
 updated_by='e2100000-0000-4000-8000-000000000002' where id='e2100000-0000-4000-8000-000000000031';
select ok((select version=2 and updated_at>'2000-01-02' and updated_by='e2100000-0000-4000-8000-000000000002'
 from public.hydrants where id='e2100000-0000-4000-8000-000000000031'),'meaningful update increments once with server time and supplied trusted actor');
select is((select created_at from public.hydrants where id='e2100000-0000-4000-8000-000000000031'),(select created_at from before_hydrant),'creation time immutable');
select throws_ok($$update public.hydrants set organization_id='e2100000-0000-4000-8000-000000000012' where id='e2100000-0000-4000-8000-000000000031'$$,'23514',null,'hydrant organization immutable');
select throws_ok($$update public.hydrants set id=gen_random_uuid() where id='e2100000-0000-4000-8000-000000000031'$$,'23514',null,'hydrant identity immutable');
select throws_ok($$update public.hydrants set created_by='e2100000-0000-4000-8000-000000000002' where id='e2100000-0000-4000-8000-000000000031'$$,'23514',null,'creator immutable');
select throws_ok($$update public.hydrants set hydrant_type_id='e2100000-0000-4000-8000-000000000022' where id='e2100000-0000-4000-8000-000000000031'$$,'23514',null,'foreign type rejected on update');
update public.hydrant_types set active=false where id='30000000-0000-4000-8000-000000000001';
select lives_ok($$update public.hydrants set notes='Historical type retained' where id='e2100000-0000-4000-8000-000000000031'$$,'existing inactive type permits ordinary edit');
select throws_ok($$select pg_temp.new_hydrant()$$,'23514',null,'new inactive reference rejected');
select pg_temp.new_hydrant('{"id":"e2100000-0000-4000-8000-000000000032","hydrant_type_id":"30000000-0000-4000-8000-000000000002"}');
select throws_ok($$update public.hydrants set hydrant_type_id='30000000-0000-4000-8000-000000000001' where id='e2100000-0000-4000-8000-000000000032'$$,'23514',null,'switch to inactive type rejected');
update public.hydrant_types set active=true where id='30000000-0000-4000-8000-000000000001';
select throws_ok($$delete from public.hydrant_types where id='30000000-0000-4000-8000-000000000001'$$,'23503',null,'referenced type delete restricted');
select throws_ok($$delete from public.organizations where id='e2100000-0000-4000-8000-000000000011'$$,'23503',null,'referenced organization delete restricted');
select throws_ok($$delete from public.profiles where id='e2100000-0000-4000-8000-000000000001'$$,'23503',null,'referenced creator delete restricted');
select throws_ok($$update public.hydrants set code='ARBITRARY' where id='e2100000-0000-4000-8000-000000000031'$$,'23514',null,'direct null-to-code assignment denied');
select throws_ok($$select private.assign_hydrant_code('e2100000-0000-4000-8000-000000000012','e2100000-0000-4000-8000-000000000031','e2100000-0000-4000-8000-000000000001')$$,'22023',null,'allocation scoped to owning organization');
select throws_ok($$select private.assign_hydrant_code('e2100000-0000-4000-8000-000000000011','e2100000-0000-4000-8000-000000000031',null)$$,'23503',null,'allocation requires valid actor');
select is(private.assign_hydrant_code('e2100000-0000-4000-8000-000000000011','e2100000-0000-4000-8000-000000000031','e2100000-0000-4000-8000-000000000001'),'M21-A-H-000001','first organization code format');
select is((select version from public.hydrants where id='e2100000-0000-4000-8000-000000000031'),4::bigint,'code assignment is meaningful change');
select is(private.assign_hydrant_code('e2100000-0000-4000-8000-000000000011','e2100000-0000-4000-8000-000000000031','e2100000-0000-4000-8000-000000000002'),'M21-A-H-000001','repeated allocation idempotent');
select is((select version from public.hydrants where id='e2100000-0000-4000-8000-000000000031'),4::bigint,'repeated allocation does not increment version');
select throws_ok($$update public.hydrants set code=null where id='e2100000-0000-4000-8000-000000000031'$$,'23514',null,'assigned code cannot be cleared');
select throws_ok($$update public.hydrants set code='M21-A-H-000999' where id='e2100000-0000-4000-8000-000000000031'$$,'23514',null,'assigned code cannot be replaced');
update public.organizations set code='M21-RENAMED' where id='e2100000-0000-4000-8000-000000000011';
select is(private.assign_hydrant_code('e2100000-0000-4000-8000-000000000011','e2100000-0000-4000-8000-000000000032','e2100000-0000-4000-8000-000000000001'),'M21-A-H-000002','renamed organization retains reserved prefix for future codes');
select pg_temp.new_hydrant('{"id":"e2100000-0000-4000-8000-000000000033","organization_id":"e2100000-0000-4000-8000-000000000012"}');
select is(private.assign_hydrant_code('e2100000-0000-4000-8000-000000000012','e2100000-0000-4000-8000-000000000033','e2100000-0000-4000-8000-000000000001'),'M21-B-H-000001','second organization independent sequence');
update public.hydrants set active=false where id='e2100000-0000-4000-8000-000000000031';
delete from public.hydrants where id='e2100000-0000-4000-8000-000000000032';
select pg_temp.new_hydrant('{"id":"e2100000-0000-4000-8000-000000000034"}');
select is(private.assign_hydrant_code('e2100000-0000-4000-8000-000000000011','e2100000-0000-4000-8000-000000000034','e2100000-0000-4000-8000-000000000001'),'M21-A-H-000003','deactivation and trusted deletion never reuse numbers');
select throws_ok($$select pg_temp.new_hydrant('{"id":"e2100000-0000-4000-8000-000000000032"}')$$,'23514',null,'deleted assigned UUID remains reserved');
update public.organizations set code='M21-A' where id='e2100000-0000-4000-8000-000000000013';
select pg_temp.new_hydrant('{"id":"e2100000-0000-4000-8000-000000000035","organization_id":"e2100000-0000-4000-8000-000000000013"}');
select throws_ok($$select private.assign_hydrant_code('e2100000-0000-4000-8000-000000000013','e2100000-0000-4000-8000-000000000035','e2100000-0000-4000-8000-000000000001')$$,'23505',null,'another organization cannot allocate with reserved historical prefix');
update private.hydrant_code_counters set last_value=999998 where organization_id='e2100000-0000-4000-8000-000000000011';
select pg_temp.new_hydrant('{"id":"e2100000-0000-4000-8000-000000000036"}');
select is(private.assign_hydrant_code('e2100000-0000-4000-8000-000000000011','e2100000-0000-4000-8000-000000000036','e2100000-0000-4000-8000-000000000001'),'M21-A-H-999999','six-digit maximum preserved without truncation');
select pg_temp.new_hydrant('{"id":"e2100000-0000-4000-8000-000000000037"}');
select throws_ok($$select private.assign_hydrant_code('e2100000-0000-4000-8000-000000000011','e2100000-0000-4000-8000-000000000037','e2100000-0000-4000-8000-000000000001')$$,'22003',null,'exhaustion fails rather than reusing or truncating');
select ok((select code is null and version=1 from public.hydrants where id='e2100000-0000-4000-8000-000000000037'),'failed allocation atomic');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.hydrants'::regclass,'public.hydrant_types'::regclass)),'both tables have RLS');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename in ('hydrants','hydrant_types')),0,'no temporary broad policies');
select ok(not has_table_privilege('anon','public.hydrants','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'anon has no public.hydrants privileges');
select ok(not has_table_privilege('anon','public.hydrant_types','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'anon has no public.hydrant_types privileges');
select ok(not has_table_privilege('anon','private.hydrant_code_counters','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'anon has no private.hydrant_code_counters privileges');
select ok(not has_table_privilege('anon','private.hydrant_code_assignments','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'anon has no private.hydrant_code_assignments privileges');
select ok(not has_function_privilege('anon','private.assign_hydrant_code(uuid,uuid,uuid)','EXECUTE'),'anon cannot execute allocator');
set local role anon;
select throws_ok($$select * from public.hydrants$$,'42501',null,'anon direct hydrants read denied');
select throws_ok($$delete from public.hydrants$$,'42501',null,'anon direct hydrants delete denied');
select throws_ok($$select * from public.hydrant_types$$,'42501',null,'anon direct hydrant_types read denied');
select throws_ok($$delete from public.hydrant_types$$,'42501',null,'anon direct hydrant_types delete denied');
reset role;
select ok(not has_table_privilege('authenticated','public.hydrants','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'authenticated has no public.hydrants privileges');
select ok(not has_table_privilege('authenticated','public.hydrant_types','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'authenticated has no public.hydrant_types privileges');
select ok(not has_table_privilege('authenticated','private.hydrant_code_counters','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'authenticated has no private.hydrant_code_counters privileges');
select ok(not has_table_privilege('authenticated','private.hydrant_code_assignments','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'authenticated has no private.hydrant_code_assignments privileges');
select ok(not has_function_privilege('authenticated','private.assign_hydrant_code(uuid,uuid,uuid)','EXECUTE'),'authenticated cannot execute allocator');
set local role authenticated;
select throws_ok($$select * from public.hydrants$$,'42501',null,'authenticated direct hydrants read denied');
select throws_ok($$delete from public.hydrants$$,'42501',null,'authenticated direct hydrants delete denied');
select throws_ok($$select * from public.hydrant_types$$,'42501',null,'authenticated direct hydrant_types read denied');
select throws_ok($$delete from public.hydrant_types$$,'42501',null,'authenticated direct hydrant_types delete denied');
reset role;
select ok(not has_table_privilege('service_role','public.hydrants','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'service_role has no public.hydrants privileges');
select ok(not has_table_privilege('service_role','public.hydrant_types','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'service_role has no public.hydrant_types privileges');
select ok(not has_table_privilege('service_role','private.hydrant_code_counters','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'service_role has no private.hydrant_code_counters privileges');
select ok(not has_table_privilege('service_role','private.hydrant_code_assignments','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'),'service_role has no private.hydrant_code_assignments privileges');
select ok(not has_function_privilege('service_role','private.assign_hydrant_code(uuid,uuid,uuid)','EXECUTE'),'service_role cannot execute allocator');
-- Separate ACL from actual RLS row filtering using rolled-back grants only.
grant select,insert,update,delete on public.hydrants,public.hydrant_types to authenticated;
set local role authenticated;
select is((select count(*)::integer from public.hydrants),0,'RLS hides hydrants even with hypothetical SELECT grant');
select is((select count(*)::integer from public.hydrant_types),0,'RLS hides types even with hypothetical SELECT grant');
select throws_ok($$insert into public.hydrant_types(code,name) values('DENIED','Denied')$$,'42501',null,'RLS denies type insertion after hypothetical grant');
reset role;
update public.hydrant_types set created_at='2000-01-01',updated_at='2000-01-01' where id='30000000-0000-4000-8000-000000000001';
select ok((select created_at>'2000-01-02' and updated_at>'2000-01-02' from public.hydrant_types where id='30000000-0000-4000-8000-000000000001'),'type timestamps server-maintained');
select * from finish();
rollback;

