export const inventoryReads=['operational_inventory','operational_inventory_item'];
export const inventoryWrites={VEHICLE:'operational_vehicle_upsert',UNIT:'operational_unit_upsert',RESOURCE:'operational_resource_upsert'} as const;
export async function inventoryRpc<T>(name:string,args:Record<string,unknown>,account:string,signal?:AbortSignal):Promise<T>{
 const response=await fetch('/api/operational-inventory',{method:'POST',headers:{'Content-Type':'application/json','X-Gasilko-Account':account},body:JSON.stringify({name,args}),signal,cache:'no-store'});
 const result=await response.json();if(!response.ok)throw new Error(result.error??'SERVER');return result.data as T;
}
