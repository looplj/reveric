// 职责: 生成插件注册、分阶段上下文、结果校验与 JSON 桥接的受限运行脚本。
// 关联文件:
//   lib/shared/services/plugins/runtime.dart
//   lib/shared/services/plugins/host.dart
//   plugins/sdk/index.d.ts
import 'dart:convert';
import 'sql_bridge.dart';

/// 插件代码之前执行：只提供注册与日志，处理函数在调用阶段拿到各自的上下文。
String pluginPrelude(String id, String version) =>
    pluginSqliteBridge +
    r'''
const __tools = Object.create(null);
const __tasks = Object.create(null);
const __prompts = Object.create(null);
const __views = Object.create(null);
const __actions = Object.create(null);
const __definitions = [];
const __actionNames = [];
let __registering = true;
let __registrationError = null;
class PluginHostError extends Error {
  constructor(code, message) { super(message); this.name = "PluginHostError"; this.code = code; }
}
async function __bridge(message) {
  const reply = JSON.parse(await fjs.bridge_call(JSON.stringify(message)));
  if (!reply.ok) throw new PluginHostError(reply.code, reply.error);
  return reply.result;
}
function __call(method, args) {
  if (__registering) return Promise.reject(new Error('Host API unavailable during apply'));
  return __bridge({kind:'call', method, args});
}
const __plugin = Object.freeze(__IDENTITY__);
const __log = Object.freeze(Object.fromEntries(['info','warn','error'].map(level => [level, (message, data) => {
  __bridge({kind:'log', level, message: String(message), data: data === undefined ? null : data}).catch(() => {});
}])));
function __reject(message) {
  __registrationError ??= message;
  throw new Error(message);
}
function __open() {
  if (!__registering) throw new Error('Registration is closed');
}
function __take(value, key, table, label) {
  __open();
  if (!value || typeof value[key] !== 'string' || typeof value.handler !== 'function' || table[value[key]]) {
    __reject('Invalid or duplicate ' + label);
  }
  const {handler, ...definition} = value;
  table[value[key]] = handler;
  return definition;
}
const __setup = Object.freeze({
  plugin: __plugin,
  log: __log,
  tools: Object.freeze({register(tool) {
    if (tool && typeof tool === 'object' && 'kind' in tool) __reject('Reserved tool property: kind');
    __definitions.push(__take(tool, 'name', __tools, 'tool'));
  }}),
  prompts: Object.freeze({
    context(provider) {
      __definitions.push({kind:'prompt', prompt:__take(provider, 'id', __prompts, 'prompt provider')});
    },
    system(provider) {
      __definitions.push({kind:'systemPrompt', systemPrompt:__take(provider, 'id', __prompts, 'prompt provider')});
    },
  }),
  tasks: Object.freeze({register(id, handler) {
    __definitions.push({kind:'task', task:__take({id, handler}, 'id', __tasks, 'task')});
  }}),
  pages: Object.freeze({registerAction(id, name, handler) {
    __open();
    if (typeof id !== 'string' || typeof name !== 'string' || typeof handler !== 'function') __reject('Invalid page action');
    const actions = __views[id] ??= Object.create(null);
    if (actions[name]) __reject('Duplicate page action');
    actions[name] = handler;
    __definitions.push({kind:'pageAction', pageId:id, name});
  }}),
  settings: Object.freeze({registerAction(name, handler) {
    __open();
    if (typeof name !== 'string' || typeof handler !== 'function' || __actions[name]) __reject('Invalid or duplicate action');
    __actions[name] = handler;
    __actionNames.push(name);
  }}),
});
// 每次调用都向宿主上报完整注册，宿主校验通过后才能调用业务 API。
async function __apply() {
  try {
    if (typeof __revericPlugin?.apply !== 'function') throw new Error('Missing apply');
    await __revericPlugin.apply(__setup);
    if (__registrationError) throw new Error(__registrationError);
  } finally { __registering = false; }
  const definitions = JSON.parse(JSON.stringify(__definitions));
  await __bridge({kind:'register', definitions, actions:__actionNames.slice()});
}
async function __handler(table, key, label) {
  const handler = table[key];
  if (typeof handler !== 'function') {
    await __bridge({kind:'mismatch', message: label + ' is not registered: ' + key});
  }
  return handler;
}
const __http = Object.freeze({fetch(url, init = {}) {return __call('http.fetch', {...init, url});}});
const __storage = Object.freeze({get(key) {return __call('storage.get', {key});}, set(key, value) {return __call('storage.set', {key, value});}, remove(key) {return __call('storage.remove', {key});}});
const __settings = Object.freeze({get(key) {return __call('settings.get', {key});}});
const __secrets = Object.freeze({get(key) {return __call('secrets.get', {key});}});
const __sqlite = __revericSqlite(__call);
const __services = Object.freeze({plugin:__plugin, log:__log, http:__http, storage:__storage, settings:__settings, secrets:__secrets, sqlite:__sqlite});
const __workData = Object.freeze(Object.fromEntries(['chapters','characters'].map(resource => [resource, Object.freeze(Object.fromEntries(['list','get','update'].map(operation => [operation, (input = {}) => __call(resource + '.' + operation, input)])))])));
function __context(extra) { return Object.freeze({...__services, ...extra}); }
function __jsonError(value, path) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return null;
  if (typeof value === 'number') return Number.isFinite(value) ? null : path + ' is a non-finite number';
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) {
      const error = __jsonError(value[i], path + '[' + i + ']');
      if (error) return error;
    }
    return null;
  }
  if (typeof value === 'object') {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      return path + ' is ' + (value.constructor?.name || 'a non-plain object') + ', not JSON';
    }
    for (const key of Object.keys(value)) {
      if (value[key] === undefined) continue;
      const error = __jsonError(value[key], path + '.' + key);
      if (error) return error;
    }
    return null;
  }
  return path + ' is ' + typeof value + ', not JSON';
}
async function __finish(run) {
  let outcome;
  try { outcome = {value: await run()}; } catch (error) { outcome = {error}; }
  let message;
  if ('error' in outcome) {
    const error = outcome.error;
    message = {kind:'result', error:String(error) + '\n' + String(error?.stack || ''),
      code: typeof error?.code === 'string' ? error.code : null,
      message: typeof error?.message === 'string' ? error.message : String(error)};
  } else {
    const invalid = __jsonError(outcome.value, '$');
    message = invalid ? {kind:'result', invalid} : {kind:'result', value:outcome.value};
  }
  await __bridge(message).catch(() => {});
}
'''
        .replaceFirst(
          '__IDENTITY__',
          jsonEncode({'id': id, 'version': version}),
        );

