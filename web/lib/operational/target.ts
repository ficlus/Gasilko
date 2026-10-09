import {geometryPositions,type Geometry,type Cop,type Position} from '../incidents/cop';
import {isUuid} from './entity';
export type OperationalTarget={kind:'HYDRANT';entityId:string}|{kind:'INCIDENT_MAP_OBJECT'|'INCIDENT_SECTOR';entityId:string;incidentId:string}|{kind:'COORDINATE';coordinate:Position};
export const validPosition=(p:unknown):p is Position=>Array.isArray(p)&&p.length===2&&p.every(v=>typeof v==='number'&&Number.isFinite(v))&&Math.abs(p[0])<=180&&Math.abs(p[1])<=90;
/** Pure adapter over an already authorized, bounded DTO. Never loads or grants access. */
export function resolveTarget(target:OperationalTarget,authorized:{cop?:Cop;hydrants?:{id:string;longitude:number|null;latitude:number|null}[]}):Geometry|null{
 if(target.kind==='COORDINATE')return validPosition(target.coordinate)?{type:'Point',coordinates:target.coordinate}:null;
 if(!isUuid(target.entityId))return null;
 if(target.kind==='HYDRANT'){
  const h=authorized.hydrants?.find(h=>h.id===target.entityId)??authorized.cop?.links.find(l=>l.hydrant?.id===target.entityId)?.hydrant;
  const p=[h?.longitude,h?.latitude];return validPosition(p)?{type:'Point',coordinates:p}:null;
 }
 const cop=authorized.cop;if(!cop||cop.incident.id!==target.incidentId)return null;
 const g=target.kind==='INCIDENT_SECTOR'?cop.sectors.find(s=>s.id===target.entityId)?.geometry:cop.objects.find(o=>o.id===target.entityId)?.geometry;
 return g&&geometryPositions(g).length<=2000&&geometryPositions(g).every(validPosition)?g:null;
}
