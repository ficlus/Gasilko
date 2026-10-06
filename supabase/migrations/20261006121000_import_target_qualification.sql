-- M9 forward repair only: qualify duplicate-target columns; preserve function signature/grants/behavior.
create or replace function public.web_import_confirm(root uuid, operation uuid, manifest jsonb) returns uuid
language plpgsql volatile security definer set search_path='' as $$
declare saved private.web_imports; input jsonb; p jsonb; n integer; target uuid; org uuid; selected boolean;
begin
 if not private.web_read(root) then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 if operation is null or jsonb_typeof(manifest->'rows') is distinct from 'array' or jsonb_array_length(manifest->'rows') not between 1 and 10000
 or octet_length(manifest::text)>16777216 or length(btrim(coalesce(manifest->>'reason',''))) not between 1 and 500
 or length(coalesce(manifest->>'filename','')) not between 1 and 180 or manifest->>'filename' ~ '[/\\[:cntrl:]]'
 or coalesce(manifest->>'format','') not in ('csv','xls','xlsx') or coalesce(manifest->>'file_hash','') !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_IMPORT'; end if;
 perform pg_advisory_xact_lock(hashtextextended(operation::text,9001));
 select * into saved from private.web_imports where id=operation;
 if found then
  if saved.actor<>auth.uid() or saved.root<>root or saved.manifest is distinct from manifest then raise exception 'OPERATION_REUSED'; end if;
  return operation;
 end if;
 -- Check duplicates over the complete file, not just the selected/apply batch.
 if exists(select 1 from jsonb_array_elements(manifest->'rows') r group by r->>'row' having count(*)>1) then raise exception 'INVALID_IMPORT'; end if;
 insert into private.web_imports(id,actor,root,manifest,payload_hash) values(operation,auth.uid(),root,manifest,encode(sha256(convert_to(manifest::text,'UTF8')),'hex'));
 for input in select value from jsonb_array_elements(manifest->'rows') loop
  n:=(input->>'row')::integer; if n not between 2 and 10001 then raise exception 'INVALID_IMPORT'; end if;
  p:=private.web_import_preview_row(root,input); org:=(p->>'organization_id')::uuid; target:=(p->>'id')::uuid;
  selected:=coalesce((input->>'selected')::boolean,false);
  if selected and p->>'action' in ('CREATE','UPDATE') then
   perform private.authorize_hydrant_write(org,array['MANAGER','ADMIN']);
   if jsonb_array_length(p->'warnings')>0 and not coalesce((input->>'accept_warnings')::boolean,false) then raise exception 'WARNINGS_REQUIRE_CONFIRMATION'; end if;
   if p->>'action'='UPDATE' and not input ? 'expected_version' then raise exception 'EXPECTED_VERSION_REQUIRED'; end if;
   target:=coalesce(target,gen_random_uuid());
  end if;
  insert into private.web_import_rows(import_id,row_number,organization_id,target,frozen,result)
   values(operation,n,org,target,p,case when selected and p->>'action' in ('CREATE','UPDATE') then null
    else p||jsonb_build_object('action',case when p->>'action' in ('ERROR','CONFLICT','UNCHANGED') then p->>'action' else 'SKIP' end) end);
 end loop;
 -- Mark every member of a duplicate group, including rows excluded in the browser.
 update private.web_import_rows r set result=jsonb_build_object('row',r.row_number,'action','ERROR','error','DUPLICATE_IDENTITY')
 where r.import_id=operation and (r.target in(select wir.target from private.web_import_rows wir where wir.import_id=operation and wir.target is not null group by wir.target having count(*)>1)
 or r.row_number in(with source as materialized(select value v from jsonb_array_elements(manifest->'rows')),
  du as(select lower(v->>'uuid') identity from source where nullif(v->>'uuid','') is not null group by lower(v->>'uuid') having count(*)>1),
  dc as(select v->>'organization' org,v->>'code' code from source where nullif(v->>'code','') is not null group by v->>'organization',v->>'code' having count(*)>1)
  select (s.v->>'row')::integer from source s left join du on du.identity=lower(s.v->>'uuid') left join dc on dc.org=s.v->>'organization' and dc.code=s.v->>'code'
  where du.identity is not null or dc.code is not null));
 perform private.write_audit(root,auth.uid(),'IMPORT_CONFIRMED','web_imports',operation,null,jsonb_build_object('rows',jsonb_array_length(manifest->'rows'),'hash',encode(sha256(convert_to(manifest::text,'UTF8')),'hex')));
 return operation;
end; $$;
