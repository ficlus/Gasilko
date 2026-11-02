/** C3 decision B. A view contract, NOT a server observation or an upload API.
 * No JSON/route/SIM/device location is accepted by this adapter. */
export const realUnitFreshnessPolicy=Object.freeze({currentUnderSeconds:120,expiresAtSeconds:900});
export type RealUnitBinding=Readonly<{account:string;actingOrganizationId:string;incidentId:string;unitAssignmentId:string}>;
export type RealUnitPositionView=Readonly<{
 binding:RealUnitBinding;availability:'UNAVAILABLE'|'LOCKED';reason:'SOURCE_NOT_IMPLEMENTED'|'SCOPE_UNAVAILABLE';
 coordinate:null;positionOrigin:null;observedAt:null;ageSeconds:null;accuracyM:null;sourceRevision:null;serverAsOf:null;
}>;
const uuid=(v:string)=>/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v);
export function realUnitPositionView(binding:RealUnitBinding,scopeAuthorized:boolean):RealUnitPositionView {
 const allowed=scopeAuthorized&&Object.values(binding).every(uuid);
 const view:RealUnitPositionView={binding:Object.freeze({...binding}),availability:allowed?'UNAVAILABLE':'LOCKED',
  reason:allowed?'SOURCE_NOT_IMPLEMENTED':'SCOPE_UNAVAILABLE',coordinate:null,positionOrigin:null,
  observedAt:null,ageSeconds:null,accuracyM:null,sourceRevision:null,serverAsOf:null};
 return Object.freeze(view);
}
