-- M14.7D. Private evidence is not task execution or a public timeline entry.
create table public.incident_attachments(
 id uuid primary key,incident_id uuid not null references public.incidents(id) on delete restrict,
 target_kind text not null check(target_kind in ('INCIDENT','TASK','MESSAGE')),
 target_task_id uuid,target_message_id uuid,
 creator_user_id uuid not null references public.profiles(id) on delete restrict,
 acting_organization_id uuid not null references public.organizations(id) on delete restrict,
 operation_id uuid not null unique,
 storage_bucket text not null default 'incident-evidence' check(storage_bucket='incident-evidence'),
 storage_object_key text not null unique,
 filename text not null check(length(filename) between 1 and 120),
 mime text not null check(mime in ('image/jpeg','image/webp','application/pdf')),
 declared_size bigint not null check(declared_size>0 and declared_size<=20971520),
 declared_sha256 text not null check(declared_sha256 ~ '^[0-9a-f]{64}$'),
 validated_size bigint,sha256 text check(sha256 ~ '^[0-9a-f]{64}$'),
 status text not null default 'STAGED' check(status in ('STAGED','READY','REJECTED')),
 created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null default clock_timestamp()+interval '30 minutes',
 verified_at timestamptz,changed_revision bigint,verification_error text,
 foreign key(target_task_id,incident_id) references public.incident_tasks(id,incident_id) on delete restrict,
 foreign key(target_message_id,incident_id) references public.incident_messages(id,incident_id) on delete restrict,
 check((target_kind='INCIDENT' and target_task_id is null and target_message_id is null)
 or (target_kind='TASK' and target_task_id is not null and target_message_id is null)
 or (target_kind='MESSAGE' and target_task_id is null and target_message_id is not null)),
 check(mime='application/pdf' or declared_size<=10485760),
 check(storage_object_key=incident_id::text||'/'||id::text||'/original.'||case mime when 'image/jpeg' then 'jpg' when 'image/webp' then 'webp' else 'pdf' end),
 check((status='READY' and validated_size=declared_size and sha256 is not null and verified_at is not null and changed_revision is not null)
 or (status in ('STAGED','REJECTED') and validated_size is null and sha256 is null and verified_at is null and changed_revision is null))
);
create index incident_attachment_page on public.incident_attachments(incident_id,target_kind,coalesce(target_task_id,target_message_id),created_at desc,id desc);
create index incident_attachment_pending on public.incident_attachments(creator_user_id,acting_organization_id,status);
alter table public.incident_attachments enable row level security;
revoke all on public.incident_attachments from public,anon,authenticated,service_role;
create trigger evidence_no_delete before delete on public.incident_attachments for each row execute function private.audit_immutable();
create trigger evidence_no_truncate before truncate on public.incident_attachments for each statement execute function private.audit_immutable();

