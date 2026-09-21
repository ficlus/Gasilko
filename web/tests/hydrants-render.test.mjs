import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { RegistryController } from '../lib/hydrants/controller.ts';
// Execute the actual TSX with existing dependencies; no component source assertions.
registerHooks({
  resolve(specifier, context, next) {
    if(specifier==='next/link')return next('next/link.js',context);
    if(specifier==='next/navigation')return next('next/navigation.js',context);
    try{return next(specifier,context)}catch(error){
      if(specifier.startsWith('.'))for(const suffix of ['.ts','.tsx'])try{return next(specifier+suffix,context)}catch{ /* Try the next source extension. */ }
      throw error;
    }
  },
  load(url,context,next) {
    if(url.endsWith('.tsx'))return {format:'module',shortCircuit:true,source:ts.transpileModule(readFileSync(new URL(url),'utf8'),{compilerOptions:{jsx:ts.JsxEmit.ReactJSX,module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText};
    if(url.endsWith('.json')&&url.includes('/messages/'))return {format:'module',shortCircuit:true,source:'export default '+readFileSync(new URL(url),'utf8')};
    return next(url,context);
  }
});
const {RegistryView}=await import('../features/hydrants/Registry.tsx');
const h={id:'h',organization_id:'a',code:'A-H-000001',hydrant_type_id:'type',status:'WORKING',latitude:null,longitude:null,address:'Street',location_description:null,notes:null,inspection_interval_months:null,active:true,version:2,created_by:'u'};
async function render(role,mode='detail',locale='sl',mutate=()=>{}) {
 const service={organizations:async()=>[{id:'a',name:'Station A',active:true,role}],types:async()=>[{id:'type',name:'Custom hydrant',code:'CUSTOM',active:true,organization_id:'a'}],get:async()=>h,list:async()=>[h]};
 const c=new RegistryController(service,mode,mode==='detail'||mode==='edit'?'h':undefined);await c.load();await mutate(c);
 return renderToStaticMarkup(React.createElement(RegistryView,{locale,controller:c}));
}
test('rendered firefighter details hide master edit and activation, show status form',async()=>{const html=await render('FIREFIGHTER');assert.ok(html.includes('Deluje'));assert.ok(html.includes('Shrani'));assert.ok(!html.includes('Deaktiviraj'));assert.ok(!html.includes('/edit'));assert.ok(html.includes('A-H-000001'))});
for(const role of ['MANAGER','ADMIN'])test('rendered '+role+' has edit and deactivate controls',async()=>{const html=await render(role);assert.ok(html.includes('/edit?org=a'));assert.ok(html.includes('Deaktiviraj'))});
test('rendered German detail uses localized statuses and actions',async()=>{const html=await render('MANAGER','detail','de');assert.ok(html.includes('Funktionsfähig'));assert.ok(html.includes('Deaktivieren'));assert.ok(!html.includes('>WORKING<'));assert.ok(html.includes('Keine Angabe'))});
test('rendered create form has dynamic type, labels and no editable identity',async()=>{const html=await render('FIREFIGHTER','new');assert.ok(html.includes('Custom hydrant'));assert.ok(html.includes('for="hydrant-latitude"'));assert.ok(html.includes('for="hydrant-type"'));assert.ok(!html.includes('hydrant-code'));assert.ok(!html.includes('expected_version'))});
test('rendered firefighter direct edit route has safe error and no form',async()=>{const html=await render('FIREFIGHTER','edit');assert.ok(html.includes('role="alert"'));assert.ok(!html.includes('<form'))});
test('rendered manager confirmation is labeled and cancel receives focus',async()=>{const html=await render('MANAGER','detail','sl',c=>c.requestActive());assert.ok(html.includes('<dialog'));assert.ok(html.includes('aria-labelledby="deactivate-heading"'));assert.ok(html.includes('autofocus=""'));assert.ok(html.includes('Prekliči'))});
test('rendered registry table has caption, headers, organization and scoped links',async()=>{const html=await render('MANAGER','list');assert.ok(html.includes('<caption>Station A'));assert.ok(html.includes('scope="col"'));assert.ok(html.includes('scope="row"'));assert.ok(html.includes('/h?org=a'));assert.ok(html.includes('Samo neaktivni'))});
test('rendered firefighter search exposes no inactive filter and submits explicitly',async()=>{const html=await render('FIREFIGHTER','list');assert.ok(html.includes('method="get"'));assert.ok(html.includes('name="q"'));assert.ok(html.includes('name="type"'));assert.ok(html.includes('name="status"'));assert.ok(!html.includes('name="active"'));assert.ok(!html.includes('name="after"'))});
