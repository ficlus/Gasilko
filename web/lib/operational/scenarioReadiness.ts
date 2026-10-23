import {placementMissing,type Definition} from './templates';
import type {EventPlan} from './scenarioEvents';
import type {HazardPlan} from './hazards';
export type EditorSection='overview'|'area'|'units'|'objects'|'hazards'|'events'|'settings'|'review';
export function scenarioReadiness(d:Definition,e:EventPlan,h:HazardPlan){
 const issues:{section:EditorSection;code:string}[]=[];
 const add=(section:EditorSection,code:string)=>{if(!issues.some(i=>i.section===section&&i.code===code))issues.push({section,code});};
 if(!d.metadata.title.trim()||d.metadata.title.length>200||d.metadata.duration_minutes<5||d.metadata.duration_minutes>480||d.metadata.objectives.length>20)add('overview','INVALID_TEMPLATE');
 if(placementMissing(d)||d.world.radius_m<10||d.world.radius_m>5000)add('area','missing');
 if(d.virtual_units.length>30)add('units','INVALID_TEMPLATE');
 if(d.initial_objects.length>40)add('objects','INVALID_TEMPLATE');
 if(e.events.length>40)add('events','INVALID_EVENT_PLAN');
 e.events.forEach((v,i)=>{
  const prior=e.events.slice(0,i);
  if(!v.title.trim()||v.title.length>200||v.trigger.mode==='AFTER_EVENT'&&!prior.some(p=>p.id===v.trigger.event_id)||
   v.trigger.mode==='SIMULATION_TIME'&&(!Number.isInteger(v.trigger.offset_seconds)||v.trigger.offset_seconds!<0||v.trigger.offset_seconds!>28800)||
   v.effect?.source_object_id&&!d.initial_objects.some(o=>o.id===v.effect?.source_object_id)||
   v.type==='HAZARD_UPDATE'&&!prior.some(p=>p.id===v.effect?.target_event_id&&p.type==='HAZARD_REVEAL')||
   v.effect&&!v.effect.source_object_id&&!v.effect.geometry)add('events','INVALID_EVENT_PLAN');
 });
 if(h.models.length>4||h.models.filter(m=>m.type==='WILDFIRE').length>1)add('hazards','INVALID_HAZARD_PLAN');
 h.models.forEach(m=>{
  if(!m.title.trim()||m.origins.length<1||m.origins.length>8||m.radius_m<25||m.radius_m>250||m.radius_m%m.cell_m!==0||Math.abs(m.center[1])>75||m.effects.some(x=>!e.events.some(v=>v.id===x.event_id)||x.effect.type==='IGNITE'&&!m.origins.some(o=>o.id===x.effect.value)))add('hazards','INVALID_HAZARD_PLAN');
 });
 if(d.operational){
  const cfg=d.operational;
  if(cfg.resources.length>30||cfg.bindings.length>16||cfg.resources.some(r=>!d.virtual_units.some(u=>u.id===r.unit_key)||![r.capacity_l,r.initial_l,r.pump_lpm,r.range_m,r.efficiency].every(Number.isFinite)||r.initial_l<0||r.initial_l>r.capacity_l||r.capacity_l<0||r.capacity_l>100000||r.pump_lpm<0||r.pump_lpm>5000||r.range_m<1||r.range_m>100||r.efficiency<0.000001||r.efficiency>0.001)||cfg.bindings.some(b=>b.duration_seconds<5||b.duration_seconds>3600||b.duration_seconds%5!==0||b.flow_lpm<=0||b.flow_lpm>5000))add('settings','INVALID_TEMPLATE');
 }
 return issues;
}