-- Explicit actor helper: also used by the trusted validator after auth/v1/user.
-- TASK predicates mirror field_assignment_visible + current task command lineage.
create function private.evidence_authority(p_actor uuid,p_org uuid,p_incident uuid,p_kind text,p_target uuid,p_write boolean)
returns boolean language sql volatile security definer set search_path='' as $evidence_authority$
 select private.message_authority(p_actor,p_org,p_incident,'INCIDENT',null,null,false) and (
 (p_kind='INCIDENT' and p_target is null and
 private.message_authority(p_actor,p_org,p_incident,'INCIDENT',null,null,p_write))
 or (p_kind='MESSAGE' and exists(select 1 from public.incident_messages m where m.id=p_target and m.incident_id=p_incident
 and private.message_authority(p_actor,p_org,p_incident,m.audience_kind,m.audience_org_id,m.audience_unit_assignment_id,false)
 and (not p_write or (m.sender_user_id=p_actor and m.sender_acting_org_id=p_org
 and not exists(select 1 from public.incident_messages child where child.supersedes_id=m.id)
 and private.message_authority(p_actor,p_org,p_incident,m.audience_kind,m.audience_org_id,m.audience_unit_assignment_id,true)))))
 or (p_kind='TASK' and exists(select 1 from public.incident_tasks t
 join public.incident_task_assignments a on a.task_id=t.id and a.incident_id=t.incident_id
 left join public.incident_crew_members c on c.id=a.incident_crew_member_id
 join public.incident_units u on u.id=coalesce(a.incident_unit_id,c.unit_assignment_id) and u.incident_id=t.incident_id
 join public.incident_participants ip on ip.id=u.participation_id and ip.status='ACTIVE'
 join public.organizations uo on uo.id=u.organization_id and uo.active
 where t.id=p_target and t.incident_id=p_incident and u.status not in ('RELEASED','UNAVAILABLE')
 and a.status<>'CANCELLED' and t.status<>'CANCELLED'
 and (not p_write or (t.status='OPEN' and a.status not in ('COMPLETED','UNABLE','CANCELLED')))
 and (
 (not p_write and private.field_assignment_visible(p_actor,p_org,a.id))
 or (p_write and a.recipient_type='INCIDENT_CREW_MEMBER' and c.user_id=p_actor and c.membership_organization_id=p_org and c.status='ACTIVE')
 or exists(select 1 from public.incident_role_assignments r where r.incident_id=p_incident
 and r.organization_id=p_org and r.user_id=p_actor and private.incident_assignment_effective(r.id)
 and (r.role='INCIDENT_COMMANDER'
 or (r.role='AGENCY_COMMANDER' and u.organization_id=p_org)
 or (r.role='SECTOR_COMMANDER' and r.sector_id=u.sector_id)
 or (r.role='UNIT_LEADER' and r.unit_assignment_id=u.id
 and (not p_write or a.recipient_type='INCIDENT_UNIT' or (c.status='ACTIVE' and c.membership_organization_id=p_org))))))))
 );
$evidence_authority$;

create function private.evidence_lock(p_actor uuid,p_org uuid,p_incident uuid) returns void
language plpgsql volatile security definer set search_path='' as $evidence_lock$
declare v_org uuid;
begin
 for v_org in select distinct q.org from(select p_org org union all
 select ip.organization_id from public.incident_participants ip where ip.incident_id=p_incident) q order by q.org loop
  perform private.lock_organization(v_org);
  perform 1 from public.organizations o where o.id=v_org for share;
 end loop;
 perform 1 from public.profiles pr where pr.id=p_actor for share;
 perform 1 from public.incidents i where i.id=p_incident for update;
end;
$evidence_lock$;
create function private.evidence_dto(p_row public.incident_attachments) returns jsonb
language sql stable security definer set search_path='' as $evidence_dto$
 select jsonb_build_object('id',p_row.id,'incident_id',p_row.incident_id,'target_kind',p_row.target_kind,
 'target_id',coalesce(p_row.target_task_id,p_row.target_message_id),'creator_user_id',p_row.creator_user_id,
 'acting_organization_id',p_row.acting_organization_id,'operation_id',p_row.operation_id,
 'filename',p_row.filename,'mime',p_row.mime,'size',p_row.declared_size::text,
 'status',p_row.status,'created_at',p_row.created_at,'verified_at',p_row.verified_at,
 'sha256',p_row.sha256,'revision',p_row.changed_revision::text,'error',p_row.verification_error);
$evidence_dto$;

