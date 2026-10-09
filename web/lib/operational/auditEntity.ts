import {isUuid,type EntityRef,type EntityType} from './entity';
const types:Record<string,EntityType>={hydrants:'HYDRANT',inspection_plans:'PLAN',incidents:'INCIDENT',inspection_teams:'TEAM',organizations:'ORGANIZATION',operational_units:'OPERATIONAL_UNIT',operational_vehicles:'OPERATIONAL_VEHICLE'};
const object=(v:unknown):Record<string,unknown>=>v&&typeof v==='object'&&!Array.isArray(v)?v as Record<string,unknown>:{};
/** Only stable typed IDs from the existing audit contract; never parse prose. */
export function auditEntity(row:Record<string,unknown>):EntityRef|null{
 const type=typeof row.entity_type==='string'?types[row.entity_type]:undefined;
 if(!type||!isUuid(row.entity_id))return null;
 const context={organizationId:isUuid(row.organization_id)?row.organization_id:undefined};
 if(type==='INCIDENT'){
  const event=object(object(row.new_data).event);
  // Resource event payloads are already typed by their owning domain.
  if(isUuid(event.resource_allocation_id))return {type:'ALLOCATION',id:event.resource_allocation_id,context:{...context,incidentId:row.entity_id}};
  if(isUuid(event.unit_assignment_id))return {type:'INCIDENT_UNIT',id:event.unit_assignment_id,context:{...context,incidentId:row.entity_id}};
 }
 return {type,id:row.entity_id,context:type==='ORGANIZATION'?{organizationId:row.entity_id}:context};
}
