'use client';
import {useEffect,useState} from 'react';
import type {Locale} from '../../lib/i18n';
import {agentEvents,agentProfiles,terminalAgent,type AgentRun} from '../../lib/operational/agents';
import {agentText} from '../../lib/operational/agentMessages';
import {taskText} from '../../lib/operational/taskMessages';
import {navigationText} from '../../lib/operational/navigationMessages';
import {simulationText} from '../../lib/operational/simulationMessages';
import {useAutonomousSimulation} from './AutonomousSimulationProvider';
import {useSimulation} from './SimulationProvider';
import {useIncidentNavigation} from './IncidentNavigationProvider';
import {useWorkspace} from './workspace';
export function AutonomousSimulationPanel({locale}:{locale:Locale}){
 const agents=useAutonomousSimulation(),sim=useSimulation(),nav=useIncidentNavigation(),workspace=useWorkspace();
 const t=agentText(locale),tt=taskText(locale),nt=navigationText(locale),st=simulationText(locale);
 const [assignment,setAssignment]=useState(''),[profile,setProfile]=useState<string>('NORMAL');
 const [ack,setAck]=useState('3'),[start,setStart]=useState('2'),[completion,setCompletion]=useState('5'),[factor,setFactor]=useState('1'),[fault,setFault]=useState('0.5'),[duration,setDuration]=useState('30');
 const [eventRun,setEventRun]=useState(''),[event,setEvent]=useState<string>('SIM_BREAKDOWN'),[trigger,setTrigger]=useState('PROGRESS'),[value,setValue]=useState('0.6');
 const selected=workspace?.selected?.kind==='INCIDENT_UNIT'?workspace.selected.id:null;
 useEffect(()=>{agents?.scope(selected);setAssignment('');setEventRun('');},[selected]);
 useEffect(()=>{const template=sim?.data?.scenario?.template;setAck(template==='WILDFIRE'?'8':template==='TRAFFIC_ACCIDENT'?'2':'3');setStart(template==='WILDFIRE'?'5':'2');},[sim?.data?.scenario?.id]);
 if(!agents||!sim?.data?.scenario||!sim.data.enabled)return null;
 const d=agents.data,s=sim.data.scenario,row=d?.assignments.find(a=>a.id===assignment);
 const can=!!d?.can_control&&!agents.busy&&!agents.pending;
 const moving=!!row&&['MOVE_TO','WITHDRAW_TO'].includes(row.behavior);
 const ready=!!row&&(!moving||!!row.route_id&&!!row.origin_current&&(row.access_gap??Infinity)<=5);
 const stale=sim.data.positions.filter(p=>!Number.isFinite(Date.parse(p.observed_at))||Date.now()-Date.parse(p.observed_at)>30000).length;
 const runner=d?.clock.last_runner_at?Date.now()-Date.parse(d.clock.last_runner_at)<30000?'active':'unavailable':'manual';
 const time=(seconds:number)=>new Date(seconds*1000).toISOString().slice(11,19);
 function control(action:string,r:AgentRun){agents?.propose(action,{run_id:r.id,version:r.version},r.callsign+' · '+t(r.status)+' → '+t(action));}
 return <>
 {workspace?.view==='command'&&<section className="operational-card" aria-label={t('autoTitle')}>
 <h3>SIM · {t('autoTitle')}</h3>
 {d?<><p><strong>{t(d.automation.enabled?'autoOn':'autoOff')}</strong> · {t(d.can_control?'autoController':'autoReadOnly')}</p>
 <p>{st(s.status)} · {t('profile')}: {t(d.automation.profile)} · {t('scale')}: {d.clock.scale}× · {t('runner')}: {t(runner)}</p>
 <p>{t('autoBoundary')}</p>
 <div className="actions"><button disabled={!can||s.status==='FINISHED'} onClick={()=>agents.propose('AUTOMATION',{enabled:!d.automation.enabled,profile:d.automation.profile},t(d.automation.enabled?'autoDisableConfirm':'autoEnableConfirm'))}>{t(d.automation.enabled?'autoDisable':'autoEnable')}</button>
 <label>{t('profile')}<select disabled={!can||s.status==='FINISHED'} value={d.automation.profile} onChange={e=>agents.propose('AUTOMATION',{enabled:d.automation.enabled,profile:e.target.value},t('profile')+' · '+t(e.target.value))}>{agentProfiles.map(p=><option key={p} value={p}>{t(p)}</option>)}</select></label></div>
 {agents.error&&<p role="alert">{t(agents.error)}</p>}
 <div style={{maxHeight:'18rem',overflowY:'auto'}} aria-label={t('autoJobs')}>
 {!d.automation.jobs.length&&<p>{t('autoEmpty')}</p>}
 {d.automation.jobs.map(job=><article className="web-row" key={job.id}>
 <strong>{job.callsign} · {locale==='de'?job.label_de:job.label_sl}</strong><p>{job.target??'—'}</p>
 <p>{t('auto_'+job.state)}{job.run_state?' · '+t(job.run_state):''}</p>
 {job.navigation_state&&<p>{t('navigation')}: {nt(job.navigation_state)}</p>}
 {job.distance_m!=null&&<p>{(job.distance_m/1000).toFixed(2)} km · {job.duration_s==null?'—':Math.ceil(job.duration_s/60)+' min'}
 {job.remaining_s!=null?' · '+t('remaining')+': '+Math.ceil(job.remaining_s/60)+' min':''}</p>}
 {job.error&&<p role="status">{t(job.error)}</p>}
 {job.detail.distance_m!=null&&<p>{t('gap')}: {job.detail.distance_m.toFixed(1)} m · {t('roadOnly')}</p>}
 <div className="actions">
 {job.route_id&&<button onClick={()=>{nav?.select(job.assignment_id);if(job.route_id)nav?.viewRoute(job.route_id);}}>{t('show')}</button>}
 {job.error==='SIM_ACCESS_GAP'&&job.detail.snapped_origin&&job.position_version&&<button disabled={!can} onClick={()=>{const point=job.detail.snapped_origin;if(point)sim.propose('SET_POSITION',{unit_id:job.unit_id,position_version:job.position_version,longitude:point[0],latitude:point[1],heading_degrees:0,speed_mps:0},t('access')+' · '+job.callsign+' · '+point.join(', '));}}>{t('access')}</button>}
 {['BLOCKED','RETRY'].includes(job.state)&&<button disabled={!can||s.status!=='RUNNING'} onClick={()=>agents.propose('AUTOMATION_RETRY',{job_id:job.id,version:job.version},job.callsign+' · '+t('autoRetryConfirm'))}>{t('autoRetry')}</button>}
 </div></article>)}
 </div>
 <div className="actions"><button disabled={agents.page===0} onClick={()=>agents.setPage(agents.page-1)}>{t('previous')}</button><button disabled={!d.automation.more} onClick={()=>agents.setPage(agents.page+1)}>{t('next')}</button></div>
 </>:<p role="status">{agents.error?t(agents.error):t('autoLoading')}</p>}
 </section>}
 <details className="workspace-section"><summary>SIM · {t('title')}</summary>
 <p>{t('notice')}</p>{agents.error&&<p role="alert">{t(agents.error)}</p>}
 <button onClick={agents.refresh}>{t('refresh')}</button>
 {d&&<>
 <p><strong>{t('clock')}: {Math.floor(d.clock.seconds/86400)>0?Math.floor(d.clock.seconds/86400)+' d ':''}{time(d.clock.seconds)} · {d.clock.scale}×</strong></p>
 <p>{t('runner')}: {t(runner)} · {t('latest')}: {d.clock.last_tick_at??'—'}</p>
 {d.clock.last_error&&<p role="alert">{t(d.clock.last_error)}</p>}{d.clock.behind&&<p>{t('behind')}</p>}
 <p>{t('moving')}: {d.counts.moving} · {t('waiting')}: {d.counts.waiting} · {t('blocked')}: {d.counts.blocked} · {t('total')}: {d.counts.total} · {t('stale')}: {stale}</p>
 <div className="actions" aria-label={t('scale')}>{[1,5,10].map(scale=><button key={scale} disabled={!can||s.status==='FINISHED'} onClick={()=>agents.propose('SCALE',{scale},scale+'×')}>{scale}×</button>)}
 <button disabled={!can||s.status!=='RUNNING'} onClick={()=>agents.propose('STEP',{tick:d.clock.tick},t('STEP'))}>{t('STEP')}</button>
 <button disabled={!can} onClick={()=>agents.propose('STOP_ALL',{},t('STOP_ALL'))}>{t('STOP_ALL')}</button>
 {['RUNNING','PAUSED'].includes(s.status)&&<button disabled={!can} onClick={()=>sim.propose(s.status==='RUNNING'?'PAUSE':'RESUME',{},st(s.status==='RUNNING'?'PAUSE':'RESUME'))}>{st(s.status==='RUNNING'?'PAUSE':'RESUME')}</button>}
 </div>
 <p>{selected?sim.data.positions.find(p=>p.incident_unit_id===selected)?.callsign:t('all')}</p>
 <label>{t('select')}<select value={assignment} onChange={e=>setAssignment(e.target.value)}><option value="">—</option>{d.assignments.map(a=><option key={a.id} value={a.id}>{a.callsign} · {locale==='de'?a.label_de:a.label_sl} · {a.target}</option>)}</select></label>
 {row&&<section className="operational-card">
 <h4>{row.callsign} → {row.target}</h4><p>{t('operational')}: {tt(row.status)}</p>
 {moving&&<><p>{row.distance_m==null?'—':(row.distance_m/1000).toFixed(2)+' km'} · {row.duration_s==null?'—':Math.ceil(row.duration_s/60)+' min'}</p>
 <p>{t('gap')}: {row.access_gap?.toFixed(1)??'—'}</p><p>{t('roadOnly')}</p>
 <div className="actions"><button onClick={()=>nav?.select(row.id)}>{t('route')}</button>
 <button disabled={!row.route_id} onClick={()=>{nav?.select(row.id);if(row.route_id)nav?.viewRoute(row.route_id);}}>{t('show')}</button>
 <button disabled={!can||!row.snapped_origin} onClick={()=>row.snapped_origin&&sim.propose('SET_POSITION',{unit_id:row.unit_id,position_version:row.position_version,longitude:row.snapped_origin[0],latitude:row.snapped_origin[1],heading_degrees:0,speed_mps:0},t('access')+' · '+row.callsign+' · '+row.snapped_origin.join(', '))}>{t('access')}</button></div>
 <p>{t('recalculate')}</p>{!ready&&<p role="status">{t(row.access_gap!=null&&row.access_gap>5?'SIM_ACCESS_GAP':'SIM_ROUTE_REQUIRED')}</p>}</>}
 <label>{t('profile')}<select value={profile} onChange={e=>{setProfile(e.target.value);setAck(e.target.value==='SLOW_RESPONSE'?'15':'3');setStart(e.target.value==='SLOW_RESPONSE'?'10':'2');}}>{agentProfiles.map(p=><option key={p} value={p}>{t(p)}</option>)}</select></label>
 <div className="actions">{[
 ['ack',ack,setAck,0,600],['start',start,setStart,0,600],['completion',completion,setCompletion,0,3600],
 ['factor',factor,setFactor,0.1,3],['fault',fault,setFault,0.01,0.99],['duration',duration,setDuration,1,3600]
 ].map(([label,current,set,min,max])=><label key={label as string}>{t(label as string)}<input type="number" min={min as number} max={max as number} step={label==='factor'||label==='fault'?'0.01':'1'} value={current as string} onChange={e=>(set as (v:string)=>void)(e.target.value)}/></label>)}</div>
 <button disabled={!can||!ready||s.status!=='RUNNING'} onClick={()=>agents.propose('START',{run_id:crypto.randomUUID(),assignment_id:row.id,position_version:row.position_version,session_id:moving?row.session_id:null,route_id:moving?row.route_id:null,
 profile,ack_delay:Number(ack),start_delay:Number(start),completion_delay:Number(completion),speed_factor:Number(factor),fault_progress:Number(fault),signal_duration:Number(duration)},
 row.callsign+' → '+row.target+'\n'+t(profile)+' · '+ack+' s · '+d.clock.scale+'×\n'+(row.distance_m??0)+' m / '+(row.duration_s??0)+' s'+'\n'+t('start')+': '+start+' · '+t('completion')+': '+completion+' · '+t('factor')+': '+factor+' · '+t('fault')+': '+fault+' · '+t('duration')+': '+duration)}>{t('START')}</button>
 </section>}
 {d.runs.map(r=><article className="operational-card" key={r.id}>
 <h4>SIM · {r.callsign} · {r.target}</h4><p>{t('operational')}: {tt(r.operational_status)} · {t('navigation')}: {r.navigation_status?nt(r.navigation_status):'—'}</p>
 <p><strong>{t('simulation')}: {t(r.status)}</strong></p>
 {r.route_id&&<><progress aria-label={t('progress')} value={r.progress_m} max={r.length_m||1}/><p>{t('progress')}: {(r.progress_m/1000).toFixed(2)} / {(r.length_m/1000).toFixed(2)} km · {t('speed')}: {(r.speed_mps*3.6).toFixed(0)} km/h</p>
 <p>{t('remaining')}: {r.baseline_mps>0?Math.ceil((r.length_m-r.progress_m)/r.baseline_mps/60):'—'} min</p>
 <button onClick={()=>{nav?.select(r.task_assignment_id);if(r.route_id)nav?.viewRoute(r.route_id);}}>{t('show')}</button></>}
 {!terminalAgent(r)&&<div className="actions">{['PAUSE','RESUME','STOP','CLEAR'].map(action=><button key={action} disabled={!can} onClick={()=>control(action,r)}>{t(action)}</button>)}<button disabled={!can} onClick={()=>setEventRun(r.id)}>{t('INJECT')}</button></div>}
 </article>)}
 {eventRun&&d.runs.some(r=>r.id===eventRun&&!terminalAgent(r))&&<fieldset><legend>{t('INJECT')} · {d.runs.find(r=>r.id===eventRun)?.callsign}</legend>
 <label>{t('event')}<select value={event} onChange={e=>setEvent(e.target.value)}>{agentEvents.map(e=><option key={e} value={e}>{t(e)}</option>)}</select></label>
 <label>{t('trigger')}<select value={trigger} onChange={e=>setTrigger(e.target.value)}>{['TIME','AFTER_ACK','PROGRESS','EXECUTION_START'].map(v=><option key={v} value={v}>{t(v)}</option>)}</select></label>
 <label>{t('value')}<input type="number" min="0" max={trigger==='PROGRESS'?1:31536000} step={trigger==='PROGRESS'?'0.01':'1'} value={value} onChange={e=>setValue(e.target.value)}/></label>
 <label>{t('duration')}<input type="number" min="1" max="3600" value={duration} onChange={e=>setDuration(e.target.value)}/></label>
 <button disabled={!can} onClick={()=>{const r=d.runs.find(r=>r.id===eventRun);if(r)agents.propose('INJECT',{run_id:r.id,version:r.version,event_id:crypto.randomUUID(),event_type:event,trigger_type:trigger,trigger_value:Number(value),duration:Number(duration)},r.callsign+' · '+t(event)+' · '+t(trigger)+' '+value);}}>{t('INJECT')}</button>
 <button onClick={()=>setEventRun('')}>{t('cancel')}</button></fieldset>}
 <div className="actions"><button disabled={agents.page===0} onClick={()=>agents.setPage(agents.page-1)}>{t('previous')}</button><button disabled={!d.more} onClick={()=>agents.setPage(agents.page+1)}>{t('next')}</button></div>
 <details><summary>{t('scheduled')}</summary>{d.injections.map(e=><p key={e.id}>{t(e.event_type)} · {t(e.trigger_type)} {e.trigger_value} · {e.fired_at==null?t('notFired'):t('fired')+' '+e.fired_at+' s'} · {e.run_id}</p>)}</details>
 <details><summary>{t('history')}</summary>{d.events.map(e=><article key={e.sequence}><strong>{t(e.event_type)}</strong><p>{e.sim_seconds} s · {e.created_at} · {t(e.actor_origin)} {e.actor_user_id??''} · {e.run_id??''}</p><pre>{JSON.stringify(e.payload,null,2)}</pre></article>)}
 <button onClick={()=>agents.older(null)}>{t('newest')}</button><button disabled={d.events.length<50} onClick={()=>agents.older(d.events.at(-1)?.sequence??null)}>{t('older')}</button></details>
 </>}
 </details></>;
}
