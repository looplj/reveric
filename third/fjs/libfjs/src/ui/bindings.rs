//! Synchronous QuickJS adapter for the pinned nsh reactive graph.
//! No graph borrow survives a call into JS. State is context userdata, not opaque.
use super::nodes;
use super::reactive::{self as r, Equals, Host, Kind};
use crate::api::ui::{UiEvent, UiOp, UiOutput, UiValue};
use rquickjs::{
    Class, Ctx, Error, FromJs, Function, JsLifetime, Object, Result, Value, class::Trace,
    function::Func, qjs,
};
use std::{cell::UnsafeCell, collections::HashMap, rc::Rc};

type Raw = qjs::JSValue;
#[derive(Clone, Copy)]
pub(crate) struct Js(pub *mut State);
pub(crate) struct GraphData {
    pub ctx: *mut qjs::JSContext,
    pub error: Option<Raw>,
}
pub(crate) struct State {
    pub graph: r::Graph<Js>,
    pub closing: bool,
    pub tree: nodes::Tree,
    pub calls: HashMap<u64, (Raw, Raw)>,
    pub next_call: u64,
    pub outbox: Vec<UiOutput>,
    pub fatal: Option<String>,
    pub rejections: HashMap<usize, (Raw, Raw)>,
    pub rows: HashMap<u64, HashMap<String, EachRow>>,
    pub timers: HashMap<u64, UiTimer>,
    pub next_timer: u64,
    pub paused: bool,
}

// SAFETY: these handles are accessed only by the owning context's dedicated
// thread. Every generic graph operation uses short non-overlapping borrows.
unsafe impl Host for Js {
    type Value = Raw;
    type Func = Raw;
    type Equals = Raw;
    type Cleanup = Raw;
    type Context = ();
    type Data = GraphData;
    unsafe fn graph<'a>(self) -> &'a mut r::Graph<Self> {
        // SAFETY: the caller guarantees exclusive short graph access.
        unsafe { &mut (*self.0).graph }
    }
    fn empty() -> Raw {
        qjs::JS_UNDEFINED
    }
    fn dup(self, value: &Raw) -> Raw {
        // SAFETY: the value and context are live on this thread.
        unsafe { qjs::JS_DupValue((*self.0).graph.data.ctx, *value) }
    }
    fn free(self, value: Raw) {
        // SAFETY: ownership of one live reference is transferred here.
        unsafe { qjs::JS_FreeValue((*self.0).graph.data.ctx, value) }
    }
    fn dup_func(self, value: &Raw) -> Raw {
        self.dup(value)
    }
    fn free_func(self, value: Raw) {
        self.free(value);
    }
    fn dup_equals(self, value: &Raw) -> Raw {
        self.dup(value)
    }
    fn free_equals(self, value: Raw) {
        self.free(value);
    }
    fn call(self, function: &Raw, previous: Raw) -> Option<Raw> {
        let result = self.invoke(*function, &mut [previous]);
        self.free(previous);
        result
    }
    fn same(self, a: &Raw, b: &Raw) -> bool {
        // SAFETY: strict equality cannot execute user code.
        unsafe { qjs::JS_IsStrictEqual((*self.0).graph.data.ctx, *a, *b) }
    }
    fn truthy(self, value: &Raw) -> bool {
        // SAFETY: boolean conversion does not execute user code.
        unsafe { qjs::JS_ToBool((*self.0).graph.data.ctx, *value) == 1 }
    }
    fn custom_changed(self, function: &Raw, previous: Raw, next: &Raw) -> bool {
        let next = self.dup(next);
        let result = self.invoke(*function, &mut [previous, next]);
        self.free(previous);
        self.free(next);
        result
            .map(|value| {
                let changed = !self.truthy(&value);
                self.free(value);
                changed
            })
            .unwrap_or(true)
    }
    fn run_cleanup(self, function: Raw) {
        if let Some(value) = self.invoke(function, &mut []) {
            self.free(value);
        }
        self.free(function);
    }
    fn free_cleanup(self, function: Raw) {
        self.free(function);
    }
    fn runaway(self) {
        // SAFETY: this creates an owned exception in the live context.
        unsafe {
            let ctx = (*self.0).graph.data.ctx;
            qjs::JS_ThrowInternalError(ctx, c"Reactive effect cycle exceeded budget".as_ptr());
            self.keep_error(qjs::JS_GetException(ctx));
        }
    }
}
impl Js {
    pub(crate) fn invoke(self, function: Raw, args: &mut [Raw]) -> Option<Raw> {
        // SAFETY: no graph reference is held during a reentrant JS call.
        unsafe {
            let ctx = (*self.0).graph.data.ctx;
            let value = qjs::JS_Call(
                ctx,
                function,
                qjs::JS_UNDEFINED,
                args.len() as i32,
                args.as_mut_ptr(),
            );
            if qjs::JS_IsException(value) {
                self.keep_error(qjs::JS_GetException(ctx));
                None
            } else {
                Some(value)
            }
        }
    }
    fn keep_error(self, value: Raw) {
        // SAFETY: replacing graph metadata holds no borrow during value release.
        let previous = unsafe { (*self.0).graph.data.error.replace(value) };
        if let Some(previous) = previous {
            self.free(previous);
        }
    }
}

