-- M14.5A/C: fix PL/pgSQL variable/SQL alias ambiguities encountered during
-- training scenario provisioning and task issuance (SQLSTATE 42702).
--
-- Forward-only, compatible with the already deployed one-off SQL Editor patches
-- (sim_vars.unit_id, AS def(value), AS recipient(value)).
-- No data updates, policy changes, grants, new privileges, or new tables.
-- Apply once after M14.5D prerequisites and before M14.5E.
--
-- Intentionally use the current installed function definitions instead of
-- replacing them with old migration copies: this preserves any later security
-- hooks added by subsequent milestones. EVERY change is guarded by an exact
-- expected substring; drift aborts the transaction instead of guessing.

begin;

do $m145_ambiguity_hotfix$
declare
  v_def text;
  v_old text;
  v_new text;
  v_anchor text;
  v_start integer;
  v_end integer;
  v_block text;
  v_fixed text;
  v_changes integer;
begin
  ---------------------------------------------------------------------------
  -- 1. M14.5A parameter validator: d is both a PL/pgSQL variable and
  --    an unqualified SQL range alias. Give the SQL JSON value its own name.
  ---------------------------------------------------------------------------
  select pg_get_functiondef(
    'private.validate_action_parameters(jsonb,jsonb)'::regprocedure
  ) into v_def;

  v_old := 'from jsonb_array_elements(p_defs) d where d->>''code''=x';
  v_new := 'from jsonb_array_elements(p_defs) AS param_def(value) where param_def.value->>''code''=x';

  if strpos(v_def,v_old)>0 then
    v_changes := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
    if v_changes<>1 then
      raise exception 'HOTFIX_D_UNEXPECTED_OCCURRENCES: %',v_changes;
    end if;
    execute replace(v_def,v_old,v_new);
    raise notice 'M14.5A validator d: repaired';
  elsif strpos(v_def,v_new)>0
     or strpos(v_def,'from jsonb_array_elements(p_defs) AS def(value) where def.value->>''code''=x')>0
  then
    raise notice 'M14.5A validator d: already repaired';
  else
    raise exception 'HOTFIX_D_SOURCE_DRIFT: review installed function before changing it';
  end if;

  ---------------------------------------------------------------------------
  -- 2. M14.5A assignment insertion: r is a PL/pgSQL JSONB variable and
  --    also a SQL table alias. Change ONLY the INSERT ... SELECT block,
  --    leaving the FOR r LOOP and other similarly named aliases untouched.
  ---------------------------------------------------------------------------
  select pg_get_functiondef(
    'private.incident_task_command(text,uuid,uuid,uuid,bigint,jsonb)'::regprocedure
  ) into v_def;

  v_start := strpos(v_def,'insert into public.incident_task_assignments(');
  v_end := strpos(v_def,'task_id_value:=entity;');

  if v_start=0 or v_end<=v_start then
    raise exception 'HOTFIX_R_SOURCE_DRIFT: assignment insertion block not found';
  end if;

  v_block := substr(v_def,v_start,v_end-v_start);
  v_old := 'from jsonb_array_elements(p_payload->''recipients'') r;';
  v_new := 'from jsonb_array_elements(p_payload->''recipients'') AS recipient(value);';

  if strpos(v_block,v_new)>0 then
    if strpos(v_block,'recipient.value->>')=0 then
      raise exception 'HOTFIX_R_INCONSISTENT: renamed alias without matching JSON expressions';
    end if;
    raise notice 'M14.5A assignment r: already repaired';
  elsif strpos(v_block,v_old)>0 then
    if strpos(v_block,'r->>')=0 then
      raise exception 'HOTFIX_R_SOURCE_DRIFT: original JSON expressions missing';
    end if;
    v_changes := (length(v_block)-length(replace(v_block,v_old,'')))/length(v_old);
    if v_changes<>1 then
      raise exception 'HOTFIX_R_UNEXPECTED_OCCURRENCES: %',v_changes;
    end if;

    v_fixed := replace(v_block,'r->>','recipient.value->>');
    v_fixed := replace(v_fixed,v_old,v_new);
    v_def := overlay(v_def placing v_fixed from v_start for length(v_block));
    execute v_def;
    raise notice 'M14.5A assignment r: repaired';
  else
    raise exception 'HOTFIX_R_SOURCE_DRIFT: original/known-repaired alias not found';
  end if;

  ---------------------------------------------------------------------------
  -- 3. M14.5C provisioning: incident_units has its own unit_id column,
  --    which conflicts with simulation_command's local unit_id variable.
  --    Qualify the PL/pgSQL variable using an actual BLOCK LABEL, never
  --    a function name (simulation_command.unit_id is invalid in this form).
  ---------------------------------------------------------------------------
  select pg_get_functiondef(
    'public.simulation_command(uuid,uuid,uuid,bigint,text,jsonb)'::regprocedure
  ) into v_def;

  v_old := 'where id=unit_id and incident_id=s.incident_id for update;';
  v_new := 'where id=sim_vars.unit_id and incident_id=s.incident_id for update;';
  v_anchor := 'declare actor uuid:=auth.uid();';

  if strpos(v_def,v_new)>0 and strpos(v_def,'<<sim_vars>>')>0 then
    raise notice 'M14.5C unit_id: already repaired';
  else
    if strpos(v_def,v_new)>0 and strpos(v_def,'<<sim_vars>>')=0 then
      raise exception 'HOTFIX_UNIT_INCONSISTENT: qualified variable without block label';
    end if;

    if strpos(v_def,v_old)=0 then
      v_old := 'where id=simulation_command.unit_id and incident_id=s.incident_id for update;';
    end if;

    if strpos(v_def,v_old)=0 then
      raise exception 'HOTFIX_UNIT_SOURCE_DRIFT: expected unit lookup not found';
    end if;

    v_changes := (length(v_def)-length(replace(v_def,v_old,'')))/length(v_old);
    if v_changes<>1 then
      raise exception 'HOTFIX_UNIT_UNEXPECTED_OCCURRENCES: %',v_changes;
    end if;

    if strpos(v_def,'<<sim_vars>>')=0 then
      if strpos(v_def,v_anchor)=0 then
        raise exception 'HOTFIX_UNIT_SOURCE_DRIFT: declaration anchor not found';
      end if;
      v_changes := (length(v_def)-length(replace(v_def,v_anchor,'')))/length(v_anchor);
      if v_changes<>1 then
        raise exception 'HOTFIX_UNIT_UNEXPECTED_DECLARATIONS: %',v_changes;
      end if;
      v_def := replace(v_def,v_anchor,'<<sim_vars>>'||chr(10)||v_anchor);
    end if;

    v_def := replace(v_def,v_old,v_new);
    execute v_def;
    raise notice 'M14.5C unit_id: repaired';
  end if;

  raise notice 'M14.5A/C SQL ambiguity hotfix complete';
end;
$m145_ambiguity_hotfix$;

commit;
