import {test} from 'node:test';
import assert from 'node:assert/strict';
import {transformTsx,tsxPlugin} from './tsx_transform.mjs';
import {build} from 'esbuild';
import vm from 'node:vm';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const here=dirname(fileURLToPath(import.meta.url));
const file=resolve(here,'transform-fixture.tsx');
async function compile(source,ui){
  const transformed=transformTsx(source,file);
  const result=await build({stdin:{contents:transformed.javascript,resolveDir:here,loader:'js',sourcefile:file},write:false,bundle:true,format:'iife',globalName:'view',plugins:[tsxPlugin()]});
  const scope={__revericUi:ui};vm.runInNewContext(result.outputFiles[0].text,scope);
  return {exports:scope.view,map:transformed.map,code:result.outputFiles[0].text};
}
function runtime(){
  return {signal(initial){let value=initial;const read=()=>value;read.set=next=>value=next;return read;},
    component(fn,props){return fn(props);},element(type,props){return {type,props};}};
}
test('keeps dynamic props as getters and event callbacks uncalled',async()=>{
  const {exports,map}=await compile(`import {signal,Text as Label,Button,Column} from 'reveric/ui';
    export const count=signal(0); export let clicks=0;
    export function page(){return <Column><Label text={String(count())}/><Button label="Run" onPress={()=>{clicks++;}}/></Column>;}`,runtime());
  const node=exports.page();let children=node.props.children;
  assert.equal(children[0].type,'Text');assert.equal(children[0].props.text,'0');
  exports.count.set(2);assert.equal(children[0].props.text,'2');
  assert.equal(exports.clicks,0);children[1].props.onPress({});assert.equal(exports.clicks,1);
  assert.ok(map.sourcesContent[0].includes('<Label'));
});
test('built-in components create host elements without a component root',()=>{
  const {javascript}=transformTsx(`import {Text as Label,If,signal} from 'reveric/ui';const show=signal(true);
    export const page=()=> <If when={show()}><Label text="x"/></If>;`,file);
  assert.match(javascript,/element\("Text"/);
  assert.match(javascript,/component\(If,/);
  assert.doesNotMatch(javascript,/component\(Label/);
});
test('preserves local components and lexical shadowing',async()=>{
  const {exports}=await compile(`import {Text, type TextProps, type UiNode} from 'reveric/ui';
    export function page(Text:(props:TextProps)=>UiNode){return <Text text="local"/>;}`,runtime());
  const node=exports.page(props=>({type:'custom',props}));assert.equal(node.type,'custom');
});
test('conditional children are constructed lazily',async()=>{
  let created=0;const ui=runtime();const element=ui.element;ui.element=(type,props)=>{created++;return element(type,props);};
  const {exports}=await compile(`import {signal,Column,Text} from 'reveric/ui';export const show=signal(false);
    export function page(){return <Column>{show()?<Text text="yes"/>:<Text text="no"/>}</Column>;}`,ui);
  const node=exports.page();assert.equal(created,1);assert.equal(node.props.children.props.text,'no');
  exports.show.set(true);assert.equal(node.props.children.props.text,'yes');
});
function reactiveRuntime(){
  let observer=null;const created=[];
  const effect=fn=>{const run=()=>{const previous=observer;observer=run;try{fn();}finally{observer=previous;}};run();};
  return {created,signal(initial){let value=initial;const subscribers=new Set();
      const read=()=>{if(observer) subscribers.add(observer);return value;};
      read.set=next=>{value=next;[...subscribers].forEach(run=>run());};return read;},
    component(fn,props){const previous=observer;observer=null;try{return fn(props);}finally{observer=previous;}},
    element(type,props){const node={type,props:{}};created.push(node);
      for(const key of Object.keys(props)){const descriptor=Object.getOwnPropertyDescriptor(props,key);
        if(descriptor.get) effect(()=>{node.props[key]=props[key];}); else node.props[key]=props[key];}
      return node;}};
}
test('dynamic children refresh only their own slot',async()=>{
  const ui=reactiveRuntime();
  const {exports}=await compile(`import {signal,Column,Text,TextField} from 'reveric/ui';export const show=signal(false);
    export function page(){return <Column><TextField value=""/>{show()?<Text text="yes"/>:<Text text="no"/>}<Text text="tail"/></Column>;}`,ui);
  const node=exports.page();const [field,slot,tail]=node.props.children;
  assert.equal(field.type,'TextField');assert.equal(slot.type,'Fragment');assert.equal(slot.props.children.props.text,'no');
  exports.show.set(true);
  assert.equal(slot.props.children.props.text,'yes');
  [field,slot,tail].forEach((child,index)=>assert.equal(node.props.children[index],child));
  assert.equal(ui.created.filter(item=>item.type==='TextField').length,1);
});
test('rejects unsupported or misspelled components at source location',()=>{
  assert.throws(()=>transformTsx('export const page=()=> <div/>;',file),/div|PascalCase/);
  assert.throws(()=>transformTsx(`import {Text} from 'reveric/ui'; export const page=()=> <Text text={42}/>;`,file),/number.*string|Type.*number/s);
});