#[derive(Clone)]
pub(crate) struct NativeState {
    pub inner: Rc<UnsafeCell<State>>,
}
// SAFETY: no Rust reference carrying a JS lifetime is stored in this handle;
// its raw JS references are traced and released before the context is dropped.
unsafe impl<'js> JsLifetime<'js> for NativeState {
    type Changed<'to> = NativeState;
}
unsafe extern "C" fn mark_state(rt: *mut qjs::JSRuntime, value: Raw, mark: qjs::JS_MarkFunc) {
    // SAFETY: this callback belongs only to our private class; opaque is one
    // live Rc allocation. The marker never allocates or changes refcounts.
    unsafe {
        let pointer =
            qjs::JS_GetOpaque(value, qjs::JS_GetClassID(value)).cast::<UnsafeCell<State>>();
        if pointer.is_null() {
            return;
        }
        let state = &*(*pointer).get();
        let visit = |value: &Raw| qjs::JS_MarkValue(rt, *value, mark);
        state.graph.visit_references(visit, visit, visit, visit);
        if let Some(error) = &state.graph.data.error {
            visit(error);
        }
        for listener in state.tree.listeners.values() {
            visit(&listener.function);
        }
        for (promise, reason) in state.rejections.values() {
            visit(promise);
            visit(reason);
        }
        for timer in state.timers.values() {
            visit(&timer.function);
        }
        for (resolve, reject) in state.calls.values() {
            visit(resolve);
            visit(reject);
        }
    }
}
unsafe extern "C" fn finalize_state(_rt: *mut qjs::JSRuntime, value: Raw) {
    // SAFETY: JS_SetOpaque transfers exactly one Rc strong reference to this
    // object. The context userdata retains its independent strong reference.
    unsafe {
        let pointer =
            qjs::JS_GetOpaque(value, qjs::JS_GetClassID(value)).cast::<UnsafeCell<State>>();
        if !pointer.is_null() {
            drop(Rc::from_raw(pointer));
        }
    }
}
fn install_gc_root(ctx: &Ctx<'_>, state: &NativeState) -> Result<()> {
    // SAFETY: one private class per dedicated runtime; this does not touch
    // QuickJS runtime/context opaque fields owned by rquickjs.
    unsafe {
        let runtime = qjs::JS_GetRuntime(ctx.as_raw().as_ptr());
        let mut id = 0;
        qjs::JS_NewClassID(runtime, &mut id);
        let definition = qjs::JSClassDef {
            class_name: c"RevericUiState".as_ptr(),
            finalizer: Some(finalize_state),
            gc_mark: Some(mark_state),
            call: None,
            exotic: std::ptr::null_mut(),
        };
        if qjs::JS_NewClass(runtime, id, &definition) < 0 {
            return Err(Error::Exception);
        }
        let value = qjs::JS_NewObjectClass(ctx.as_raw().as_ptr(), id);
        if qjs::JS_IsException(value) {
            return Err(Error::Exception);
        }
        qjs::JS_SetOpaque(value, Rc::into_raw(state.inner.clone()).cast_mut().cast());
        ctx.globals()
            .prop("__revericGcRoot", Value::from_raw(ctx.clone(), value))?;
    }
    Ok(())
}

pub(crate) fn state(ctx: &Ctx<'_>) -> Result<Js> {
    let value = ctx
        .userdata::<NativeState>()
        .ok_or_else(|| Error::new_from_js_message("Context", "UI", "Native UI state missing"))?;
    Ok(Js(value.inner.get()))
}
pub(crate) fn finish(ctx: &Ctx<'_>, host: Js) -> Result<()> {
    // SAFETY: a short exclusive metadata access, followed by throwing ownership.
    if let Some(error) = unsafe { (*host.0).graph.data.error.take() } {
        // SAFETY: transfer the owned exception back to this same context.
        unsafe {
            qjs::JS_Throw(ctx.as_raw().as_ptr(), error);
        }
        return Err(Error::Exception);
    }
    Ok(())
}
fn raw_owned(host: Js, value: &Value<'_>) -> Raw {
    host.dup(&value.as_raw())
}
fn signal<'js>(ctx: Ctx<'js>, value: Value<'js>) -> Result<Vec<u32>> {
    let host = state(&ctx)?;
    let value = raw_owned(host, &value);
    // SAFETY: allocation does not invoke user code; the reference ends here.
    let id = unsafe { (*host.0).graph.owned_signal(value, Equals::Default) };
    Ok(vec![id, unsafe { (*host.0).graph.generation(id) }])
}
fn check(host: Js, id: u32, generation: u32) -> Result<()> {
    // SAFETY: read-only, short inspection before entering a graph operation.
    if unsafe { !(*host.0).graph.live(id, generation, u32::MAX) } {
        return Err(Error::new_from_js_message(
            "Handle",
            "Reactive",
            "Disposed reactive handle",
        ));
    }
    Ok(())
}
fn read<'js>(ctx: Ctx<'js>, id: u32, generation: u32) -> Result<Value<'js>> {
    let host = state(&ctx)?;
    check(host, id, generation)?;
    let value = r::read(host, id);
    // SAFETY: guard the owned reference even when the graph reported an error.
    let value = unsafe { Value::from_raw(ctx.clone(), value) };
    finish(&ctx, host)?;
    Ok(value)
}
fn write<'js>(ctx: Ctx<'js>, id: u32, generation: u32, value: Value<'js>) -> Result<()> {
    let host = state(&ctx)?;
    check(host, id, generation)?;
    r::write(host, id, raw_owned(host, &value));
    finish(&ctx, host)
}
fn memo<'js>(ctx: Ctx<'js>, function: Function<'js>) -> Result<Vec<u32>> {
    let host = state(&ctx)?;
    let function = raw_owned(host, function.as_value());
    // SAFETY: allocating a stale memo runs no JS; reads evaluate it lazily.
    let id = unsafe { (*host.0).graph.lazy_memo(function, qjs::JS_UNDEFINED) };
    finish(&ctx, host)?;
    Ok(vec![id, unsafe { (*host.0).graph.generation(id) }])
}
fn effect<'js>(ctx: Ctx<'js>, function: Function<'js>) -> Result<Vec<u32>> {
    let host = state(&ctx)?;
    let id = r::effect(
        host,
        Kind::Effect,
        raw_owned(host, function.as_value()),
        qjs::JS_UNDEFINED,
    );
    finish(&ctx, host)?;
    Ok(vec![id, unsafe { (*host.0).graph.generation(id) }])
}
fn cleanup<'js>(ctx: Ctx<'js>, function: Function<'js>) -> Result<()> {
    let host = state(&ctx)?;
    let function = raw_owned(host, function.as_value());
    // SAFETY: on_cleanup only stores the callback; it does not execute it.
    if let Err(function) = unsafe { (*host.0).graph.on_cleanup(function) } {
        host.free(function);
        return Err(Error::new_from_js_message(
            "Function",
            "Cleanup",
            "Cleanup needs a live owner",
        ));
    }
    Ok(())
}
fn dispose(ctx: Ctx<'_>, id: u32, generation: u32) -> Result<()> {
    let host = state(&ctx)?;
    if check(host, id, generation).is_ok() {
        r::dispose_owner(host, id);
    }
    finish(&ctx, host)
}
fn scoped<'js>(ctx: Ctx<'js>, function: Function<'js>, kind: String) -> Result<Value<'js>> {
    let host = state(&ctx)?;
    let invoke = || function.call::<_, Value<'js>>(());
    let result = match kind.as_str() {
        "batch" => r::batch(host, invoke),
        "untracked" => r::untracked(host, invoke),
        _ => return Err(Error::new_from_js("string", "scope kind")),
    };
    finish(&ctx, host)?;
    result
}
fn root<'js>(ctx: Ctx<'js>, function: Function<'js>) -> Result<rquickjs::Array<'js>> {
    let host = state(&ctx)?;
    let (id, result) = r::with_root(host, || function.call::<_, Value<'js>>(()));
    finish(&ctx, host)?;
    let array = rquickjs::Array::new(ctx)?;
    array.set(0, id)?;
    array.set(1, unsafe { (*host.0).graph.generation(id) })?;
    array.set(2, result?)?;
    Ok(array)
}

pub(crate) fn install<'js>(ctx: &Ctx<'js>) -> Result<NativeState> {
    let native = NativeState {
        inner: Rc::new(UnsafeCell::new(State {
            graph: r::Graph::new(GraphData {
                ctx: ctx.as_raw().as_ptr(),
                error: None,
            }),
            closing: false,
            tree: nodes::Tree::new(),
            calls: HashMap::new(),
            next_call: 1,
            outbox: Vec::new(),
            fatal: None,
            rejections: HashMap::new(),
            rows: HashMap::new(),
            timers: HashMap::new(),
            next_timer: 1,
            paused: false,
        })),
    };
    ctx.store_userdata(native.clone())
        .map_err(|_| Error::new_from_js("state", "userdata"))?;
    install_gc_root(ctx, &native)?;
    let api = Object::new(ctx.clone())?;
    api.set("signal", Func::from(signal))?;
    api.set("read", Func::from(read))?;
    api.set("write", Func::from(write))?;
    api.set("computed", Func::from(memo))?;
    api.set("effect", Func::from(effect))?;
    api.set("cleanup", Func::from(cleanup))?;
    api.set("dispose", Func::from(dispose))?;
    api.set("scoped", Func::from(scoped))?;
    api.set("root", Func::from(root))?;
    api.set("create", Func::from(create_node))?;
    api.set("fail", Func::from(report_failure))?;
    api.set("timer", Func::from(start_timer))?;
    api.set("clearTimer", Func::from(clear_timer))?;
    api.set("each", Func::from(reconcile_each))?;
    api.set("clearEach", Func::from(clear_each))?;
    api.set("replaceSlot", Func::from(replace_slot))?;
    api.set("set", Func::from(set_node))?;
    api.set("insert", Func::from(insert_node))?;
    api.set("listen", Func::from(listen_node))?;
    api.set("release", Func::from(release_node))?;
    api.set("call", Func::from(host_call))?;
    api.set(
        "rootNode",
        Class::instance(
            ctx.clone(),
            NodeHandle {
                id: 1,
                identity: native.inner.get() as usize,
            },
        )?,
    )?;
    ctx.globals().set("__revericNative", api)?;
    Ok(native)
}

