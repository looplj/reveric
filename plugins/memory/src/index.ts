import type {PluginSetup,JsonObject} from '../../sdk/index';
import {create,update,search,prompt,categories} from './data';
import {organize} from './organize';
const scope={type:'string',enum:['current','global'],description:'默认当前作品；写全局记忆必须显式选择 global。'};
const fields={
  scope,
  content:{type:'string',minLength:1,maxLength:4000,description:'需要长期保留的完整记忆。'},
  category:{type:'string',enum:[...categories],description:'fact 事实；preference 偏好；instruction 持续要求。'},
  priority:{type:'integer',enum:[0,1],description:'0 普通；1 核心，优先加入聊天参考。'},
  enabled:{type:'boolean',description:'是否加入后续聊天请求的参考。'},
};
const identity={id:{type:'string',description:'搜索结果中的记忆 ID。'},revision:{type:'integer',minimum:1,description:'搜索结果中的版本，修改冲突时重新搜索。'},scope};
export function apply(setup:PluginSetup) {
  setup.tools.register({name:'MemorySearch',description:'搜索当前作品和全局记忆，返回 items（含 id、revision、scope 信息）和 hasMore。',inputSchema:{type:'object',additionalProperties:false,properties:{query:{type:'string',maxLength:200,description:'内容包含的文本。'},category:{type:'string',enum:['',...categories]},scope:{type:'string',enum:['all','current','global'],description:'默认 all，表示全局与当前作品。'},limit:{type:'integer',minimum:1,maximum:50},offset:{type:'integer',minimum:0}}},display:{result:'items',resultPath:'items'},handler:async(input,context)=>await search(context.sqlite,context.request.workId,input) as unknown as JsonObject});
  setup.tools.register({name:'MemoryCreate',description:'创建供后续聊天参考的记忆，返回新记忆及 revision。',inputSchema:{type:'object',additionalProperties:false,required:['content','category'],properties:fields},display:{result:'json'},handler:async(input,context)=>await create(context.sqlite,context.request.workId,input) as unknown as JsonObject});
  setup.tools.register({name:'MemoryUpdate',description:'修改一条记忆，返回更新后的记忆及 revision；版本已改变时返回冲突。',inputSchema:{type:'object',additionalProperties:false,required:['id','revision'],properties:{...fields,...identity}},display:{result:'json'},handler:async(input,context)=>await update(context.sqlite,context.request.workId,input) as unknown as JsonObject});
  setup.tools.register({name:'MemoryRemove',description:'移除一条记忆，使其不再出现在搜索和后续聊天参考中；版本已改变时返回冲突。',inputSchema:{type:'object',additionalProperties:false,required:['id','revision'],properties:identity},display:{result:'json'},handler:async(input,context)=>await update(context.sqlite,context.request.workId,input,true) as unknown as JsonObject});
  setup.prompts.context({id:'memory',handler:async context=>(await prompt(context.sqlite,context.request.workId)).text||null});
  setup.tasks.register('organize',organize);
}
