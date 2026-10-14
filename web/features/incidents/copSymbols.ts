import type {Map} from 'maplibre-gl';
import type {MapKind} from '../../lib/incidents/cop';

export const tacticalPointKinds=['COMMAND_POST','STAGING','TRIAGE_POINT','WATER_SOURCE','ACCESS_POINT','NOTE'] as const satisfies readonly MapKind[];
export const copSymbolId=(kind:typeof tacticalPointKinds[number])=>'cop-symbol-'+kind;

/** Fixed local sprites keep map objects in the shared MapLibre source/layer path. */
export function installCopSymbols(map:Map):string[]{
 const canvas=document.createElement('canvas');canvas.width=48;canvas.height=48;
 const c=canvas.getContext('2d');if(!c)return [];
 const installed:string[]=[];
 for(const kind of tacticalPointKinds){
  const id=copSymbolId(kind);if(map.hasImage(id))continue;
  c.clearRect(0,0,48,48);c.save();c.scale(2,2);c.fillStyle='#fff';c.strokeStyle='#fff';c.lineWidth=2;c.lineCap='round';c.lineJoin='round';c.beginPath();
  if(kind==='COMMAND_POST'){c.moveTo(6,20);c.lineTo(6,4);c.lineTo(19,4);c.lineTo(16,8);c.lineTo(19,12);c.lineTo(6,12);c.stroke();}
  else if(kind==='STAGING'){for(const [x,y] of [[7,7],[17,7],[12,4]]){c.moveTo(x+2,y);c.arc(x,y,2,0,Math.PI*2);}c.fill();c.beginPath();c.moveTo(4,19);c.quadraticCurveTo(4,11,10,11);c.moveTo(14,11);c.quadraticCurveTo(20,11,20,19);c.moveTo(8,19);c.lineTo(8,14);c.quadraticCurveTo(8,9,12,9);c.quadraticCurveTo(16,9,16,14);c.lineTo(16,19);c.stroke();}
  else if(kind==='TRIAGE_POINT'){c.fillRect(9,3,6,18);c.fillRect(3,9,18,6);}
  else if(kind==='WATER_SOURCE'){c.moveTo(12,3);c.bezierCurveTo(9,8,5,11,5,15);c.bezierCurveTo(5,24,19,24,19,15);c.bezierCurveTo(19,11,15,8,12,3);c.closePath();c.fill();}
  else if(kind==='ACCESS_POINT'){c.moveTo(3,12);c.lineTo(17,12);c.moveTo(12,6);c.lineTo(18,12);c.lineTo(12,18);c.moveTo(21,5);c.lineTo(21,19);c.stroke();}
  else {c.rect(5,3,14,18);c.moveTo(8,8);c.lineTo(16,8);c.moveTo(8,12);c.lineTo(16,12);c.moveTo(8,16);c.lineTo(13,16);c.stroke();}
  c.restore();map.addImage(id,c.getImageData(0,0,48,48),{pixelRatio:2});installed.push(id);
 }
 return installed;
}