pub(crate) fn teardown(native: &NativeState) {
    let host = Js(native.inner.get());
    // SAFETY: teardown is called on the owning thread before Context/Runtime
    // destruction. free_all drops values without invoking cleanup callbacks.
    unsafe {
        (*host.0).closing = true;
        (*host.0).graph.free_all(host);
    }
    let functions: Vec<_> = unsafe {
        (*host.0)
            .tree
            .listeners
            .drain()
            .map(|(_, v)| v.function)
            .collect()
    };
    for function in functions {
        host.free(function);
    }
    let calls: Vec<_> = unsafe { (*host.0).calls.drain().map(|(_, v)| v).collect() };
    for (resolve, reject) in calls {
        host.free(resolve);
        host.free(reject);
    }
    let timers: Vec<_> = unsafe {
        (*host.0)
            .timers
            .drain()
            .map(|(_, timer)| timer.function)
            .collect()
    };
    for function in timers {
        host.free(function);
    }
    let rejections: Vec<_> =
        unsafe { (*host.0).rejections.drain().map(|(_, pair)| pair).collect() };
    for (promise, reason) in rejections {
        host.free(promise);
        host.free(reason);
    }
    if let Some(error) = unsafe { (*host.0).graph.data.error.take() } {
        host.free(error);
    }
}