create function public.incident_attachment_prepare(p_operation uuid,p_acting_organization_id uuid,p_incident_id uuid,
 p_attachment_id uuid,p_target_kind text,p_target_id uuid,p_metadata jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $evidence_prepare$
declare v_actor uuid:=auth.uid();v_row public.incident_attachments;v_receipt private.incident_operation_receipts;
 v_request jsonb;v_result jsonb;v_name text;v_mime text;v_size bigint;v_path text;
begin
 if v_actor is null or p_operation is null or p_attachment_id is null or p_incident_id is null or p_acting_organization_id is null
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if jsonb_typeof(p_metadata) is distinct from 'object' or octet_length(p_metadata::text)>2048
 or exists(select 1 from jsonb_object_keys(p_metadata) k where k not in ('filename','mime','size','sha256'))
 or jsonb_typeof(p_metadata->'filename') is distinct from 'string' then raise exception 'VALIDATION_FAILED';end if;
 v_name:=left(btrim(regexp_replace(translate(p_metadata->>'filename',chr(92)||'/'||chr(1564)||chr(8206)||chr(8207)||chr(65279)||chr(8291)||chr(8234)||chr(8235)||chr(8236)||chr(8237)||chr(8238)||chr(8294)||chr(8295)||chr(8296)||chr(8297),''),'[[:cntrl:]]','','g')),120);
 if v_name='' then v_name:='evidence';end if;
 v_mime:=p_metadata->>'mime';v_size:=(p_metadata->>'size')::bigint;
 if p_metadata->>'sha256' is null or p_metadata->>'sha256' !~ '^[0-9a-f]{64}$' then raise exception 'VALIDATION_FAILED';end if;
 if v_mime not in ('image/jpeg','image/webp','application/pdf') or v_mime is null then raise exception 'ATTACHMENT_TYPE_UNSUPPORTED';end if;
 if v_size is null or v_size<1 or v_size>case when v_mime='application/pdf' then 20971520 else 10485760 end then raise exception 'ATTACHMENT_TOO_LARGE';end if;
 v_path:=p_incident_id::text||'/'||p_attachment_id::text||'/original.'||case v_mime when 'image/jpeg' then 'jpg' when 'image/webp' then 'webp' else 'pdf' end;
 v_request:=jsonb_build_object('command','ATTACHMENT_PREPARE','org',p_acting_organization_id,'incident',p_incident_id,
 'id',p_attachment_id,'kind',p_target_kind,'target',p_target_id,'filename',v_name,'mime',v_mime,'size',v_size::text,'sha256',p_metadata->>'sha256');
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 perform private.evidence_lock(v_actor,p_acting_organization_id,p_incident_id);
 select * into v_row from public.incident_attachments a where a.id=p_attachment_id;
 if private.evidence_authority(v_actor,p_acting_organization_id,p_incident_id,p_target_kind,p_target_id,
 not coalesce(v_row.status='READY' and v_row.creator_user_id=v_actor and v_row.acting_organization_id=p_acting_organization_id,false)) is not true
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select * into v_receipt from private.incident_operation_receipts r where r.operation_id=p_operation;
 if found then
  if v_receipt.actor_user_id<>v_actor or v_receipt.request is distinct from v_request then raise exception 'OPERATION_REUSED';end if;
  update public.incident_attachments a set expires_at=clock_timestamp()+interval '30 minutes' where a.id=p_attachment_id and a.status='STAGED';
  select * into v_row from public.incident_attachments a where a.id=p_attachment_id;
  return private.evidence_dto(v_row)||jsonb_build_object('bucket','incident-evidence','path',v_row.storage_object_key);
 end if;
 if (select count(*) from public.incident_attachments a where a.creator_user_id=v_actor and a.acting_organization_id=p_acting_organization_id and a.status='STAGED')>=32
 or coalesce((select sum(a.declared_size) from public.incident_attachments a where a.creator_user_id=v_actor and a.acting_organization_id=p_acting_organization_id and a.status='STAGED'),0)+v_size>134217728
 then raise exception 'ATTACHMENT_LIMIT';end if;
 insert into public.incident_attachments(id,incident_id,target_kind,target_task_id,target_message_id,creator_user_id,acting_organization_id,
 operation_id,storage_object_key,filename,mime,declared_size,declared_sha256)
 values(p_attachment_id,p_incident_id,p_target_kind,case when p_target_kind='TASK' then p_target_id end,
 case when p_target_kind='MESSAGE' then p_target_id end,v_actor,p_acting_organization_id,p_operation,v_path,v_name,v_mime,v_size,p_metadata->>'sha256')
 returning * into v_row;
 v_result:=private.evidence_dto(v_row)||jsonb_build_object('bucket','incident-evidence','path',v_path);
 perform private.write_audit(p_acting_organization_id,v_actor,'EVIDENCE_STAGED','incident_attachments',p_attachment_id,null,
 jsonb_build_object('incident_id',p_incident_id,'operation_id',p_operation));
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,v_actor,p_acting_organization_id,p_incident_id,'ATTACHMENT_PREPARE',v_request,v_result);
 return v_result;
exception when unique_violation then raise exception 'OPERATION_REUSED';
 when invalid_text_representation or numeric_value_out_of_range or check_violation or not_null_violation or foreign_key_violation then raise exception 'VALIDATION_FAILED';
end;
$evidence_prepare$;

