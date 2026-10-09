'use client';
import {useEffect} from 'react';
import type {Map} from 'maplibre-gl';
import type {Locale} from '../../lib/i18n';
import {OperationalMapCanvas} from './OperationalMapCanvas';
import {integrationText} from '../../lib/operational/integrationMessages';
import {resolveTarget} from '../../lib/operational/target';
import type {Geometry} from '../../lib/incidents/cop';
function LocationLayer({map,geometry}:{map:Map;geometry:Geometry}){
 useEffect(()=>{map.addSource('canonical-location',{type:'geojson',data:{type:'Feature',geometry,properties:{}}});
  map.addLayer({id:'canonical-location',type:'circle',source:'canonical-location',paint:{'circle-radius':12,'circle-color':'#a9232e','circle-stroke-color':'#fff','circle-stroke-width':3}});
  return()=>{if(map.getLayer('canonical-location'))map.removeLayer('canonical-location');if(map.getSource('canonical-location'))map.removeSource('canonical-location');};
 },[map,geometry]);return null;
}
export default function CanonicalLocation({locale,hydrant}:{locale:Locale;hydrant:{id:string;latitude:number|null;longitude:number|null}}){
 const g=resolveTarget({kind:'HYDRANT',entityId:hydrant.id},{hydrants:[hydrant]});
 const t=integrationText(locale);if(!g||g.type!=='Point')return <p>{t('noLocation')}</p>;
 return <OperationalMapCanvas locale={locale} label={t('map')} initialPoints={[g.coordinates]}>{map=><LocationLayer map={map} geometry={g}/>}</OperationalMapCanvas>;
}
