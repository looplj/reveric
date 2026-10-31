import {PluginError, type PluginSqlite, type JsonObject} from '../../sdk/index';
export const categories = ['fact', 'preference', 'instruction'] as const;
export type Scope = 'current' | 'global' | 'all';
export interface Memory {id:string;work_id:string|null;content:string;category:string;priority:number;enabled:number;revision:number;created_at:number;updated_at:number;deleted_at:number|null}
export function fail(code:string,message:string):never {throw new PluginError(code,message);}
export function scopeWork(workId:string|null,scope:unknown):string|null {
  if(scope==='global') return null;
  if(scope!==undefined && scope!=='current') fail('invalid_argument','scope must be current or global');
  if(!workId) fail('invalid_argument','Choose global explicitly outside a work');
  return workId;
}
export function checked(input:JsonObject) {
  const {content,category}=input,priority=input.priority??0,enabled=input.enabled??true;
  if(typeof content!=='string'||!content.trim()||content.length>4000) fail('invalid_argument','content must contain 1–4000 characters');
  if(!categories.includes(category as typeof categories[number])) fail('invalid_argument','Invalid category');
  if(priority!==0&&priority!==1) fail('invalid_argument','priority must be 0 or 1');
  if(typeof enabled!=='boolean') fail('invalid_argument','enabled must be boolean');
  return {content:content.trim(),category:category as string,priority:priority as number,enabled:enabled?1:0};
}
export function id() {return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;}
export const now=()=>Math.floor(Date.now()/1000);
export async function search(db:PluginSqlite,workId:string|null,input:JsonObject={}) {
  const scope=input.scope??'all',query=input.query??'',category=input.category??'',limit=input.limit??20,offset=input.offset??0;
  if(!['all','global','current'].includes(String(scope))||typeof query!=='string'||query.length>200||typeof category!=='string'||(category!==''&&!categories.includes(category as typeof categories[number]))||!Number.isInteger(limit)||Number(limit)<1||Number(limit)>50||!Number.isInteger(offset)||Number(offset)<0) fail('invalid_argument','Invalid search filters or pagination');
  const where=scope==='all'?'(work_id IS NULL OR work_id = ?)':'work_id IS ?';
  const selected=scope==='all'?workId:scopeWork(workId,scope);
  const rows=await db.query({sql:`SELECT * FROM memories WHERE deleted_at IS NULL AND ${where} AND (? = '' OR instr(lower(content),lower(?)) > 0) AND (? = '' OR category = ?) ORDER BY priority DESC, updated_at DESC, id LIMIT ? OFFSET ?`,params:[selected,query,query,category,category,Number(limit)+1,Number(offset)]});
  return {items:rows.slice(0,Number(limit)) as unknown as Memory[],hasMore:rows.length>Number(limit)};
}
export async function get(db:PluginSqlite,workId:string|null,memoryId:unknown) {
  if(typeof memoryId!=='string'||!memoryId) fail('invalid_argument','id is required');
  const rows=await db.query({sql:'SELECT * FROM memories WHERE id = ? AND deleted_at IS NULL AND (work_id IS NULL OR work_id = ?)',params:[memoryId,workId]});
  if(!rows.length) fail('not_found','Memory is not accessible in this scope');
  return rows[0] as unknown as Memory;
}
export async function create(db:PluginSqlite,workId:string|null,input:JsonObject) {
  const value=checked(input),scope=scopeWork(workId,input.scope),key=id(),time=now();
  await db.execute({sql:'INSERT INTO memories (id,work_id,content,category,priority,enabled,revision,created_at,updated_at) VALUES (?,?,?,?,?,?,1,?,?)',params:[key,scope,value.content,value.category,value.priority,value.enabled,time,time]});
  return get(db,workId,key);
}
export async function update(db:PluginSqlite,workId:string|null,input:JsonObject,remove=false) {
  const original=await get(db,workId,input.id);
  // Omitted scope means the record's own scope; an explicit one must match it.
  if(input.scope!==undefined&&scopeWork(workId,input.scope)!==original.work_id) fail('invalid_scope','scope does not match the memory');
  if(!Number.isInteger(input.revision)||Number(input.revision)<1) fail('invalid_argument','revision is required');
  const value=remove?original:checked({...original,enabled:original.enabled===1,...input});
  const result=await db.execute({sql:'UPDATE memories SET content = ?, category = ?, priority = ?, enabled = ?, revision = revision + 1, updated_at = ?, deleted_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND work_id IS ?',params:[value.content,value.category,value.priority,value.enabled,now(),remove?now():null,original.id,Number(input.revision),original.work_id]});
  if(result.changes!==1) fail('conflict','Memory changed; search again before editing');
  return remove?{id:original.id,deleted:true}:get(db,workId,original.id);
}
export async function prompt(db:Pick<PluginSqlite,'query'>,workId:string|null) {
  const rows=await db.query({sql:'SELECT id,content,category,priority FROM memories WHERE deleted_at IS NULL AND enabled = 1 AND (work_id IS NULL OR work_id = ?) ORDER BY priority DESC, updated_at DESC, id LIMIT 100',params:[workId]});
  // A conservative character budget keeps complete entries below the Host token budget.
  let text='';let count=0;
  for(const row of rows) {
    const entry=`- [${row.category}${row.priority===1?'; core':''}] ${row.content}\n`;
    if(text.length+entry.length>800) continue;
    text+=entry;count++;
  }
  return {text:text?`Memory references:\n${text}`:'',count,budget:800,used:text.length};
}
export async function suggestions(db:PluginSqlite,workId:string|null) {
  return db.query({sql:"SELECT s.*, m.work_id, m.content AS original, m.revision AS current_revision FROM suggestions s JOIN memories m ON m.id = s.memory_id WHERE s.status = 'pending' AND m.deleted_at IS NULL AND (m.work_id IS NULL OR m.work_id = ?) ORDER BY s.created_at, s.id LIMIT 50",params:[workId]});
}
export async function resolveSuggestion(db:PluginSqlite,workId:string|null,suggestionId:string,apply:boolean) {
  const rows=await db.query({sql:"SELECT s.*, m.work_id FROM suggestions s JOIN memories m ON m.id = s.memory_id WHERE s.id = ? AND s.status = 'pending' AND m.deleted_at IS NULL AND (m.work_id IS NULL OR m.work_id = ?)",params:[suggestionId,workId]});
  if(!rows.length) fail('not_found','Suggestion is no longer available');
  const suggestion=rows[0];
  if(apply) {
    checked({content:suggestion.content as string,category:suggestion.category as string});
    const result=await db.execute({sql:'UPDATE memories SET content = ?, category = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND work_id IS ?',params:[suggestion.content,suggestion.category,now(),suggestion.memory_id,suggestion.source_revision,suggestion.work_id]});
    if(result.changes!==1) fail('conflict','Source memory changed; ignore this suggestion and review the current version');
  }
  await db.execute({sql:"UPDATE suggestions SET status = ?, updated_at = ? WHERE id = ? AND status = 'pending'",params:[apply?'applied':'ignored',now(),suggestionId]});
}
