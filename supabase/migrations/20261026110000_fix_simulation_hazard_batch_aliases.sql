-- P0: disambiguate PL/pgSQL records and SQL aliases in the M14.6D batch.
-- Forward-only replacement; CREATE OR REPLACE retains the existing owner/grants.
-- No runner, scheduling, hazard algorithm or operational-effect changes.
begin;

create or replace function public.simulation_hazard_batch() returns jsonb
language plpgsql security definer set search_path='' set lock_timeout='100ms' as $batch$
declare
 v_candidate record;
 v_model private.simulation_hazard_models;
 v_scenario public.simulation_scenarios;
 v_target bigint;
 v_iteration integer;
 v_steps integer:=0;
 v_failed integer:=0;
 v_state jsonb;
 v_started timestamptz:=clock_timestamp();
 v_one timestamptz;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'NOT_AUTHORIZED';end if;
 if not private.simulation_enabled() then return jsonb_build_object('steps',0);end if;
 -- Locks are acquired in the same order as agents/events. No model lock before
 -- agent_locks; concurrent invocations recheck the durable cursor after waiting.
 for v_candidate in
  select hm.id,hm.scenario_id from private.simulation_hazard_models as hm
  join public.simulation_scenarios as sc on sc.id=hm.scenario_id
  where sc.status='RUNNING' and hm.last_error is null and hm.last_step<5760
  order by hm.last_scan_at nulls first,hm.id limit 4
 loop
  exit when clock_timestamp()-v_started>interval '2 seconds';
  v_one:=clock_timestamp();
  begin
   perform private.agent_locks(v_candidate.scenario_id);
   select sc.* into v_scenario from public.simulation_scenarios as sc where sc.id=v_candidate.scenario_id;
   update private.simulation_hazard_models as hm set last_scan_at=clock_timestamp() where hm.id=v_candidate.id;
   if v_scenario.status<>'RUNNING' or not private.simulation_event_authority(v_scenario.id)
    or not exists(select 1 from private.simulation_template_instances as ti
     where ti.scenario_id=v_scenario.id and ti.state='READY') then continue;end if;
   select hm.* into v_model from private.simulation_hazard_models as hm where hm.id=v_candidate.id for update;
   if v_model.last_error is not null then continue;end if;
   if v_model.version>=9980 then
    update private.simulation_hazard_models as hm set version=hm.version+1,last_error='HAZARD_HISTORY_LIMIT' where hm.id=v_model.id;
    perform private.hazard_record(v_model.id,'LIMIT',null,'{"error":"HAZARD_HISTORY_LIMIT"}',true);continue;
   end if;
   select least(5760,clk.seconds/5) into v_target from public.simulation_scenario_clock as clk where clk.scenario_id=v_scenario.id;
   perform private.hazard_apply(v_model.id);
   for v_iteration in 1..10 loop
    select hm.* into v_model from private.simulation_hazard_models as hm where hm.id=v_candidate.id;
    exit when v_model.last_step>=v_target or v_model.version>=9980 or clock_timestamp()-v_started>interval '2 seconds' or exists(
     select 1 from private.simulation_hazard_effects as he where he.model_id=v_model.id and he.effective_step<=v_model.last_step
     and not exists(select 1 from private.simulation_hazard_history as hh where hh.model_id=v_model.id and hh.operation_id=he.operation_id));
    v_state:=private.hazard_step(v_model.configuration,v_model.state,(v_model.last_step+1-v_model.started_step)*5);
    if v_model.state is distinct from v_state then
     update private.simulation_hazard_models as hm set last_step=hm.last_step+1,version=hm.version+1,state=v_state
      where hm.id=v_model.id returning hm.* into v_model;
    else
     update private.simulation_hazard_models as hm set last_step=hm.last_step+1,version=hm.version+1
      where hm.id=v_model.id returning hm.* into v_model;
    end if;
    perform private.operational_step(v_model.id,v_model.last_step);
    select hm.state into v_state from private.simulation_hazard_models as hm where hm.id=v_model.id;
    perform private.hazard_record(v_model.id,case when exists(
     select 1 from private.simulation_operational_history as oh
     where oh.scenario_id=v_scenario.id and oh.kind='DELIVERY' and oh.sim_second=v_model.last_step*5 and oh.data->>'model_id'=v_model.id::text
    ) then 'STEP_WITH_OPERATIONS' else 'STEP' end,null,
     jsonb_build_object('burning',(select count(*) from jsonb_array_elements(v_state) as cell(value) where (cell.value->>'intensity')::numeric>0)),
     v_model.last_step%60=0 or v_model.last_step=5760);
    perform private.hazard_apply(v_model.id);v_steps:=v_steps+1;
   end loop;
   update private.simulation_hazard_models as hm set last_scan_at=clock_timestamp(),
    processing_ms=round(extract(epoch from clock_timestamp()-v_one)*1000) where hm.id=v_candidate.id;
  exception
   when lock_not_available or deadlock_detected or serialization_failure then v_failed:=v_failed+1;
   when others then
    -- This subtransaction rolls back its state/effect/history together.
    update private.simulation_hazard_models as hm set last_error='HAZARD_PROCESSING_FAILED',last_scan_at=clock_timestamp(),
     version=hm.version+1 where hm.id=v_candidate.id;
    perform private.hazard_record(v_candidate.id,'ERROR',null,jsonb_build_object('error','HAZARD_PROCESSING_FAILED'),false);
    v_failed:=v_failed+1;
  end;
 end loop;
 return jsonb_build_object('steps',v_steps,'failed',v_failed,'duration_ms',round(extract(epoch from clock_timestamp()-v_started)*1000));
end;
$batch$;

commit;
