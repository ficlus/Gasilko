import 'server-only';
import {fork} from 'node:child_process';
import path from 'node:path';
import type {Cell} from './model';
let running=0;
export async function spreadsheet<T>(message:Record<string,unknown>):Promise<T>{
 if(running>=2)throw Error('BUSY');running++;
 try{return await new Promise<T>((resolve,reject)=>{
  const child=fork(path.join(process.cwd(),'scripts','spreadsheet.cjs'),[],{env:{},execArgv:['--max-old-space-size=256'],stdio:['ignore','ignore','ignore','ipc'],windowsHide:true});
  let settled=false;const finish=(error?:Error,result?:T)=>{if(settled)return;settled=true;clearTimeout(timer);child.kill();error?reject(error):resolve(result!);};
  const timer=setTimeout(()=>finish(Error('LIMIT_EXCEEDED')),30000);
  child.once('error',()=>finish(Error('INVALID_FILE')));child.once('exit',()=>finish(Error('INVALID_FILE')));
  child.once('message',(m:unknown)=>{const reply=m as {error?:string;result?:T};finish(reply.error?Error(reply.error):undefined,reply.result);});child.send(message);
 });}finally{running--;}
}
export async function boundedBody(request:Request,max:number){
 if(Number(request.headers.get('content-length')??0)>max)throw Error('LIMIT_EXCEEDED');
 const reader=request.body?.getReader();if(!reader)throw Error('INVALID_FILE');const chunks:Uint8Array[]=[];let size=0;
 try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>max)throw Error('LIMIT_EXCEEDED');chunks.push(value);}}finally{await reader.cancel();}
 return Buffer.concat(chunks);
}
export type Parsed={sheets:string[];sheet?:string;delimiter?:string;rows:Cell[][]|null};
