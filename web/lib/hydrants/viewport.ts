import type {Status} from './domain';
export type ContextHydrant={id:string;organization_id:string;code:string|null;status:Status;latitude:number;longitude:number;
 address:string|null;location_description:string|null;
 organization:{name:string}|null;type:{code:string;name:string;names?:Record<string,string>;organization_id:string|null}|null};
export type HydrantViewport={rows:ContextHydrant[];more:boolean};
