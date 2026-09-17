begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

-- These fixtures exist only inside this rolled-back test transaction.
insert into public.countries (id,code,name) values
 ('90000000-0000-4000-8000-000000000001','ZZ','Test country'),
 ('90000000-0000-4000-8000-000000000002','ZY','Other test country');
insert into public.administrative_areas (id,country_id,name,area_type) values
 ('91000000-0000-4000-8000-000000000001','90000000-0000-4000-8000-000000000001','Root','CUSTOM_LEVEL');
insert into public.administrative_areas (id,country_id,parent_id,name,area_type) values
 ('91000000-0000-4000-8000-000000000002','90000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000001','Child','DISTRICT');
insert into public.administrative_areas (id,country_id,parent_id,name,area_type) values
 ('91000000-0000-4000-8000-000000000003','90000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000002','Grandchild','LOCAL');
insert into public.organizations (id,administrative_area_id,name,code,type) values
 ('92000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000001','Test organization','TEST-ONE','OTHER');
insert into auth.users (id,email) values
 ('93000000-0000-4000-8000-000000000001','m11-fixture@example.invalid');
insert into public.profiles (id) values ('93000000-0000-4000-8000-000000000001');

select ok((select id is not null and active from public.countries where code='ZZ'), 'country active default');
select is((select inspection_interval_months from public.organizations where code='TEST-ONE'),12,'default interval');
select is((select account_status from public.profiles where id='93000000-0000-4000-8000-000000000001'),'PENDING_APPROVAL','profile defaults to pending');
select is((select start_screen from public.profiles where id='93000000-0000-4000-8000-000000000001'),'DASHBOARD','default start screen');
select is((select inspection_mode from public.profiles where id='93000000-0000-4000-8000-000000000001'),'GUIDED','default inspection mode');
select is((with recursive ancestry as (
 select id,parent_id from public.administrative_areas where id='91000000-0000-4000-8000-000000000003'
 union all select a.id,a.parent_id from public.administrative_areas a join ancestry p on a.id=p.parent_id
) select count(*)::integer from ancestry),3,'recursive arbitrary hierarchy');
select is((select count(*)::integer from public.countries where (code='SI' and id='10000000-0000-4000-8000-000000000001') or (code='AT' and id='10000000-0000-4000-8000-000000000002')),2,'deterministic SI and AT seed identities');
select is((with recursive tree as (
 select id,1 as depth from public.administrative_areas where id='20000000-0000-4000-8000-000000000011'
 union all select a.id,t.depth+1 from public.administrative_areas a join tree t on a.parent_id=t.id
) select max(depth) from tree),4,'Austrian seed has four representative levels');
select throws_ok($test$insert into public.countries(code,name) values ('ZZ','Duplicate')$test$, '23505', null, 'country codes are unique');
select throws_ok($test$insert into public.countries(code,name) values ('si','Invalid')$test$, '23514', null, 'reject invalid country code si');
select throws_ok($test$insert into public.countries(code,name) values ('S','Invalid')$test$, '23514', null, 'reject invalid country code S');
select throws_ok($test$insert into public.countries(code,name) values ('12','Invalid')$test$, '23514', null, 'reject invalid country code 12');
select throws_ok($test$insert into public.countries(code,name) values ('ZX','  ')$test$, '23514', null, 'reject blank country name');
select throws_ok($test$insert into public.administrative_areas(country_id,name,area_type) values ('99999999-0000-4000-8000-000000000099','Orphan','REGION')$test$, '23503', null, 'country FK');
select throws_ok($test$insert into public.administrative_areas(country_id,parent_id,name,area_type) values ('90000000-0000-4000-8000-000000000001','99999999-0000-4000-8000-000000000099','Orphan','REGION')$test$, '23503', null, 'parent FK');
select throws_ok($test$insert into public.administrative_areas(country_id,parent_id,name,area_type) values ('90000000-0000-4000-8000-000000000002','91000000-0000-4000-8000-000000000001','Cross country','REGION')$test$, '23503', null, 'parent must belong to same country');
select throws_ok($test$update public.administrative_areas set parent_id=id where id='91000000-0000-4000-8000-000000000001'$test$, '23514', null, 'self cycle rejected');
select throws_ok($test$update public.administrative_areas set parent_id='91000000-0000-4000-8000-000000000003' where id='91000000-0000-4000-8000-000000000001'$test$, '23514', null, 'indirect cycle rejected');
select throws_ok($test$delete from public.administrative_areas where id='91000000-0000-4000-8000-000000000002'$test$, '23503', null, 'referenced parent cannot be deleted');
select lives_ok($test$update public.administrative_areas set parent_id='91000000-0000-4000-8000-000000000001' where id='91000000-0000-4000-8000-000000000003'$test$, 'valid reparenting');
select throws_ok($test$insert into public.organizations(name,code,type) values ('Duplicate','TEST-ONE','OTHER')$test$, '23505', null, 'organization codes globally unique');
select lives_ok($test$update public.organizations set active=false where code='TEST-ONE'$test$, 'deactivate organization');
select throws_ok($test$insert into public.organizations(name,code,type) values ('Duplicate inactive','TEST-ONE','OTHER')$test$, '23505', null, 'inactive organization retains its code');
select throws_ok($test$update public.organizations set code='lowercase' where code='TEST-ONE'$test$, '23514', null, 'organization rejects code=''lowercase''');
select throws_ok($test$update public.organizations set code=' PADDED ' where code='TEST-ONE'$test$, '23514', null, 'organization rejects code='' PADDED ''');
select throws_ok($test$update public.organizations set code='' where code='TEST-ONE'$test$, '23514', null, 'organization rejects code=''''');
select throws_ok($test$update public.organizations set name=' ' where code='TEST-ONE'$test$, '23514', null, 'organization rejects name='' ''');
select throws_ok($test$update public.organizations set type='INVALID' where code='TEST-ONE'$test$, '23514', null, 'organization rejects type=''INVALID''');
select throws_ok($test$update public.organizations set inspection_interval_months=0 where code='TEST-ONE'$test$, '23514', null, 'organization rejects inspection_interval_months=0');
select throws_ok($test$update public.organizations set inspection_interval_months=-1 where code='TEST-ONE'$test$, '23514', null, 'organization rejects inspection_interval_months=-1');
select throws_ok($test$update public.organizations set default_language='en' where code='TEST-ONE'$test$, '23514', null, 'organization rejects default_language=''en''');
select throws_ok($test$update public.organizations set inspection_interval_months=null where code='TEST-ONE'$test$, '23502', null, 'interval cannot be null');
select throws_ok($test$update public.organizations set administrative_area_id='99999999-0000-4000-8000-000000000099' where code='TEST-ONE'$test$, '23503', null, 'organization area FK');
select lives_ok($test$update public.organizations set type='MUNICIPALITY' where code='TEST-ONE'$test$, 'supported organization type MUNICIPALITY');
select lives_ok($test$update public.organizations set type='FIRE_DEPARTMENT' where code='TEST-ONE'$test$, 'supported organization type FIRE_DEPARTMENT');
select lives_ok($test$update public.organizations set type='WATER_UTILITY' where code='TEST-ONE'$test$, 'supported organization type WATER_UTILITY');
select lives_ok($test$update public.organizations set type='OTHER' where code='TEST-ONE'$test$, 'supported organization type OTHER');
select lives_ok($test$update public.organizations set default_language='sl' where code='TEST-ONE'$test$, 'organization language ''sl''');
select lives_ok($test$update public.organizations set default_language='de' where code='TEST-ONE'$test$, 'organization language ''de''');
select lives_ok($test$update public.organizations set default_language=null where code='TEST-ONE'$test$, 'organization language null');
select throws_ok($test$insert into public.profiles(id) values ('99999999-0000-4000-8000-000000000099')$test$, '23503', null, 'profile requires auth identity');
select throws_ok($test$insert into public.profiles(id) values ('93000000-0000-4000-8000-000000000001')$test$, '23505', null, 'one profile per auth identity');
select throws_ok($test$delete from auth.users where id='93000000-0000-4000-8000-000000000001'$test$, '23503', null, 'identity deletion cannot orphan or silently erase profile');
select throws_ok($test$update public.profiles set account_status='INVALID' where id='93000000-0000-4000-8000-000000000001'$test$, '23514', null, 'profile rejects invalid account_status');
select throws_ok($test$update public.profiles set preferred_language='INVALID' where id='93000000-0000-4000-8000-000000000001'$test$, '23514', null, 'profile rejects invalid preferred_language');
select throws_ok($test$update public.profiles set start_screen='INVALID' where id='93000000-0000-4000-8000-000000000001'$test$, '23514', null, 'profile rejects invalid start_screen');
select throws_ok($test$update public.profiles set inspection_mode='INVALID' where id='93000000-0000-4000-8000-000000000001'$test$, '23514', null, 'profile rejects invalid inspection_mode');
select throws_ok($test$update public.profiles set account_status=null where id='93000000-0000-4000-8000-000000000001'$test$, '23502', null, 'profile requires account_status');
select throws_ok($test$update public.profiles set start_screen=null where id='93000000-0000-4000-8000-000000000001'$test$, '23502', null, 'profile requires start_screen');
select throws_ok($test$update public.profiles set inspection_mode=null where id='93000000-0000-4000-8000-000000000001'$test$, '23502', null, 'profile requires inspection_mode');
select lives_ok($test$update public.profiles set account_status='PENDING_APPROVAL' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports account_status=PENDING_APPROVAL');
select lives_ok($test$update public.profiles set account_status='ACTIVE' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports account_status=ACTIVE');
select lives_ok($test$update public.profiles set account_status='SUSPENDED' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports account_status=SUSPENDED');
select lives_ok($test$update public.profiles set account_status='REJECTED' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports account_status=REJECTED');
select lives_ok($test$update public.profiles set preferred_language='sl' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports preferred_language=sl');
select lives_ok($test$update public.profiles set preferred_language='de' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports preferred_language=de');
select lives_ok($test$update public.profiles set start_screen='DASHBOARD' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports start_screen=DASHBOARD');
select lives_ok($test$update public.profiles set start_screen='MAP' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports start_screen=MAP');
select lives_ok($test$update public.profiles set start_screen='INSPECTIONS' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports start_screen=INSPECTIONS');
select lives_ok($test$update public.profiles set inspection_mode='QUICK' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports inspection_mode=QUICK');
select lives_ok($test$update public.profiles set inspection_mode='GUIDED' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports inspection_mode=GUIDED');
select lives_ok($test$update public.profiles set inspection_mode='CLASSIC' where id='93000000-0000-4000-8000-000000000001'$test$, 'profile supports inspection_mode=CLASSIC');
select lives_ok($test$update public.profiles set preferred_language=null where id='93000000-0000-4000-8000-000000000001'$test$, 'profile language may be unset');

-- Server UUID defaults, actual constraints, and untrusted timestamp inputs.
with inserted as (insert into public.countries(code,name) values ('ZX','Generated UUID') returning id)
select ok((select id is not null from inserted),'country UUID generated on server');
with inserted as (insert into public.administrative_areas(country_id,name,area_type) values ('90000000-0000-4000-8000-000000000001','Generated UUID','ANY_LEVEL') returning id)
select ok((select id is not null from inserted),'area UUID generated on server');
with inserted as (insert into public.organizations(name,code,type,created_at,updated_at) values ('Generated UUID','GENERATED','OTHER','2000-01-01','2100-01-01') returning *)
select ok((select id is not null and created_at=statement_timestamp() and updated_at=statement_timestamp() from inserted),'organization UUID and server insertion timestamps');
insert into auth.users(id) values ('93000000-0000-4000-8000-000000000002');
with inserted as (insert into public.profiles(id,created_at,updated_at) values ('93000000-0000-4000-8000-000000000002','2000-01-01','2100-01-01') returning *)
select ok((select created_at=statement_timestamp() and updated_at=statement_timestamp() from inserted),'profile server insertion timestamps');
create temporary table original_timestamps as select 'organization' as kind,created_at,updated_at from public.organizations where code='TEST-ONE'
union all select 'profile',created_at,updated_at from public.profiles where id='93000000-0000-4000-8000-000000000001';
with changed as (update public.organizations set created_at='2100-01-01',updated_at='2000-01-01' where code='TEST-ONE' returning *)
select ok((select c.created_at=o.created_at and c.updated_at=statement_timestamp() and c.updated_at>=o.updated_at from changed c cross join original_timestamps o where o.kind='organization'),'organization preserves created_at and overrides spoofed updated_at');
with changed as (update public.profiles set created_at='2100-01-01',updated_at='2000-01-01' where id='93000000-0000-4000-8000-000000000001' returning *)
select ok((select c.created_at=o.created_at and c.updated_at=statement_timestamp() and c.updated_at>=o.updated_at from changed c cross join original_timestamps o where o.kind='profile'),'profile preserves created_at and overrides spoofed updated_at');
select * from finish();
rollback;
