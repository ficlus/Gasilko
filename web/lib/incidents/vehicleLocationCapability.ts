/** C2 safe subset: no observation, consent session, producer or enable input. */
export const vehicleLocationProducerEnabled=false;
export type VehicleLocationScope=Readonly<{account:string;org:string;incidentId:string}>;
const uuid=(value:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
const fields=['schema_version','account','organization','incident_id','scope_fingerprint','mode','state',
 'enabled','producer_available','reader_available','policy_approved','retention_ready','device_binding_ready'].sort();
export function isDisabledVehicleCapability(value:unknown,scope:VehicleLocationScope,fingerprint:string):boolean {
 if(vehicleLocationProducerEnabled||!Object.values(scope).every(uuid)||!value||typeof value!=='object'||Array.isArray(value))return false;
 const row=value as Record<string,unknown>;
 return Object.keys(row).sort().join(',')===fields.join(',')&&row.schema_version===1&&row.account===scope.account&&
  row.organization===scope.org&&row.incident_id===scope.incidentId&&/^[0-9a-f]{32}$/.test(fingerprint)&&row.scope_fingerprint===fingerprint&&
  (row.mode==='REAL'||row.mode==='TRAINING')&&row.state==='DISABLED'&&
  ['enabled','producer_available','reader_available','policy_approved','retention_ready','device_binding_ready'].every(key=>row[key]===false);
}
