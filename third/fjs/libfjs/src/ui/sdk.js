const __n = globalThis.__revericNative;
globalThis.__revericAccessor = (id, generation) => () => __n.read(id, generation);
function signal(initial) {
  const [id, generation] = __n.signal(initial);
  const read = __revericAccessor(id, generation);
  read.set = value => __n.write(id, generation, value);
  read.update = fn => read.set(fn(read()));
  return read;
}
function computed(fn) { const [id, generation] = __n.computed(fn); return __revericAccessor(id, generation); }
// Effects, listeners and timers run later from native code, so each one
// captures the ErrorBoundary that was active when it was created.
let __boundary = null;
function __enter(boundary, fn, args) {
  const previous = __boundary; __boundary = boundary;
  try { return fn(...args); } finally { __boundary = previous; }
}
function __guard(fn) {
  const boundary = __boundary;
  return (...args) => {
    let result;
    try { result = __enter(boundary, fn, args); } catch (error) {
      if (!boundary) throw error;
      boundary(error); return undefined;
    }
    if (boundary && result && typeof result.then === 'function') { result.then(undefined, boundary); return undefined; }
    return result;
  };
}
function effect(fn) {
  const [id, generation] = __n.effect(__guard(() => { const result = fn(); if (result && typeof result.then === 'function') throw new Error('Use resource instead of async effect'); }));
  return () => __n.dispose(id, generation);
}
const cleanup = fn => __n.cleanup(fn);
const batch = fn => __n.scoped(fn, 'batch');
const untracked = fn => __n.scoped(fn, 'untracked');
function resource(source, load) {
  const value = signal(undefined), loading = signal(false), error = signal(undefined);
  const trigger = signal(0); let generation = 0, disposed = false;
  const stop = effect(() => {
    trigger(); const key = source(), revision = ++generation;
    batch(() => { loading.set(true); error.set(undefined); });
    Promise.resolve().then(() => load(key)).then(result => {
      if (!disposed && revision === generation) batch(() => { value.set(result); loading.set(false); });
    }, failure => {
      if (!disposed && revision === generation) batch(() => { error.set(failure); loading.set(false); });
    });
  });
  const dispose = () => { if (!disposed) { disposed = true; generation++; stop(); } };
  cleanup(dispose);
  return { value, loading, error, refetch: () => { if (!disposed) trigger.update(v => v + 1); }, dispose };
}
let __pageDisposed = false, __pageDispose = () => {};
globalThis.__revericDisposePage = () => { __pageDisposed = true; __pageDispose(); };
globalThis.__revericObserve = promise => Promise.resolve(promise).catch(error => {
  if (!__pageDisposed) __n.fail(String(error) + '\n' + String(error?.stack || ''));
});
function mount(view, root) {
  const [id, generation, node] = __n.root(() => view());
  __n.insert(root, node, 'children', null);
  let disposed = false;
  const dispose = () => { if (!disposed) { disposed = true; __n.dispose(id, generation); } };
  __pageDispose = dispose;
  return dispose;
}
// One signal per field: a resize must not re-run code that only reads visible.
const envFields = ['width','height','platform','theme','locale','visible'];
const env = Object.fromEntries(envFields.map(key => [key, signal(__revericEnvironment?.[key])]));
globalThis.__revericSetEnvironment = value => batch(() => { for (const key of envFields) env[key].set(value?.[key]); });
const call = (method, args) => __pageDisposed ? Promise.reject(new Error('Page closed')) : __n.call(method, args).catch(raw => {
  let failure;try {failure=JSON.parse(raw);}catch {throw raw;}
  const error=new Error(failure.message);error.name='PluginHostError';error.code=failure.code;throw error;
});
globalThis.__revericPageContext = Object.freeze({
  sqlite: __revericSqlite(call),
  root: __n.rootNode, page: Object.freeze(__revericScope.page), plugin: Object.freeze(__revericScope.plugin),
  environment: Object.freeze(Object.fromEntries(envFields.map(key => [key, () => env[key]()]))),
  log: Object.freeze(Object.fromEntries(['info','warn','error'].map(level=>[level,(message,data)=>{call('log.'+level,{message,data}).catch(()=>{});}]))),
  view: Object.freeze({ setDirty: value => call('view.setDirty', {value}) }),
  storage: Object.freeze({get: key => call('storage.get', {key}), set: (key,value) => call('storage.set', {key,value}), remove:key => call('storage.remove',{key})}),
  settings: Object.freeze({get:key => call('settings.get',{key})}),
  secrets: Object.freeze({get:key => call('secrets.get',{key})}),
  http: Object.freeze({fetch:(url,init={}) => call('http.fetch',{...init,url})}),
  ai: Object.freeze({listModels: () => call('ai.listModels', {}), generateText: input => call('ai.generateText', input)}),
  ...Object.fromEntries(['chapters','characters'].map(resource=>[resource,Object.freeze(Object.fromEntries(['list','get','update'].map(method=>[method,args=>call(resource+'.'+method,args||{})])))])),
  ui: Object.freeze(Object.fromEntries(['toast','dialog','navigate'].map(method=>[method,args=>call('ui.'+method,args)]))),
});
globalThis.__revericUi = {signal,computed,effect,batch,untracked,cleanup,resource,mount};
function component(fn, props) {
  const [id,generation,node] = __n.root(() => untracked(() => fn(props)));
  cleanup(() => __n.dispose(id,generation));
  return node;
}
const __unsent = Symbol('unsent');
function element(name, props = {}) {
  const node = __n.create(name);
  cleanup(() => __n.release(node));
  const slots = __revericComponentSlots[name];
  for (const key of Object.keys(props)) {
    const descriptor = Object.getOwnPropertyDescriptor(props,key);
    // The user may have edited a text value since it was last sent. Its
    // correction must reach the host even when the normalized value is equal.
    const textField = name === 'TextField' || name === 'SearchField';
    const textValue = key === 'value' && textField;
    // A stable trampoline means swapping handlers never re-registers natively.
    let last = __unsent, handler = null, bound = false;
    const apply = () => {
      const value = props[key];
      const slot=key==='children' ? (__revericChildrenSlot[name] ?? key) : key;
      if (slots.includes(slot)) {
        const children = value == null ? [] : Array.isArray(value) ? value : [value];
        __n.replaceSlot(node,slot,children);
      } else if (key.startsWith('on') || key === 'viewport') {
        handler = value ?? null;
        if (Boolean(handler) !== bound) {
          bound = Boolean(handler);
          // editRevision only syncs text with the host; plugins see {value}.
          __n.listen(node,key,bound ? __guard(payload => handler(textField ? {value: payload.value} : payload)) : null);
        }
      } else if (textValue || !Object.is(last, value)) {
        last = value;
        __n.set(node,{[key]:value});
      }
    };
    if (descriptor.get) effect(apply); else apply();
  }
  return node;
}
function Each(props) {
  const node = element('Fragment');
  cleanup(() => __n.clearEach(node));
  effect(() => __n.each(node,props.items,props.key,props.children,0));
  return node;
}
function If(props) {
  return Each({get items(){return [Boolean(props.when)];},key:value=>String(value),
    children:value=> value() ? props.children : (props.fallback ?? element('Fragment'))});
}
function List(props) {
  const viewport = signal({first:0,count:0});
  const bound={get itemCount(){return props.items.length;},get firstIndex(){return viewport().first;},
    viewport:event=>viewport.set(event)};
  // Common props such as flex and testId pass through to the host element.
  for (const key of Object.keys(props)) if (!['items','key','renderItem'].includes(key)) Object.defineProperty(bound,key,Object.getOwnPropertyDescriptor(props,key));
  const node = element('List',bound);
  cleanup(() => __n.clearEach(node));
  effect(() => {const {first,count}=viewport(); __n.each(node,props.items.slice(first,first+count),props.key,props.renderItem,first);});
  return node;
}
function ErrorBoundary(props) {
  const node = element('Fragment'), failure = signal(undefined), parent = __boundary;
  const reset = () => failure.set(undefined);
  effect(() => {
    const current = failure();
    untracked(() => {
      let child;
      if (current) child = __enter(parent, props.fallback, [current.error, reset]);
      else {
        // Errors from a torn-down attempt must not fail its replacement.
        let live = true; cleanup(() => { live = false; });
        const report = error => { if (live) { live = false; failure.set({error}); } };
        try { child = __enter(report, () => props.children, []); } catch (error) { report(error); child = element('Fragment'); }
      }
      __n.replaceSlot(node, 'children', Array.isArray(child) ? child : [child]);
    });
  });
  return node;
}
Object.assign(__revericUi,{element,component,Each,If,List,ErrorBoundary});

function __revericTimer(fn, delay, repeat, args) {
  const id=__n.timer(__guard(()=>fn(...args)), Number(delay||0),repeat);
  return id;
}
globalThis.setTimeout=(fn,delay=0,...args)=>__revericTimer(fn,delay,false,args);
globalThis.setInterval=(fn,delay=0,...args)=>__revericTimer(fn,delay,true,args);
globalThis.clearTimeout=globalThis.clearInterval=id=>__n.clearTimer(id);

function Tabs(props) {
  const bound={};
  for (const key of Object.keys(props)) if (key!=='children') Object.defineProperty(bound,key,Object.getOwnPropertyDescriptor(props,key));
  Object.defineProperty(bound,'content',{enumerable:true,get(){const render=props.children;return render?render(props.value):element('Fragment');}});
  return element('Tabs',bound);
}
__revericUi.Tabs=Tabs;