-- Private metadata is never a generic folder listing. Every page rechecks exact target.
create function public.incident_attachment_page(p_acting_organization_id uuid,p_incident_id uuid,p_target_kind text,
 p_target_id uuid default null,p_before_created_at timestamptz default null,p_before_id uuid default null,p_limit integer default 30)
returns jsonb language plpgsql volatile security definer set search_path='' as $evidence_page$
declare v_rows jsonb;v_n integer;v_last jsonb;v_audience jsonb;
begin
 if p_limit is null or p_limit not between 1 and 50 or (p_before_created_at is null)<>(p_before_id is null) then raise exception 'VALIDATION_FAILED';end if;
 if private.evidence_authority(auth.uid(),p_acting_organization_id,p_incident_id,p_target_kind,p_target_id,false) is not true
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 select coalesce(jsonb_agg(q.dto order by q.created_at desc,q.id desc),'[]'),count(*) into v_rows,v_n from(
 select a.id,a.created_at,private.evidence_dto(a) dto from public.incident_attachments a
 where a.incident_id=p_incident_id and a.target_kind=p_target_kind and coalesce(a.target_task_id,a.target_message_id) is not distinct from p_target_id
 and (a.status='READY' or (a.creator_user_id=auth.uid() and a.acting_organization_id=p_acting_organization_id))
 and (p_before_created_at is null or (a.created_at,a.id)<(p_before_created_at,p_before_id))
 order by a.created_at desc,a.id desc limit p_limit+1) q;
 v_last:=v_rows->(least(v_n,p_limit)-1);
 v_audience:=jsonb_build_object('kind',p_target_kind,'id',coalesce(p_target_id,p_incident_id));
 if p_target_kind='MESSAGE' then
  select jsonb_build_object('kind',m.audience_kind,'id',coalesce(m.audience_org_id,m.audience_unit_assignment_id,m.incident_id))
  into v_audience from public.incident_messages m where m.id=p_target_id and m.incident_id=p_incident_id;
 end if;
 return jsonb_build_object('account',auth.uid(),'organization',p_acting_organization_id,'incident_id',p_incident_id,
 'audience',v_audience,'scope_fingerprint',private.message_scope(p_acting_organization_id,p_incident_id),'items',case when v_n>p_limit then v_rows-p_limit else v_rows end,
 'can_add',private.evidence_authority(auth.uid(),p_acting_organization_id,p_incident_id,p_target_kind,p_target_id,true),
 'has_more',v_n>p_limit,'next_created_at',v_last->>'created_at','next_id',v_last->>'id');
end;
$evidence_page$;

-- Bounded per-account/org transfer admission, not an event/operation queue.
create table private.incident_evidence_transfer_limits(
 actor uuid not null references public.profiles(id),organization uuid not null references public.organizations(id),
 window_start timestamptz not null,requests integer not null check(requests between 1 and 60),primary key(actor,organization)
);
revoke all on private.incident_evidence_transfer_limits from public,anon,authenticated,service_role;
create function private.evidence_transfer_limit(p_actor uuid,p_org uuid) returns void
language plpgsql volatile security definer set search_path='' as $evidence_limit$
begin
 insert into private.incident_evidence_transfer_limits as lim(actor,organization,window_start,requests)
 values(p_actor,p_org,clock_timestamp(),1)
 on conflict(actor,organization) do update set
 window_start=case when lim.window_start<clock_timestamp()-interval '5 minutes' then clock_timestamp() else lim.window_start end,
 requests=case when lim.window_start<clock_timestamp()-interval '5 minutes' then 1 else lim.requests+1 end
 where lim.window_start<clock_timestamp()-interval '5 minutes' or lim.requests<60;
 if not found then raise exception 'ATTACHMENT_LIMIT';end if;
end;
$evidence_limit$;
alter function private.evidence_transfer_limit(uuid,uuid) owner to postgres;
revoke all on function private.evidence_transfer_limit(uuid,uuid) from public,anon,authenticated,service_role;

