begin;
create extension if not exists pgtap with schema extensions;
select plan(2);
select ok(not has_schema_privilege('anon', 'public', 'CREATE'), 'anonymous API role cannot create objects');
select ok(not has_schema_privilege('authenticated', 'public', 'CREATE'), 'authenticated API role cannot create objects');
select * from finish();
rollback;
