import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import {create,update,search,prompt,resolveSuggestion,suggestions} from '../src/data';
import {organize} from '../src/organize';
import type {PluginSqlite,TaskContext,Json} from '../../sdk/index';
function fixture(settings:Record<string,Json>={}) {
 const raw=new DatabaseSync(':memory:');
 raw.exec(readFileSync('memory/migrations/001.sql','utf8'));
 const sqlite:PluginSqlite={
  async query({sql,params=[]}){return raw.prepare(sql).all(...params) as never;},
  async execute({sql,params=[]}){const result=raw.prepare(sql).run(...params);return {changes:Number(result.changes),lastInsertRowId:BigInt(result.lastInsertRowid)};},
  async transaction(statements){raw.exec('BEGIN');try{const result=[];for(const s of statements) result.push(await sqlite.execute(s));raw.exec('COMMIT');return result;}catch(e){raw.exec('ROLLBACK');throw e;}},
 };
 const storage=new Map<string,Json>();
 let calls=0;
 const models:unknown[]=[];
 const context={runId:'run',trigger:'manual',scheduledAt:1,sqlite,storage:{get:async(k:string)=>storage.get(k)??null,set:async(k:string,v:Json)=>{storage.set(k,v);}},settings:{get:async(k:string)=>settings[k]??null},ai:{generateText:async({prompt,providerId,model}:{prompt:string,providerId?:string,model?:string})=>{calls++;models.push(providerId===undefined?null:{providerId,model});return {text:JSON.stringify(JSON.parse(prompt).map((r:Record<string,unknown>)=>({...r,content:'Refined '+r.content})))}}}} as unknown as TaskContext;
 return {raw,sqlite,context,models,get calls(){return calls;}};
}
test('scope, optimistic updates, disable/remove and prompt share committed data',async()=>{
 const f=fixture();try{
  await assert.rejects(create(f.sqlite,null,{content:'x',category:'fact'}),/global explicitly/);
  const global=await create(f.sqlite,'a',{scope:'global',content:'Global fact',category:'fact',priority:1});
  const local=await create(f.sqlite,'a',{content:'Chinese 中文',category:'preference'});
  await create(f.sqlite,'b',{content:'Other work',category:'fact'});
  assert.equal((await search(f.sqlite,'a')).items.length,2);
  assert.equal((await search(f.sqlite,'a',{query:'中文'})).items[0].id,local.id);
  await assert.rejects(update(f.sqlite,'b',{id:local.id,revision:1,content:'bad'}),/not accessible/);
  await assert.rejects(update(f.sqlite,'a',{id:global.id,revision:1,scope:'current',content:'bad'}),(error:{code?:string})=>error.code==='invalid_scope');
  await update(f.sqlite,'a',{id:global.id,revision:1,content:'Global fact'});
  const first=await prompt(f.sqlite,'a');assert.match(first.text,/Global fact/);assert.match(first.text,/中文/);assert.doesNotMatch(first.text,/Other work/);
  await update(f.sqlite,'a',{id:local.id,revision:1,enabled:false});
  await assert.rejects(update(f.sqlite,'a',{id:local.id,revision:1,content:'stale'}),/changed/);
  assert.doesNotMatch((await prompt(f.sqlite,'a')).text,/中文/);
  await update(f.sqlite,'a',{id:global.id,revision:2,scope:'global'},true);
  assert.equal((await prompt(f.sqlite,'a')).text,'');
  assert.equal(rawCount(f.raw,'memories'),3);
 }finally{f.raw.close();}
});
function rawCount(db:DatabaseSync,table:string){return Number(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get()!.n);}
test('organize rotates scopes, persists candidates idempotently and revision-gates application',async()=>{
 const f=fixture();try{
  const a=await create(f.sqlite,'a',{content:'Original a',category:'fact'});
  await create(f.sqlite,'b',{content:'Original b',category:'fact'});
  await organize(f.context);await organize(f.context);await organize(f.context);
  assert.equal(f.calls,2);assert.equal(rawCount(f.raw,'suggestions'),2);
  const found=await suggestions(f.sqlite,'a');assert.equal(found.length,1);
  assert.equal((await search(f.sqlite,'a')).items[0].content,'Original a');
  await resolveSuggestion(f.sqlite,'a',String(found[0].id),true);
  assert.equal((await search(f.sqlite,'a')).items[0].content,'Refined Original a');
  await assert.rejects(resolveSuggestion(f.sqlite,'a',String(found[0].id),true),/no longer/);
  // Simulate a crash after memory update but before candidate status update.
  f.raw.prepare("UPDATE suggestions SET status = 'pending' WHERE id = ?").run(String(found[0].id));
  await assert.rejects(resolveSuggestion(f.sqlite,'a',String(found[0].id),true),/changed/);
  await resolveSuggestion(f.sqlite,'a',String(found[0].id),false);
  assert.equal((await search(f.sqlite,'a')).items[0].revision,a.revision+1);
 }finally{f.raw.close();}
});
test('full-entry prompt budget and twenty-memory task batch',async()=>{
 const f=fixture();try{
  for(let i=0;i<25;i++) await create(f.sqlite,'a',{content:`记忆${i}`+'中'.repeat(100),category:'fact'});
  const view=await prompt(f.sqlite,'a');assert.ok(view.used<=800);assert.ok(view.count>0&&view.count<25);
  await organize(f.context);assert.equal(rawCount(f.raw,'suggestions'),20);
  await organize(f.context);assert.equal(rawCount(f.raw,'suggestions'),25);
  await organize(f.context);assert.equal(f.calls,2);
 }finally{f.raw.close();}
});
test('organize uses the configured model, else the default chat model',async()=>{
 const chosen=fixture({organizeModel:{providerId:'openai',model:'gpt-5'}});
 const fallback=fixture();
 try{
  await create(chosen.sqlite,'a',{content:'Original',category:'fact'});
  await create(fallback.sqlite,'a',{content:'Original',category:'fact'});
  await organize(chosen.context);await organize(fallback.context);
  assert.deepEqual(chosen.models,[{providerId:'openai',model:'gpt-5'}]);
  assert.deepEqual(fallback.models,[null]);
 }finally{chosen.raw.close();fallback.raw.close();}
});