-- Mode distinguishes uploader verification from recipient download; caller cannot
-- obtain quarantine bytes. Paths go only to the authenticated upload/trusted handler.
create function public.incident_attachment_access(p_acting_organization_id uuid,p_incident_id uuid,p_attachment_id uuid,p_upload boolean default false)
returns jsonb language plpgsql volatile security definer set search_path='' as $evidence_access$
declare v_row public.incident_attachments;
begin
 if p_upload is null then raise exception 'VALIDATION_FAILED';end if;
 select * into v_row from public.incident_attachments a where a.id=p_attachment_id and a.incident_id=p_incident_id;
 if not found or private.evidence_authority(auth.uid(),p_acting_organization_id,p_incident_id,v_row.target_kind,
 coalesce(v_row.target_task_id,v_row.target_message_id),p_upload) is not true
 or (p_upload and (v_row.creator_user_id<>auth.uid() or v_row.acting_organization_id<>p_acting_organization_id))
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 if not p_upload and v_row.status<>'READY' then raise exception 'ATTACHMENT_NOT_READY';end if;
 perform private.evidence_transfer_limit(auth.uid(),p_acting_organization_id);
 return private.evidence_dto(v_row)||jsonb_build_object('bucket','incident-evidence','path',v_row.storage_object_key)||
 case when p_upload then jsonb_build_object('declared_sha256',v_row.declared_sha256,'object_exists',exists(select 1 from storage.objects o where o.bucket_id=v_row.storage_bucket and o.name=v_row.storage_object_key)) else '{}'::jsonb end;
end;
$evidence_access$;

-- ONLY service_role may invoke this after trusted byte inspection. No client hash
-- or MIME ever reaches this function through an authenticated grant.
create function public.incident_attachment_commit(p_actor uuid,p_org uuid,p_incident uuid,p_attachment uuid,p_operation uuid,
 p_mime text,p_size bigint,p_sha256 text,p_error text default null) returns jsonb
language plpgsql volatile security definer set search_path='' as $evidence_commit$
declare v_row public.incident_attachments;v_receipt private.incident_operation_receipts;v_request jsonb;v_result jsonb;v_rev bigint;
begin
 if p_operation is null then raise exception 'VALIDATION_FAILED';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_operation::text,141));
 perform private.evidence_lock(p_actor,p_org,p_incident);
 select * into v_row from public.incident_attachments a where a.id=p_attachment and a.incident_id=p_incident for update;
 if not found or v_row.creator_user_id<>p_actor or v_row.acting_organization_id<>p_org
 or private.evidence_authority(p_actor,p_org,p_incident,v_row.target_kind,coalesce(v_row.target_task_id,v_row.target_message_id),true) is not true
 then raise exception 'NOT_AUTHORIZED' using errcode='42501';end if;
 v_request:=jsonb_build_object('command','ATTACHMENT_FINALIZE','id',p_attachment,'incident',p_incident,'org',p_org,
 'mime',p_mime,'size',p_size::text,'sha256',p_sha256,'error',p_error);
 select * into v_receipt from private.incident_operation_receipts r where r.operation_id=p_operation;
 if found then
  if v_receipt.actor_user_id<>p_actor or v_receipt.request is distinct from v_request then raise exception 'OPERATION_REUSED';end if;
  return v_receipt.result;
 end if;
 if v_row.status<>'STAGED' then
  if v_row.status='READY' and v_row.mime=p_mime and v_row.validated_size=p_size and v_row.sha256=p_sha256 and p_error is null
  then return private.evidence_dto(v_row);end if;
  raise exception 'ATTACHMENT_REJECTED';
 end if;
 if p_error is not null then
  if p_error not in ('ATTACHMENT_MALFORMED','ATTACHMENT_TOO_LARGE','ATTACHMENT_TYPE_UNSUPPORTED') then raise exception 'VALIDATION_FAILED';end if;
  update public.incident_attachments a set status='REJECTED',verification_error=p_error where a.id=p_attachment returning * into v_row;
 else
  if p_mime is distinct from v_row.mime or p_size is distinct from v_row.declared_size or p_sha256 is distinct from v_row.declared_sha256 or p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$'
  or not exists(select 1 from storage.objects o where o.bucket_id=v_row.storage_bucket and o.name=v_row.storage_object_key)
  then raise exception 'ATTACHMENT_MALFORMED';end if;
  update public.incidents i set revision=i.revision+1,updated_at=clock_timestamp() where i.id=p_incident returning i.revision into v_rev;
  update public.incident_attachments a set status='READY',validated_size=p_size,sha256=p_sha256,
   verified_at=clock_timestamp(),changed_revision=v_rev where a.id=p_attachment returning * into v_row;
 end if;
 v_result:=private.evidence_dto(v_row);
 perform private.write_audit(p_org,p_actor,'EVIDENCE_'||v_row.status,'incident_attachments',p_attachment,null,
 jsonb_build_object('incident_id',p_incident,'operation_id',p_operation,'code',v_row.status));
 insert into private.incident_operation_receipts(operation_id,actor_user_id,acting_organization_id,incident_id,command_code,request,result)
 values(p_operation,p_actor,p_org,p_incident,'ATTACHMENT_FINALIZE',v_request,v_result);
 return v_result;
