import {operationalErrors} from '../../../lib/operational/operations';
import {hazardRpcs} from '../../../lib/operational/hazards';
import {scenarioEventRpcs} from '../../../lib/operational/scenarioEvents';
import {templateRpcs} from '../../../lib/operational/templates';
import {agentErrors} from '../../../lib/operational/agents';
import {navigationErrors,navigationReads} from '../../../lib/operational/navigation';
import {simulationErrors,simulationReads} from '../../../lib/operational/simulation';
import {taskErrors,taskReads} from '../../../lib/operational/tasks';
import {resourceErrors} from '../../../lib/operational/model';
import {NextResponse} from 'next/server';
import {serverClient} from '../../../lib/supabase/server';
import {loadAccount} from '../../../lib/auth/load';
import {mutationNames} from '../../../lib/incidents/model';
import {copErrors} from '../../../lib/incidents/cop';

const reads = ['incident_attachment_prepare','incident_attachment_page','incident_message_page','incident_message_history','incident_message_send','incident_sync_head','simulation_operational_command','simulation_operations_read','simulation_operational_actions','simulation_operation_resolve','simulation_hazard_history',...hazardRpcs,'simulation_map_sample',...scenarioEventRpcs,...templateRpcs,'simulation_automation_feed','simulation_agents_read','simulation_agent_command',...navigationReads,...simulationReads,'simulation_command',...taskReads,'incident_resource_selection_page','incident_team_template','incident_entry','incident_list','incident_context','incident_timeline_page','incident_candidates','incident_command_candidates','incident_command_view','incident_command_inbox','incident_cop','incident_cop_hydrants','incident_resources','incident_unit_candidates','incident_resource_candidates','incident_crew_candidates','incident_crew_history','incident_unit_leader_candidates'];
const safeErrors = new Set(['ATTACHMENT_TYPE_UNSUPPORTED','ATTACHMENT_TOO_LARGE','ATTACHMENT_MALFORMED','ATTACHMENT_NOT_READY','ATTACHMENT_REJECTED','ATTACHMENT_LIMIT','SCOPE_CHANGED','MESSAGE_SCOPE_LIMIT',...operationalErrors,'INVALID_TEMPLATE','INVALID_EVENT_PLAN','INVALID_HAZARD_PLAN','SCHEMA_MISMATCH','REQUEST_TOO_LARGE','TEMPLATE_SETUP_REQUIRED',...agentErrors,...navigationErrors,...simulationErrors,'NOT_AUTHORIZED','STALE_VERSION','INVALID_TRANSITION','INVALID_COMMANDER','INVALID_PARTICIPANT','INCIDENT_TERMINAL','OPERATION_REUSED','VALIDATION_FAILED','INVALID_STATE',
 'INVALID_COMMAND_HIERARCHY','INVALID_COMMAND_ROLE','INVALID_COMMAND_CANDIDATE','TRANSFER_NOT_CURRENT','TRANSFER_EXPIRED','TRANSFER_ALREADY_PENDING','LEAD_TRANSFER_REQUIRES_CONSENT','COMMANDER_STILL_VALID','PARTICIPANT_HAS_ACTIVE_COMMAND',...copErrors,...resourceErrors,...taskErrors]);
export async function POST(request:Request) {
 const headers={'Cache-Control':'no-store'};
 if(request.headers.get('origin')!==new URL(request.url).origin) return NextResponse.json({error:'NOT_AUTHORIZED'},{status:403,headers});
 const client=await serverClient(); const account=await loadAccount(client);
 if(!client||account.state!=='ACTIVE') return NextResponse.json({error:account.state==='UNAUTHENTICATED'?'EXPIRED':'NOT_AUTHORIZED'},{status:403,headers});
 const expectedAccount=request.headers.get('X-Gasilko-Account');
 if(expectedAccount){const {data:{user}}=await client.auth.getUser();if(!user||user.id!==expectedAccount)return NextResponse.json({error:'EXPIRED'},{status:403,headers});}
 try {
  const text=await request.text();if(new TextEncoder().encode(text).length>131072)return NextResponse.json({error:'REQUEST_TOO_LARGE',outcome:'REJECTED'},{status:413,headers});
  const input=JSON.parse(text) as {name?:unknown;args?:unknown};
  if(typeof input.name!=='string'||![...reads,...Object.values(mutationNames)].includes(input.name)||!input.args||typeof input.args!=='object'||Array.isArray(input.args))
   return NextResponse.json({error:'VALIDATION_FAILED'},{status:400,headers});
  if(input.name==='incident_navigation_calculate'){
   const result=await client.functions.invoke('incident-navigation',{body:input.args});
   if(result.error){
    let code='SERVER';
    try{if(result.error.context instanceof Response){const body=await result.error.context.json();if(safeErrors.has(body.error))code=body.error;}}catch{}
    return NextResponse.json({error:code},{status:code==='NOT_AUTHORIZED'?403:code==='STALE_VERSION'?409:422,headers});
   }
   return NextResponse.json({data:result.data},{headers});
  }
  const {data,error}=await client.rpc(input.name,input.args);
  if(error){
   const correlation=crypto.randomUUID();
   const schema=['PGRST202','PGRST203','42883','42703','42P01'].includes(error.code??'');
   const code=schema?'SCHEMA_MISMATCH':safeErrors.has(error.message)?error.message:error.code==='42501'?'NOT_AUTHORIZED':/^22|^23/.test(error.code??'')?'VALIDATION_FAILED':'SERVER';
   console.error('incident_rpc_rejected',{correlation,rpc:input.name,sqlstate:error.code,code});
   return NextResponse.json({error:code,correlation,outcome:['SERVER','SCHEMA_MISMATCH','NOT_AUTHORIZED','EXPIRED','SIMULATION_DISABLED'].includes(code)?'UNKNOWN':'REJECTED'},{status:400,headers});
  }
  if(input.name==='incident_entry'||input.name==='incident_command_inbox'){
   const records=input.name==='incident_entry'?[...(data?.invitations??[]),...(data?.nominations??[])]:data??[];
   const ids=[...new Set<string>(records.map((row:{incident_id:string})=>row.incident_id))];
   const labels=await client.rpc('simulation_inbox_labels',{p_ids:ids});
   if(labels.error)return NextResponse.json({error:'SERVER'},{status:503,headers});
   const label=(row:{incident_id:string})=>({...row,training:labels.data?.[row.incident_id]??null});
   return NextResponse.json({data:input.name==='incident_entry'?{...data,invitations:(data.invitations??[]).map(label),nominations:(data.nominations??[]).map(label)}:records.map(label)},{headers});
  }
  // Mark all returned incidents using authoritative scenario membership, even
  // when simulation writes are disabled. Fail closed rather than show unlabelled training data.
  if(input.name==='incident_list'||input.name==='incident_context'||input.name==='incident_sync_head'){
   const records=Array.isArray(data)?data:data?[data]:[];
   const args=input.args as Record<string,unknown>;
   const labels=await client.rpc('simulation_labels',{p_acting_organization_id:args.p_acting_organization_id,p_ids:records.map((row:{id:string})=>row.id)});
   if(labels.error)return NextResponse.json({error:'SERVER'},{status:503,headers});
   const label=(row:{id:string})=>({...row,training:labels.data?.[row.id]??null});
   return NextResponse.json({data:Array.isArray(data)?records.map(label):data?label(data):null},{headers});
  }
  return NextResponse.json({data},{headers});
 } catch { return NextResponse.json({error:'SERVER'},{status:503,headers}); }
}
