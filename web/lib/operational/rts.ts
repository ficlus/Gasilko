import type {Recipient,TaskTarget,Task} from './tasks';
import type {Geometry} from '../incidents/cop';

export type RtsMode='NORMAL'|'SELECT_BOX'|'SELECT_LASSO'|'CHOOSE_TARGET';
export type RtsRecipient=Recipient&{assignmentId:string;eligibility:'UNKNOWN'|'ELIGIBLE'|'UNAVAILABLE';sector_name?:string|null;status?:string};
export type RecipientKey=Pick<Recipient,'type'|'id'>;
export const recipientKey=(r:RecipientKey)=>r.type+':'+r.id;
export type TargetPreview={target:TaskTarget;geometry:Geometry|null;label:string};
export type TaskIntent=Pick<Task,'id'|'priority'|'status'|'outcome'|'target_geometry_snapshot'|'target_label_snapshot'>&{label:string};
export type Pixel=readonly [number,number];
export const sameRecipient=(a:RecipientKey,b:RecipientKey)=>recipientKey(a)===recipientKey(b);
/** Transient screen-space gesture only. Never a geographic sector or persisted object. */
export function pixelInPolygon(point:Pixel,polygon:readonly Pixel[]):boolean{
 let inside=false;
 for(let i=0,j=polygon.length-1;i<polygon.length;j=i++){
  const a=polygon[i],b=polygon[j];
  const cross=(point[0]-a[0])*(b[1]-a[1])-(point[1]-a[1])*(b[0]-a[0]);
  if(Math.abs(cross)<0.01&&point[0]>=Math.min(a[0],b[0])&&point[0]<=Math.max(a[0],b[0])&&point[1]>=Math.min(a[1],b[1])&&point[1]<=Math.max(a[1],b[1]))return true;
  if((a[1]>point[1])!==(b[1]>point[1])&&point[0]<(b[0]-a[0])*(point[1]-a[1])/(b[1]-a[1])+a[0])inside=!inside;
 }
 return inside;
}
export const typingTarget=(target:EventTarget|null)=>target instanceof Element&&!!target.closest('input,textarea,select,[contenteditable="true"],[contenteditable=""],[role="textbox"]');