end;
$evidence_commit$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('incident-evidence','incident-evidence',false,20971520,array['image/jpeg','image/webp','application/pdf']);
create function private.evidence_insert(p_path text) returns boolean language sql volatile security definer set search_path='' as $evidence_insert$
 select exists(select 1 from public.incident_attachments a where a.storage_object_key=p_path
 and a.creator_user_id=auth.uid() and a.status='STAGED' and a.expires_at>clock_timestamp()
 and private.evidence_authority(auth.uid(),a.acting_organization_id,a.incident_id,a.target_kind,coalesce(a.target_task_id,a.target_message_id),true));
$evidence_insert$;
create policy evidence_insert on storage.objects for insert to authenticated
 with check(bucket_id='incident-evidence' and private.evidence_insert(name));
-- Restrictive guards prevent a permissive unrelated policy widening this namespace.
create policy evidence_insert_guard on storage.objects as restrictive for insert to authenticated
 with check(bucket_id<>'incident-evidence' or private.evidence_insert(name));
create policy evidence_select_guard on storage.objects as restrictive for select to anon,authenticated using(bucket_id<>'incident-evidence');
create policy evidence_update_guard on storage.objects as restrictive for update to anon,authenticated
 using(bucket_id<>'incident-evidence') with check(bucket_id<>'incident-evidence');
create policy evidence_delete_guard on storage.objects as restrictive for delete to anon,authenticated using(bucket_id<>'incident-evidence');
create policy evidence_anon_insert_guard on storage.objects as restrictive for insert to anon with check(bucket_id<>'incident-evidence');

-- Explicit function grants, including private helpers: no implicit PUBLIC execute.
alter function private.evidence_authority(uuid,uuid,uuid,text,uuid,boolean) owner to postgres;
alter function private.evidence_lock(uuid,uuid,uuid) owner to postgres;
alter function private.evidence_dto(public.incident_attachments) owner to postgres;
alter function private.evidence_insert(text) owner to postgres;
revoke all on function private.evidence_authority(uuid,uuid,uuid,text,uuid,boolean),private.evidence_lock(uuid,uuid,uuid),
 private.evidence_dto(public.incident_attachments),private.evidence_insert(text) from public,anon,authenticated,service_role;
grant execute on function private.evidence_insert(text) to authenticated;
alter function public.incident_attachment_prepare(uuid,uuid,uuid,uuid,text,uuid,jsonb) owner to postgres;
alter function public.incident_attachment_page(uuid,uuid,text,uuid,timestamptz,uuid,integer) owner to postgres;
alter function public.incident_attachment_access(uuid,uuid,uuid,boolean) owner to postgres;
alter function public.incident_attachment_commit(uuid,uuid,uuid,uuid,uuid,text,bigint,text,text) owner to postgres;
revoke all on function public.incident_attachment_prepare(uuid,uuid,uuid,uuid,text,uuid,jsonb),
 public.incident_attachment_page(uuid,uuid,text,uuid,timestamptz,uuid,integer),public.incident_attachment_access(uuid,uuid,uuid,boolean),
 public.incident_attachment_commit(uuid,uuid,uuid,uuid,uuid,text,bigint,text,text) from public,anon,authenticated,service_role;
grant execute on function public.incident_attachment_prepare(uuid,uuid,uuid,uuid,text,uuid,jsonb),
 public.incident_attachment_page(uuid,uuid,text,uuid,timestamptz,uuid,integer),public.incident_attachment_access(uuid,uuid,uuid,boolean) to authenticated;
grant execute on function public.incident_attachment_commit(uuid,uuid,uuid,uuid,uuid,text,bigint,text,text) to service_role;