#[derive(Clone, Trace, JsLifetime)]
#[rquickjs::class]
pub(crate) struct NodeHandle {
    #[qjs(skip_trace)]
    pub id: u64,
    #[qjs(skip_trace)]
    identity: usize,
}
fn node_id(ctx: &Ctx<'_>, node: &Class<'_, NodeHandle>) -> Result<u64> {
    let host = state(ctx)?;
    let node = node.borrow();
    // SAFETY: identity check is followed by a short table lookup.
    if node.identity != host.0 as usize || unsafe { !(*host.0).tree.nodes.contains_key(&node.id) } {
        return Err(nodes::invalid("Foreign or disposed UI node"));
    }
    Ok(node.id)
}
fn create_node<'js>(ctx: Ctx<'js>, component: String) -> Result<Class<'js, NodeHandle>> {
    let host = state(&ctx)?;
    // SAFETY: tree mutations only enqueue owned DTOs and do not execute JS.
    let id = unsafe { (*host.0).tree.create(component)? };
    Class::instance(
        ctx,
        NodeHandle {
            id,
            identity: host.0 as usize,
        },
    )
}
fn set_node<'js>(ctx: Ctx<'js>, node: Class<'js, NodeHandle>, input: Object<'js>) -> Result<()> {
    let host = state(&ctx)?;
    let id = node_id(&ctx, &node)?;
    // SAFETY: node_id has just checked that this node is live.
    let component = unsafe { (&(*host.0).tree.nodes)[&id].component.clone() };
    let mut props = HashMap::new();
    let mut unset = Vec::new();
    for entry in input.props::<String, Value>() {
        let (key, value) = entry?;
        let Some((kind, choices)) = super::schema::property(&component, &key) else {
            return Err(nodes::invalid(&format!(
                "Unknown {component} property {key}"
            )));
        };
        if value.is_undefined() {
            unset.push(key);
            continue;
        }
        let value = nodes::decode(&ctx, value)?;
        if !super::schema::valid(kind, choices, &value) {
            let expected = if choices.is_empty() {
                kind.expected().to_string()
            } else {
                choices.join(" | ")
            };
            return Err(nodes::invalid(&format!(
                "Invalid {component}.{key}: expected {expected}"
            )));
        }
        props.insert(key, value);
    }
    // SAFETY: no JS callbacks run while editing the pending batch.
    unsafe {
        let revision = (*host.0).tree.revisions.get(&id).copied();
        (*host.0).tree.push(UiOp::Set {
            id,
            props,
            unset,
            edit_revision: revision,
        })
    }
}
fn insert_node<'js>(
    ctx: Ctx<'js>,
    parent: Class<'js, NodeHandle>,
    child: Class<'js, NodeHandle>,
    slot: String,
    before: Option<Class<'js, NodeHandle>>,
) -> Result<()> {
    let host = state(&ctx)?;
    let parent = node_id(&ctx, &parent)?;
    let child = node_id(&ctx, &child)?;
    let before = before.map(|node| node_id(&ctx, &node)).transpose()?;
    // SAFETY: structural checks and DTO enqueueing do not execute JS.
    unsafe { (*host.0).tree.insert(parent, child, slot, before) }
}
fn listen_node<'js>(
    ctx: Ctx<'js>,
    node: Class<'js, NodeHandle>,
    event: String,
    function: Option<Function<'js>>,
) -> Result<()> {
    let host = state(&ctx)?;
    let id = node_id(&ctx, &node)?;
    if super::schema::Event::parse(&event).is_none() {
        return Err(nodes::invalid("Unknown UI event"));
    }
    let function = function.map(|function| raw_owned(host, function.as_value()));
    // SAFETY: take old references out of the table before releasing them.
    let previous = unsafe {
        let state = &mut *host.0;
        let previous = state
            .tree
            .nodes
            .get_mut(&id)
            .unwrap()
            .handlers
            .remove(&event)
            .and_then(|id| state.tree.listeners.remove(&id));
        let handler = function.map(|function| {
            let handler = state.tree.next_handler;
            state.tree.next_handler += 1;
            state.tree.listeners.insert(
                handler,
                nodes::Listener {
                    function,
                    owner: state.graph.owner(),
                    node: id,
                    event: event.clone(),
                },
            );
            state
                .tree
                .nodes
                .get_mut(&id)
                .unwrap()
                .handlers
                .insert(event.clone(), handler);
            handler
        });
        state.tree.push(UiOp::Listen { id, event, handler })?;
        previous
    };
    if let Some(previous) = previous {
        host.free(previous.function);
    }
    Ok(())
}
fn release_node<'js>(ctx: Ctx<'js>, node: Class<'js, NodeHandle>) -> Result<()> {
    let host = state(&ctx)?;
    let handle = node.borrow();
    if handle.identity != host.0 as usize {
        return Err(nodes::invalid("Foreign node"));
    }
    let mut freed = Vec::new();
    // SAFETY: this mutation collects references; their release happens later.
    let result = unsafe { (*host.0).tree.dispose(handle.id, &mut freed) };
    drop(handle);
    for function in freed {
        host.free(function);
    }
    result
}
fn host_call<'js>(
    ctx: Ctx<'js>,
    method: String,
    args: Value<'js>,
) -> Result<rquickjs::Promise<'js>> {
    let host = state(&ctx)?;
    // SAFETY: a short metadata lookup precedes allocating any JS objects.
    if unsafe { (*host.0).closing || (*host.0).calls.len() >= 32 } {
        return Err(nodes::invalid(
            "Host request budget exceeded or page closed",
        ));
    }
    let args = nodes::decode(&ctx, args)?;
    let (promise, resolve, reject) = ctx.promise()?;
    let resolve = raw_owned(host, resolve.as_value());
    let reject = raw_owned(host, reject.as_value());
    // SAFETY: storing owned references invokes no JavaScript.
    unsafe {
        let state = &mut *host.0;
        let id = state.next_call;
        state.next_call += 1;
        state.calls.insert(id, (resolve, reject));
        state.outbox.push(UiOutput::HostCall {
            call_id: id,
            method,
            args,
        });
    }
    Ok(promise)
}
pub(crate) fn reply(ctx: &Ctx<'_>, id: u64, value: UiValue, error: Option<String>) -> Result<()> {
    let host = state(ctx)?;
    // SAFETY: remove callbacks before entering JS, so late replies are ignored.
    let callbacks = unsafe { (*host.0).calls.remove(&id) };
    if let Some((resolve, reject)) = callbacks {
        let resolve = unsafe { Value::from_raw(ctx.clone(), resolve) };
        let reject = unsafe { Value::from_raw(ctx.clone(), reject) };
        let value = nodes::encode(ctx, error.clone().map(UiValue::String).unwrap_or(value))?;
        let function = if error.is_some() {
            reject.as_raw()
        } else {
            resolve.as_raw()
        };
        let result = host.invoke(function, &mut [value.as_raw()]);
        if let Some(result) = result {
            host.free(result);
        }
        finish(ctx, host)?;
    }
    Ok(())
}
pub(crate) fn dispatch(ctx: &Ctx<'_>, event: UiEvent) -> Result<()> {
    let host = state(ctx)?;
    // SAFETY: clone one function reference out of the listener table.
    let listener = unsafe {
        let state = &mut *host.0;
        if event.seq > state.tree.last_ack && state.tree.awaiting != Some(event.seq) {
            return Err(nodes::invalid("Event references uncommitted batch"));
        }
        state
            .tree
            .listeners
            .get(&event.handler)
            .filter(|listener| listener.node == event.node && listener.event == event.event)
            .map(|listener| {
                (
                    qjs::JS_DupValue(ctx.as_raw().as_ptr(), listener.function),
                    listener.owner,
                )
            })
    };
    let Some((function, owner)) = listener else {
        return Ok(());
    };
    // Submit carries the text the handler acts on, so a value it writes back
    // must not look older than that text.
    if event.event == "onChange" || event.event == "onSubmit" {
        if let UiValue::Object(payload) = &event.payload {
            if let Some(UiValue::Number(revision)) = payload.get("editRevision") {
                if *revision >= 0.0 && revision.fract() == 0.0 {
                    unsafe {
                        (*host.0)
                            .tree
                            .revisions
                            .insert(event.node, *revision as u64);
                    }
                }
            }
        }
    }
    let function = unsafe { Value::from_raw(ctx.clone(), function) };
    let payload = nodes::encode(ctx, event.payload)?;
    let result = r::with_owner(host, owner, || {
        host.invoke(function.as_raw(), &mut [payload.as_raw()])
    });
    if let Some(result) = result {
        // Async event rejection is surfaced by the SDK without serializing
        // subsequent events behind the Promise.
        let value = unsafe { Value::from_raw(ctx.clone(), result) };
        if value.is_promise() {
            let observe: Function = ctx.globals().get("__revericObserve")?;
            observe.call::<_, ()>((value,))?;
        }
    }
    finish(ctx, host)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rquickjs::{Context, Runtime};
    fn run(source: &str) {
        let runtime = Runtime::new().unwrap();
        let context = Context::full(&runtime).unwrap();
        context.with(|ctx| {
            let native = install(&ctx).unwrap();
            ctx.eval::<(), _>("globalThis.__revericScope={}; globalThis.__revericEnvironment={};")
                .unwrap();
            ctx.eval::<(), _>(include_str!("components.js")).unwrap();
            ctx.eval::<(), _>(include_str!("sqlite.js"))
                .expect("SQLite SDK codec");
            ctx.eval::<(), _>(include_str!("sdk.js")).unwrap();
            let result = ctx.eval::<(), _>(source);
            if let Err(error) = &result {
                eprintln!("{error:?} {:?}", ctx.catch());
            }
            teardown(&native);
            result.unwrap();
        });
        runtime.run_gc();
    }
    #[test]
    fn synchronous_signals_batch_computed_and_cleanup() {
        run(r#"
          const n=__revericNative;
          let count=0,cleaned=0,value,s;
          const root=n.root(()=>{
            s=signal(1); const doubled=computed(()=>s()*2);
            effect(()=>{value=doubled(); count++; cleanup(()=>cleaned++);});
          });
          if(value!==2 || count!==1) throw Error('initial effect');
          batch(()=>{s.set(2);s.set(3);});
          if(value!==6 || count!==2 || cleaned!==1) throw Error('reactivity mismatch');
          s.set(3); if(count!==2) throw Error('equal update');
          n.dispose(root[0],root[1]); n.dispose(root[0],root[1]);
          if(cleaned!==2) throw Error('cleanup must run once');
        "#);
    }
    #[test]
    fn computed_values_are_lazy_until_observed() {
        run(r#"
          const n=__revericNative;let runs=0,s,m;
          const root=n.root(()=> {s=signal(1);m=computed(()=>{runs++;return s()*2;});});
          if(runs!==0)throw Error('computed eager at creation');
          s.set(2);if(runs!==0)throw Error('computed eager before read');
          if(m()!==4 || runs!==1)throw Error('computed read');
          s.set(3);if(runs!==1)throw Error('unobserved computed eager');
          if(m()!==6 || m()!==6 || runs!==2)throw Error('computed cache');
          n.dispose(root[0],root[1]);
        "#);
    }
    #[test]
    fn gc_traces_graph_cycles_and_rejects_disposed_handles() {
        run(r#"
          const n=__revericNative; let stale;
          const root=n.root(()=>{ const cycle={};cycle.self=cycle;stale=signal(cycle);effect(()=>stale()); });
          n.dispose(root[0],root[1]);
          let rejected=false; try {stale.set({});}catch(error){rejected=true;}
          if(!rejected)throw Error('disposed signal accepted');
        "#);
    }
    #[test]
    fn host_promises_release_resolvers_and_ignore_late_replies() {
        let runtime = Runtime::new().unwrap();
        let context = Context::full(&runtime).unwrap();
        context.with(|ctx| {
            let native=install(&ctx).unwrap();
            ctx.eval::<(),_>("globalThis.result=0;__revericNative.call('storage.get',{key:'x'}).then(v=>result=v);").unwrap();
            assert_eq!(unsafe {(*native.inner.get()).calls.len()},1);
            reply(&ctx,1,UiValue::Number(7.0),None).unwrap();
            while ctx.execute_pending_job() {}
            assert_eq!(ctx.eval::<i32,_>("result").unwrap(),7);
            reply(&ctx,1,UiValue::Number(9.0),None).unwrap();
            assert_eq!(ctx.eval::<i32,_>("result").unwrap(),7);
            assert!(unsafe {(*native.inner.get()).calls.is_empty()});
            teardown(&native);
        });
    }
}

#[derive(Clone, Copy)]
pub(crate) struct EachRow {
    owner: u32,
    node: u64,
    item: u32,
    index: u32,
}
fn release_id(host: Js, id: u64) -> Result<()> {
    let mut freed = Vec::new();
    // SAFETY: collect function references before releasing any JS values.
    let result = unsafe { (*host.0).tree.dispose(id, &mut freed) };
    for function in freed {
        host.free(function);
    }
    result
}
fn clear_each<'js>(ctx: Ctx<'js>, node: Class<'js, NodeHandle>) -> Result<()> {
    let host = state(&ctx)?;
    let handle = node.borrow();
    if handle.identity != host.0 as usize {
        return Err(nodes::invalid("Foreign list"));
    }
    let rows = unsafe { (*host.0).rows.remove(&handle.id) };
    drop(handle);
    if let Some(rows) = rows {
        for row in rows.values() {
            r::dispose_owner(host, row.owner);
            release_id(host, row.node)?;
        }
    }
    finish(&ctx, host)
}
fn reconcile_each<'js>(
    ctx: Ctx<'js>,
    parent: Class<'js, NodeHandle>,
    items: rquickjs::Array<'js>,
    key: Function<'js>,
    render: Function<'js>,
    offset: u32,
) -> Result<()> {
    let host = state(&ctx)?;
    let parent = node_id(&ctx, &parent)?;
    if items.len() > 2000 {
        return Err(nodes::invalid("plugin_ui_limit: too many rendered rows"));
    }
    r::untracked(host, || {
        let mut values = Vec::new();
        let mut keys = std::collections::HashSet::new();
        for item in items.iter::<Value>() {
            let item = item?;
            let id: String = key.call((item.clone(),))?;
            if !keys.insert(id.clone()) {
                return Err(nodes::invalid("Duplicate list key"));
            }
            values.push((id, item));
        }
        // SAFETY: move the reconciliation map out before calling render/graph.
        let mut old = unsafe { (*host.0).rows.remove(&parent).unwrap_or_default() };
        let mut next = HashMap::new();
        let mut order = Vec::with_capacity(values.len());
        let result = (|| -> Result<()> {
            for (position, (id, value)) in values.iter().enumerate() {
                let index = (position as u32) + offset;
                let row = if let Some(row) = old.remove(id) {
                    r::batch(host, || {
                        r::write(host, row.item, raw_owned(host, value));
                        r::write(host, row.index, qjs::JS_NewFloat64(index as f64));
                    });
                    row
                } else {
                    let (owner, result) = r::with_root(host, || -> Result<EachRow> {
                        let item_value = raw_owned(host, value);
                        // SAFETY: allocating row signals does not execute JS.
                        let (item, item_gen, index_id, index_gen) = unsafe {
                            let graph = &mut (*host.0).graph;
                            let item = graph.owned_signal(item_value, Equals::Default);
                            let index_id = graph
                                .owned_signal(qjs::JS_NewFloat64(index as f64), Equals::Default);
                            (
                                item,
                                graph.generation(item),
                                index_id,
                                graph.generation(index_id),
                            )
                        };
                        let accessor: Function = ctx.globals().get("__revericAccessor")?;
                        let item_accessor: Function = accessor.call((item, item_gen))?;
                        let index_accessor: Function = accessor.call((index_id, index_gen))?;
                        let node: Class<NodeHandle> =
                            render.call((item_accessor, index_accessor))?;
                        Ok(EachRow {
                            owner: 0,
                            node: node_id(&ctx, &node)?,
                            item,
                            index: index_id,
                        })
                    });
                    match result {
                        Ok(mut row) => {
                            row.owner = owner;
                            row
                        }
                        Err(error) => {
                            r::dispose_owner(host, owner);
                            return Err(error);
                        }
                    }
                };
                order.push(row.node);
                next.insert(id.clone(), row);
            }
            Ok(())
        })();
        for row in old.values() {
            r::dispose_owner(host, row.owner);
            release_id(host, row.node)?;
        }
        // Keep completed rows reachable for teardown even when a renderer fails.
        unsafe {
            (*host.0).rows.insert(parent, next);
        }
        result?;
        // SAFETY: moving keyed rows changes only typed tree data.
        unsafe { (*host.0).tree.reorder(parent, "children", &order)? };
        finish(&ctx, host)
    })
}
fn replace_slot<'js>(
    ctx: Ctx<'js>,
    parent: Class<'js, NodeHandle>,
    slot: String,
    children: rquickjs::Array<'js>,
) -> Result<()> {
    let host = state(&ctx)?;
    let parent = node_id(&ctx, &parent)?;
    let ids = children
        .iter::<Class<NodeHandle>>()
        .map(|node| node.and_then(|node| node_id(&ctx, &node)))
        .collect::<Result<Vec<_>>>()?;
    let unique: std::collections::HashSet<_> = ids.iter().copied().collect();
    if unique.len() != ids.len() {
        return Err(nodes::invalid("Duplicate child node"));
    }
    let old = unsafe {
        (*host.0)
            .tree
            .nodes
            .get(&parent)
            .and_then(|node| node.slots.get(&slot))
            .cloned()
            .unwrap_or_default()
    };
    for id in old {
        if !unique.contains(&id) {
            release_id(host, id)?;
        }
    }
    for id in ids {
        unsafe {
            (*host.0).tree.insert(parent, id, slot.clone(), None)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod keyed_tests {
    use super::*;
    use rquickjs::{Context, Runtime};
    #[test]
    fn keyed_rows_keep_identity_refresh_values_and_dispose_removed_owners() {
        let runtime = Runtime::new().unwrap();
        let context = Context::full(&runtime).unwrap();
        context.with(|ctx| {
            let native = install(&ctx).unwrap();
            ctx.eval::<(), _>("globalThis.__revericScope={};globalThis.__revericEnvironment={};")
                .unwrap();
            ctx.eval::<(), _>(include_str!("components.js")).unwrap();
            ctx.eval::<(), _>(include_str!("sqlite.js"))
                .expect("SQLite SDK codec");
            ctx.eval::<(), _>(include_str!("sdk.js")).unwrap();
            ctx.eval::<(), _>(
                r#"
              globalThis.freed=0;
              mount(()=> {
                globalThis.items=signal([{id:'a',label:'A'},{id:'b',label:'B'}]);
                return Each({get items(){return items();},key:item=>item.id,children:item=> {
                  cleanup(()=>freed++);return element('Text',{get text(){return item().label;}});
                }});
              },__revericNative.rootNode);
            "#,
            )
            .unwrap();
            let (parent, a, b) = unsafe {
                let state = &mut *native.inner.get();
                let (parent, rows) = state.rows.iter().next().unwrap();
                let ids = (*parent, rows["a"].node, rows["b"].node);
                state.tree.pending.clear();
                ids
            };
            ctx.eval::<(), _>("items.set([{id:'b',label:'B2'},{id:'a',label:'A2'}]);")
                .unwrap();
            unsafe {
                let state = &*native.inner.get();
                let moves = state
                    .tree
                    .pending
                    .iter()
                    .filter(|op| matches!(op, UiOp::Insert { .. }));
                assert_eq!(moves.count(), 1);
                assert_eq!(state.rows[&parent]["a"].node, a);
                assert_eq!(state.rows[&parent]["b"].node, b);
                assert_eq!(state.tree.nodes[&parent].slots["children"], vec![b, a]);
            }
            ctx.eval::<(), _>("items.set([{id:'a',label:'A3'}]);")
                .unwrap();
            assert_eq!(ctx.eval::<i32, _>("freed").unwrap(), 1);
            assert!(!unsafe { (*native.inner.get()).tree.nodes.contains_key(&b) });
            // Mark live graph/event references without changing their refcounts.
            unsafe {
                qjs::JS_RunGC(qjs::JS_GetRuntime(ctx.as_raw().as_ptr()));
            }
            ctx.eval::<(), _>("items.set([{id:'a',label:'A4'}]);__revericDisposePage();")
                .unwrap();
            assert_eq!(ctx.eval::<i32, _>("freed").unwrap(), 2);
            teardown(&native);
        });
    }
    #[test]
    fn unchanged_props_and_swapped_handlers_send_no_ops() {
        let runtime = Runtime::new().unwrap();
        let context = Context::full(&runtime).unwrap();
        context.with(|ctx| {
            let native = install(&ctx).unwrap();
            ctx.eval::<(), _>("globalThis.__revericScope={};globalThis.__revericEnvironment={};")
                .unwrap();
            ctx.eval::<(), _>(include_str!("components.js")).unwrap();
            ctx.eval::<(), _>(include_str!("sqlite.js")).unwrap();
            ctx.eval::<(), _>(include_str!("sdk.js")).unwrap();
            ctx.eval::<(), _>(
                r#"globalThis.calls=[];globalThis.s=signal(1);
                mount(()=>element('Button',{get label(){return s()>0?'positive':'negative';},
                  get onPress(){const v=s();return v===3?undefined:v===1?()=>calls.push('a'):()=>calls.push('b');}}),
                  __revericNative.rootNode);"#,
            )
            .unwrap();
            let count = |kind: &str| unsafe {
                let ops = &(*native.inner.get()).tree.pending;
                ops.iter()
                    .filter(|op| match (kind, op) {
                        ("set", UiOp::Set { .. }) => true,
                        ("listen", UiOp::Listen { .. }) => true,
                        _ => false,
                    })
                    .count()
            };
            unsafe { (*native.inner.get()).tree.pending.clear() };
            ctx.eval::<(), _>("s.set(2);").unwrap();
            assert_eq!((count("set"), count("listen")), (0, 0));
            ctx.eval::<(), _>("s.set(3);").unwrap();
            assert_eq!((count("set"), count("listen")), (0, 1));
            teardown(&native);
        });
    }
}

pub(crate) struct UiTimer {
    function: Raw,
    cleanup: Raw,
    owner: u32,
    generation: u32,
    due: std::time::Instant,
    interval: Option<std::time::Duration>,
}
fn start_timer<'js>(
    ctx: Ctx<'js>,
    function: Function<'js>,
    delay: f64,
    repeat: bool,
) -> Result<u64> {
    let host = state(&ctx)?;
    if !delay.is_finite() || delay < 0.0 || delay > 2_147_483_647.0 {
        return Err(nodes::invalid("Invalid timer delay"));
    }
    // SAFETY: inspect ownership before taking an additional JS reference.
    let (owner, generation) = unsafe {
        let state = &*host.0;
        if state.closing || state.timers.len() >= 64 || !state.graph.has_owner() {
            return Err(nodes::invalid(
                "Timer requires live owner and an available slot",
            ));
        }
        let owner = state.graph.owner();
        (owner, state.graph.generation(owner))
    };
    let delay =
        std::time::Duration::from_secs_f64((if repeat { delay.max(1.0) } else { delay }) / 1000.0);
    let id = unsafe {
        let state = &mut *host.0;
        let id = state.next_timer;
        state.next_timer += 1;
        id
    };
    let cleanup_function = Function::new(ctx.clone(), move |ctx: Ctx<'_>| clear_timer(ctx, id))?;
    let cleanup = raw_owned(host, cleanup_function.as_value());
    // SAFETY: the graph owns cleanup; the timer stores only its identity so it
    // can unlink that cleanup when it fires or is explicitly cleared.
    if let Err(cleanup) = unsafe { (*host.0).graph.on_cleanup(cleanup) } {
        host.free(cleanup);
        return Err(nodes::invalid("Timer owner was disposed"));
    }
    let function = raw_owned(host, function.as_value());
    unsafe {
        (*host.0).timers.insert(
            id,
            UiTimer {
                function,
                cleanup,
                owner,
                generation,
                due: std::time::Instant::now() + delay,
                interval: repeat.then_some(delay),
            },
        );
    }
    Ok(id)
}
fn clear_timer(ctx: Ctx<'_>, id: u64) -> Result<()> {
    let host = state(&ctx)?;
    let timer = unsafe { (*host.0).timers.remove(&id) };
    if let Some(timer) = timer {
        // SAFETY: strict equality invokes no JS. The graph cleanup may already
        // have been taken by owner disposal; in that case its caller owns it.
        let cleanup = unsafe {
            (*host.0).graph.remove_cleanup(timer.owner, |value| {
                qjs::JS_IsStrictEqual(ctx.as_raw().as_ptr(), *value, timer.cleanup)
            })
        };
        if let Some(cleanup) = cleanup {
            host.free(cleanup);
        }
        host.free(timer.function);
    }
    Ok(())
}
pub(crate) fn set_visibility(native: &NativeState, environment: &UiValue) {
    let UiValue::Object(environment) = environment else {
        return;
    };
    let Some(UiValue::Boolean(visible)) = environment.get("visible") else {
        return;
    };
    // SAFETY: only metadata changes; no JavaScript executes here.
    unsafe {
        let state = &mut *native.inner.get();
        let paused = !*visible;
        if state.paused && !paused {
            for timer in state.timers.values_mut() {
                if let Some(interval) = timer.interval {
                    timer.due = std::time::Instant::now() + interval;
                }
            }
        }
        state.paused = paused;
    }
}
pub(crate) fn next_timer(native: &NativeState) -> Option<std::time::Duration> {
    // SAFETY: read-only lookup on the owning thread.
    unsafe {
        let state = &*native.inner.get();
        state
            .timers
            .values()
            .filter(|timer| !(state.paused && timer.interval.is_some()))
            .map(|timer| {
                timer
                    .due
                    .saturating_duration_since(std::time::Instant::now())
            })
            .min()
    }
}
pub(crate) fn tick_timers(ctx: &Ctx<'_>) -> Result<()> {
    let host = state(ctx)?;
    let now = std::time::Instant::now();
    let due: Vec<_> = unsafe {
        let state = &*host.0;
        state
            .timers
            .iter()
            .filter(|(_, timer)| timer.due <= now && !(state.paused && timer.interval.is_some()))
            .map(|(id, _)| *id)
            .collect()
    };
    for id in due {
        let invocation = unsafe {
            let state = &mut *host.0;
            let Some(timer) = state.timers.get_mut(&id) else {
                continue;
            };
            if !state.graph.live(timer.owner, timer.generation, u32::MAX) {
                None
            } else {
                // Dup one temporary invocation reference before callback reentry.
                let function = qjs::JS_DupValue(ctx.as_raw().as_ptr(), timer.function);
                let owner = timer.owner;
                if let Some(interval) = timer.interval {
                    timer.due = now + interval;
                }
                Some((function, owner, timer.interval.is_none()))
            }
        };
        let Some((function, owner, one_shot)) = invocation else {
            clear_timer(ctx.clone(), id)?;
            continue;
        };
        if one_shot {
            clear_timer(ctx.clone(), id)?;
        }
        let result = r::with_owner(host, owner, || host.invoke(function, &mut []));
        host.free(function);
        if let Some(result) = result {
            let value = unsafe { Value::from_raw(ctx.clone(), result) };
            if value.is_promise() {
                let observe: Function = ctx.globals().get("__revericObserve")?;
                observe.call::<_, ()>((value,))?;
            }
        }
        finish(ctx, host)?;
    }
    Ok(())
}

#[cfg(test)]
mod timer_tests {
    use super::*;
    use rquickjs::{Context, Runtime};
    #[test]
    fn timer_owner_cleanup_pause_and_completed_callback_release() {
        let runtime = Runtime::new().unwrap();
        let context = Context::full(&runtime).unwrap();
        context.with(|ctx| {
            let native = install(&ctx).unwrap();
            ctx.eval::<(), _>("globalThis.__revericScope={};globalThis.__revericEnvironment={};")
                .unwrap();
            ctx.eval::<(), _>(include_str!("components.js")).unwrap();
            ctx.eval::<(), _>(include_str!("sqlite.js"))
                .expect("SQLite SDK codec");
            ctx.eval::<(), _>(include_str!("sdk.js")).unwrap();
            ctx.eval::<(), _>(
                r#"
              globalThis.ticks=0;
              globalThis.timerOwner=__revericNative.root(()=>{
                for(let i=0;i<200;i++) {const timer=setTimeout(()=>{},10000);clearTimeout(timer);}
                setInterval(()=>ticks++,1);
                setTimeout(()=>ticks+=10,0);
              });
            "#,
            )
            .unwrap();
            assert_eq!(unsafe { (*native.inner.get()).timers.len() }, 2);
            set_visibility(
                &native,
                &UiValue::Object(HashMap::from([("visible".into(), UiValue::Boolean(false))])),
            );
            tick_timers(&ctx).unwrap();
            assert_eq!(ctx.eval::<i32, _>("ticks").unwrap(), 10);
            let mut cleanups = 0;
            unsafe {
                (*native.inner.get()).graph.visit_references(
                    |_| {},
                    |_| {},
                    |_| {},
                    |_| cleanups += 1,
                );
            }
            assert_eq!(
                cleanups, 1,
                "completed/cancelled timer cleanups must not accumulate"
            );
            std::thread::sleep(std::time::Duration::from_millis(3));
            tick_timers(&ctx).unwrap();
            assert_eq!(ctx.eval::<i32, _>("ticks").unwrap(), 10);
            set_visibility(
                &native,
                &UiValue::Object(HashMap::from([("visible".into(), UiValue::Boolean(true))])),
            );
            std::thread::sleep(std::time::Duration::from_millis(3));
            tick_timers(&ctx).unwrap();
            assert_eq!(ctx.eval::<i32, _>("ticks").unwrap(), 11);
            ctx.eval::<(), _>("__revericNative.dispose(timerOwner[0],timerOwner[1]);")
                .unwrap();
            assert!(unsafe { (*native.inner.get()).timers.is_empty() });
            teardown(&native);
        });
    }
}

fn report_failure(ctx: Ctx<'_>, message: String) -> Result<()> {
    let host = state(&ctx)?;
    unsafe {
        (*host.0).fatal = Some(message);
    }
    Ok(())
}
pub(crate) fn track_rejection<'js>(
    ctx: &Ctx<'js>,
    promise: Value<'js>,
    reason: Value<'js>,
    handled: bool,
) {
    let Ok(host) = state(ctx) else {
        return;
    };
    let id = unsafe { qjs::JS_VALUE_GET_PTR(promise.as_raw()) as usize };
    let value = if handled {
        None
    } else {
        Some((raw_owned(host, &promise), raw_owned(host, &reason)))
    };
    let previous = unsafe {
        if let Some(value) = value {
            (*host.0).rejections.insert(id, value)
        } else {
            (*host.0).rejections.remove(&id)
        }
    };
    if let Some((promise, reason)) = previous {
        host.free(promise);
        host.free(reason);
    }
}
pub(crate) fn pending_error(ctx: &Ctx<'_>) -> Option<String> {
    let host = state(ctx).ok()?;
    if let Some(message) = unsafe { (*host.0).fatal.take() } {
        return Some(message);
    }
    let value = unsafe {
        (*host.0)
            .rejections
            .values()
            .next()
            .map(|(_, reason)| qjs::JS_DupValue(ctx.as_raw().as_ptr(), *reason))
    }?;
    let value = unsafe { Value::from_raw(ctx.clone(), value) };
    let message = rquickjs::Coerced::<String>::from_js(ctx, value.clone())
        .map(|value| value.0)
        .unwrap_or_else(|_| "Unhandled promise rejection".into());
    let stack = value
        .as_object()
        .and_then(|object| object.get::<_, String>("stack").ok())
        .unwrap_or_default();
    Some(format!("{message}\n{stack}"))
}
