export type Position=[number,number];
export type Geometry={type:'Point';coordinates:Position}|{type:'LineString';coordinates:Position[]}|{type:'Polygon';coordinates:Position[][]};
export const mapKinds=['COMMAND_POST','STAGING','HAZARD','WATER_SOURCE','ACCESS_POINT','PERIMETER','NOTE'] as const;
export type MapKind=typeof mapKinds[number];
export type Sector={id:string;code:string;name:string;geometry:Geometry|null;version:string;changed_revision:string;can_edit:boolean;can_deactivate:boolean;commander:string|null};
export type MapObject={id:string;kind:MapKind;label:string;description:string;geometry:Geometry;sector_id:string|null;sector_name:string|null;version:string;changed_revision:string;can_edit:boolean};
export type HydrantLink={id:string;purpose:string;version:string;changed_revision:string;can_unlink:boolean;hydrant:{id:string;organization_id:string;code:string|null;latitude:number|null;longitude:number|null;status:string;address:string|null;location_description:string|null}|null};
export type Cop={incident:{id:string;reference_number:string;latitude:number|null;longitude:number|null;status:string;version:string;revision:string};can_manage:boolean;sectors:Sector[];objects:MapObject[];links:HydrantLink[]};
export type CopFeedback={sequence:number;kind:'saved'|'stale'|'blocked'};
export const copMutations:readonly string[]=['sector_create','sector_update','sector_deactivate','object_put','object_deactivate','hydrant_link','hydrant_unlink'];
export const copErrors=['INVALID_GEOMETRY','UNSUPPORTED_GEOMETRY','GEOMETRY_TOO_LARGE','INVALID_SCOPE','INVALID_SECTOR','SECTOR_HAS_ACTIVE_COMMAND','INVALID_MAP_OBJECT','INVALID_HYDRANT','COP_LIMIT_REACHED','DUPLICATE_COP_ENTITY'] as const;
export function geometryPositions(g:Geometry):Position[]{return g.type==='Point'?[g.coordinates]:g.type==='LineString'?g.coordinates:g.coordinates.flat();}