String pluginActivate() =>
    'await __finish(async () => { await __apply(); return {}; });';

String pluginInvokeAction(String action, String callId) =>
    '''
await __finish(async () => {
  await __apply();
  const handler = await __handler(__actions, ${jsonEncode(action)}, 'Action');
  return handler(__context({callId:${jsonEncode(callId)}}));
});
''';

String pluginInvoke(
  String tool,
  Map<String, dynamic> input,
  String callId,
  Map<String, dynamic> request,
) =>
    '''
await __finish(async () => {
  await __apply();
  const handler = await __handler(__tools, ${jsonEncode(tool)}, 'Tool');
  return handler(${jsonEncode(input)}, __context({...__workData, callId:${jsonEncode(callId)}, request:Object.freeze(${jsonEncode(request)})}));
});
''';

String pluginInvokeViewAction(
  String viewId,
  String action,
  Map<String, dynamic> input,
) =>
    '''
await __finish(async () => {
  await __apply();
  const input = ${jsonEncode(input)};
  const handler = await __handler(__views[${jsonEncode(viewId)}] ?? {}, ${jsonEncode(action)}, 'View action');
  const ui = Object.freeze(Object.fromEntries(['toast','dialog','navigate'].map(method => [method, args => __call('ui.' + method, args)])));
  const view = Object.freeze({setDirty(value) { return __call('view.setDirty', {value}); }});
  return {messages: await handler(input.data, input.event, __context({...__workData, page:Object.freeze(input.page), ui, view}))};
});
''';

String pluginInvokePrompt(String providerId, Map<String, dynamic> request) =>
    '''
await __finish(async () => {
  await __apply();
  const handler = await __handler(__prompts, ${jsonEncode(providerId)}, 'Prompt provider');
  const text = await handler(Object.freeze({plugin:__plugin, log:__log, request:Object.freeze(${jsonEncode(request)}),
    sqlite:Object.freeze({query:__sqlite.query}), storage:Object.freeze({get:__storage.get}), settings:__settings}));
  return {text};
});
''';

String pluginInvokeTask(String taskId, Map<String, dynamic> run) =>
    '''
await __finish(async () => {
  await __apply();
  const handler = await __handler(__tasks, ${jsonEncode(taskId)}, 'Task');
  const ai = Object.freeze({generateText(input) {return __call('ai.generateText', input);}});
  const result = await handler(__context({...${jsonEncode(run)}, ai}));
  if (result !== undefined && (result === null || typeof result !== 'object' || Array.isArray(result))) {
    throw new Error('Task must return a summary object or void');
  }
  return {summary: result?.summary ?? null};
});
''';
