//! Dedicated OS-thread event loop, native interruption and nonblocking host replies.
use super::{bindings, nodes};
use crate::api::ui::{UiEvent, UiOutput, UiValue};
use rquickjs::{Coerced, Context, FromJs, Runtime};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        mpsc::Receiver,
    },
    time::Instant,
};

pub(crate) enum Command {
    Event(UiEvent),
    Reply {
        call_id: u64,
        value: UiValue,
        error: Option<String>,
    },
    Ack(u64),
    Environment(UiValue),
    Close,
}
impl Command {
    pub fn size(&self) -> usize {
        match self {
            Self::Event(v) => 128 + nodes::value_size(&v.payload),
            Self::Reply { value, error, .. } => {
                64 + nodes::value_size(value) + error.as_ref().map(String::len).unwrap_or(0)
            }
            Self::Environment(v) => nodes::value_size(v),
            _ => 16,
        }
    }
}

pub(crate) const VIEW_FILENAME: &str = "plugin-view.js";
pub(crate) fn run(
    surface: String,
    generation: u32,
    source: String,
    scope: UiValue,
    environment: UiValue,
    output: impl Fn(UiOutput) -> Result<(), ()>,
    commands: Receiver<Command>,
    closed: Arc<AtomicBool>,
    queued: Arc<AtomicUsize>,
) {
    let worker = super::telemetry::Worker::new();
    let timed_out = Arc::new(AtomicBool::new(false));
    let exceeded = timed_out.clone();
    let result = (|| -> Result<(), String> {
        let _engine = worker.engine();
        let runtime = Runtime::new().map_err(|e| e.to_string())?;
        runtime.set_memory_limit(64 * 1024 * 1024);
        runtime.set_max_stack_size(1024 * 1024);
        let origin = Instant::now();
        let deadline = Arc::new(AtomicU64::new(5_000_000));
        let cleaning = Arc::new(AtomicBool::new(false));
        let cleanup_flag = cleaning.clone();
        let stop = closed.clone();
        let cutoff = deadline.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            let expired = origin.elapsed().as_micros() as u64 > cutoff.load(Ordering::Acquire);
            if expired {
                exceeded.store(true, Ordering::Release);
            }
            (stop.load(Ordering::Acquire) && !cleanup_flag.load(Ordering::Acquire)) || expired
        })));
        runtime.set_host_promise_rejection_tracker(Some(Box::new(
            |ctx, promise, reason, handled| {
                bindings::track_rejection(&ctx, promise, reason, handled);
            },
        )));
        let context = Context::full(&runtime).map_err(|e| e.to_string())?;
        context.with(|ctx| {
            let native = bindings::install(&ctx).map_err(|e| diagnostic(&ctx, e))?;
            bindings::set_visibility(&native, &environment);
            let result = (|| -> Result<(), String> {
                ctx.globals()
                    .set(
                        "__revericScope",
                        nodes::encode(&ctx, scope).map_err(|e| diagnostic(&ctx, e))?,
                    )
                    .map_err(|e| diagnostic(&ctx, e))?;
                ctx.globals()
                    .set(
                        "__revericEnvironment",
                        nodes::encode(&ctx, environment).map_err(|e| diagnostic(&ctx, e))?,
                    )
                    .map_err(|e| diagnostic(&ctx, e))?;
                ctx.eval::<(), _>(include_str!("components.js"))
                    .map_err(|e| diagnostic(&ctx, e))?;
                ctx.eval::<(), _>(include_str!("sqlite.js"))
                    .map_err(|e| diagnostic(&ctx, e))?;
                ctx.eval::<(), _>(include_str!("sdk.js"))
                    .map_err(|e| diagnostic(&ctx, e))?;
                ctx.eval::<(), _>(include_str!("harden.js"))
                    .map_err(|e| diagnostic(&ctx, e))?;
                // A distinct name lets the host map plugin frames through the
                // view source map without touching SDK frames.
                let mut options = rquickjs::context::EvalOptions::default();
                options.filename = Some(VIEW_FILENAME.into());
                ctx.eval_with_options::<(), _>(source, options)
                    .map_err(|e| diagnostic(&ctx, e))?;
                ctx.eval::<(), _>("__revericView.mount(__revericPageContext)")
                    .map_err(|e| diagnostic(&ctx, e))?;
                loop {
                    let jobs_started = Instant::now();
                    let mut had_jobs = false;
                    while unsafe {
                        rquickjs::qjs::JS_IsJobPending(rquickjs::qjs::JS_GetRuntime(
                            ctx.as_raw().as_ptr(),
                        ))
                    } {
                        had_jobs = true;
                        if closed.load(Ordering::Acquire) {
                            return Ok(());
                        }
                        if origin.elapsed().as_micros() as u64 > deadline.load(Ordering::Acquire) {
                            return Err("plugin_timeout: promise job budget exceeded".into());
                        }
                        let mut job_context = ctx.as_raw().as_ptr();
                        // SAFETY: Context::with already holds the runtime lock;
                        // the raw job pump executes only on this owning thread.
                        let ran = unsafe {
                            rquickjs::qjs::JS_ExecutePendingJob(
                                rquickjs::qjs::JS_GetRuntime(job_context),
                                &mut job_context,
                            )
                        };
                        if ran < 0 {
                            return Err(diagnostic(&ctx, rquickjs::Error::Exception));
                        }
                    }
                    if had_jobs {
                        worker.elapsed("js_reactive_us", jobs_started);
                    }
                    if let Some(error) = bindings::pending_error(&ctx) {
                        return Err(error);
                    }
                    // SAFETY: take DTOs out before writing to the output channel.
                    let batch_started = Instant::now();
                    let (batch, calls) = unsafe {
                        let state = &mut *native.inner.get();
                        (
                            state.tree.flush(&surface, generation),
                            std::mem::take(&mut state.outbox),
                        )
                    };
                    worker.elapsed("native_batch_us", batch_started);
                    if super::telemetry::enabled() {
                        unsafe {
                            let state = &*native.inner.get();
                            let (nodes, subscriptions) = state.graph.resource_counts();
                            worker.snapshot([
                                ("ui_nodes", state.tree.nodes.len()),
                                ("graph_nodes", nodes),
                                ("subscriptions", subscriptions),
                                ("timers", state.timers.len()),
                                ("pending_host", state.calls.len()),
                                ("event_handlers", state.tree.listeners.len()),
                            ]);
                        }
                    }
                    if let Some(batch) = batch {
                        output(UiOutput::Batch(batch))
                            .map_err(|_| "UI output closed".to_string())?;
                    }
                    for call in calls {
                        output(call).map_err(|_| "UI output closed".to_string())?;
                    }
                    if closed.load(Ordering::Acquire) {
                        return Ok(());
                    }
                    let command = if let Some(delay) = bindings::next_timer(&native) {
                        match commands.recv_timeout(delay) {
                            Ok(command) => Some(command),
                            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => None,
                            Err(_) => return Ok(()),
                        }
                    } else {
                        match commands.recv() {
                            Ok(command) => Some(command),
                            Err(_) => return Ok(()),
                        }
                    };
                    deadline.store(
                        origin.elapsed().as_micros() as u64 + 2_000_000,
                        Ordering::Release,
                    );
                    let Some(command) = command else {
                        bindings::tick_timers(&ctx).map_err(|e| diagnostic(&ctx, e))?;
                        continue;
                    };
                    queued.fetch_sub(
                        command.size().min(queued.load(Ordering::Acquire)),
                        Ordering::AcqRel,
                    );
                    deadline.store(
                        origin.elapsed().as_micros() as u64 + 2_000_000,
                        Ordering::Release,
                    );
                    let track_js = matches!(
                        &command,
                        Command::Event(_) | Command::Reply { .. } | Command::Environment(_)
                    );
                    let turn_started = Instant::now();
                    let result = match command {
                        Command::Close => return Ok(()),
                        Command::Ack(seq) => unsafe { (*native.inner.get()).tree.ack(seq) },
                        Command::Event(event) => {
                            if event.surface != surface || event.generation != generation {
                                continue;
                            }
                            bindings::dispatch(&ctx, event)
                        }
                        Command::Reply {
                            call_id,
                            value,
                            error,
                        } => bindings::reply(&ctx, call_id, value, error),
                        Command::Environment(environment) => {
                            bindings::set_visibility(&native, &environment);
                            let value = nodes::encode(&ctx, environment)
                                .map_err(|e| diagnostic(&ctx, e))?;
                            let update: rquickjs::Function = ctx
                                .globals()
                                .get("__revericSetEnvironment")
                                .map_err(|e| diagnostic(&ctx, e))?;
                            update.call::<_, ()>((value,))
                        }
                    };
                    if track_js {
                        worker.elapsed("js_reactive_us", turn_started);
                    }
                    result.map_err(|e| diagnostic(&ctx, e))?;
                }
            })();
            // Interruption remains bounded during cooperative cleanup. Disable
            // the external close flag check only for this one cleanup window.
            cleaning.store(true, Ordering::Release);
            deadline.store(
                origin.elapsed().as_micros() as u64 + 2_000_000,
                Ordering::Release,
            );
            let _ = ctx.eval::<(), _>(
                "if (typeof __revericDisposePage === 'function') __revericDisposePage()",
            );
            bindings::teardown(&native);
            result
        })
    })();
    if let Err(message) = result {
        if !closed.load(Ordering::Acquire) {
            let _ = output(UiOutput::Error {
                code: if timed_out.load(Ordering::Acquire) || message.contains("timeout") {
                    "plugin_timeout"
                } else {
                    "plugin_ui_error"
                }
                .into(),
                message,
            });
        }
    }
    closed.store(true, Ordering::Release);
    let _ = output(UiOutput::Closed);
}
fn diagnostic(ctx: &rquickjs::Ctx<'_>, error: rquickjs::Error) -> String {
    if error.is_exception() {
        let value = ctx.catch();
        let message = Coerced::<String>::from_js(ctx, value.clone())
            .map(|value| value.0)
            .unwrap_or_else(|_| "JavaScript exception".into());
        if let Some(object) = value.as_object() {
            if let Ok(stack) = object.get::<_, String>("stack") {
                return format!("{message}\n{stack}");
            }
        }
        return message;
    }
    error.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ui::UiOp;
    use std::sync::mpsc::{SyncSender, channel, sync_channel};
    use std::time::Duration;
    struct Worker {
        commands: SyncSender<Command>,
        output: Receiver<UiOutput>,
        closed: Arc<AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
        // Declared last: released only after Drop has joined the thread.
        _counts: std::sync::RwLockReadGuard<'static, ()>,
    }
    impl Worker {
        fn start(handler: &str) -> Self {
            let source = format!(
                r#"globalThis.__revericView={{mount(context){{
              const n=__revericNative;let count=0;
              n.root(()=>{{const button=n.create('Button');n.set(button,{{label:'0'}});
                n.listen(button,'onPress',async()=>{{{handler}}});n.insert(context.root,button,'children',null);
              }});
            }}}};"#
            );
            Self::from_source(source)
        }
        fn from_source(source: String) -> Self {
            let counts = super::super::telemetry::TEST_COUNTS
                .read()
                .unwrap_or_else(|e| e.into_inner());
            let (tx, rx) = sync_channel(256);
            let (out_tx, out_rx) = channel();
            let closed = Arc::new(AtomicBool::new(false));
            let stop = closed.clone();
            let thread = std::thread::spawn(move || {
                run(
                    "test".into(),
                    1,
                    source,
                    UiValue::Object(std::collections::HashMap::new()),
                    UiValue::Null,
                    move |v| out_tx.send(v).map_err(|_| ()),
                    rx,
                    stop,
                    Arc::new(AtomicUsize::new(0)),
                )
            });
            Self {
                commands: tx,
                output: out_rx,
                closed,
                thread: Some(thread),
                _counts: counts,
            }
        }
        fn batch(&self) -> crate::api::ui::UiBatch {
            loop {
                match self.output.recv_timeout(Duration::from_secs(5)).unwrap() {
                    UiOutput::Batch(batch) => return batch,
                    UiOutput::HostCall { call_id, .. } => self
                        .commands
                        .send(Command::Reply {
                            call_id,
                            value: UiValue::Null,
                            error: None,
                        })
                        .unwrap(),
                    event => panic!("Expected batch, got {event:?}"),
                }
            }
        }
        fn event(&self) -> UiEvent {
            let UiOutput::Batch(batch) = self.output.recv_timeout(Duration::from_secs(5)).unwrap()
            else {
                panic!("expected initial batch");
            };
            let (node, handler) = batch
                .ops
                .iter()
                .find_map(|op| {
                    if let UiOp::Listen {
                        id,
                        handler: Some(handler),
                        ..
                    } = op
                    {
                        Some((*id, *handler))
                    } else {
                        None
                    }
                })
                .unwrap();
            UiEvent {
                surface: "test".into(),
                generation: 1,
                seq: batch.seq,
                node,
                handler,
                event: "onPress".into(),
                payload: UiValue::Null,
            }
        }
        fn stop(&mut self) {
            self.closed.store(true, Ordering::Release);
            let _ = self.commands.send(Command::Close);
            if let Some(thread) = self.thread.take() {
                thread.join().unwrap();
            }
        }
    }
    impl Drop for Worker {
        fn drop(&mut self) {
            self.stop();
        }
    }
    #[test]
    fn compiled_tsx_mounts_and_updates_through_native_graph() {
        let mut worker = Worker::from_source(include_str!("fixtures/counter.js").into());
        let batch = worker.batch();
        assert!(batch.ops.iter().any(|op|matches!(op,UiOp::Set{props,..} if props.get("text")==Some(&UiValue::String("Count 0".into())))));
        let (node, handler) = batch
            .ops
            .iter()
            .find_map(|op| {
                if let UiOp::Listen {
                    id,
                    handler: Some(handler),
                    event,
                } = op
                {
                    if event == "onPress" {
                        Some((*id, *handler))
                    } else {
                        None
                    }
                } else {
                    None
                }
            })
            .unwrap();
        worker.commands.send(Command::Ack(1)).unwrap();
        worker
            .commands
            .send(Command::Event(UiEvent {
                surface: "test".into(),
                generation: 1,
                seq: 1,
                node,
                handler,
                event: "onPress".into(),
                payload: UiValue::Null,
            }))
            .unwrap();
        let batch = worker.batch();
        assert!(batch.ops.iter().any(|op|matches!(op,UiOp::Set{props,..} if props.get("text")==Some(&UiValue::String("Count 1".into())))));
        assert!(batch.ops.iter().any(|op|matches!(op,UiOp::Set{props,..} if props.get("text")==Some(&UiValue::String("Positive".into())))));
        worker.stop();
    }
    #[test]
    fn native_thread_batches_until_ack_and_preserves_latest_property() {
        let mut worker = Worker::start("count++;n.set(button,{label:String(count)});");
        let event = worker.event();
        worker.commands.send(Command::Event(event.clone())).unwrap();
        worker.commands.send(Command::Event(event)).unwrap();
        worker.commands.send(Command::Ack(1)).unwrap();
        let UiOutput::Batch(batch) = worker.output.recv_timeout(Duration::from_secs(3)).unwrap()
        else {
            panic!("expected next batch");
        };
        assert_eq!(batch.seq, 2);
        let labels: Vec<_> = batch
            .ops
            .iter()
            .filter_map(|op| {
                if let UiOp::Set { props, .. } = op {
                    props.get("label")
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(labels, vec![&UiValue::String("2".into())]);
        worker.stop();
    }
    #[test]
    fn native_thread_interrupts_infinite_event_and_microtasks() {
        for handler in [
            "while(true){}",
            "Promise.resolve().then(function loop(){Promise.resolve().then(loop);});",
        ] {
            let mut worker = Worker::start(handler);
            let event = worker.event();
            worker.commands.send(Command::Event(event)).unwrap();
            let UiOutput::Error { code, .. } =
                worker.output.recv_timeout(Duration::from_secs(4)).unwrap()
            else {
                panic!("expected timeout");
            };
            assert_eq!(code, "plugin_timeout");
            assert!(matches!(
                worker.output.recv_timeout(Duration::from_secs(3)).unwrap(),
                UiOutput::Closed
            ));
            worker.stop();
        }
    }
    #[test]
    fn native_thread_reports_async_and_unhandled_rejections() {
        for handler in [
            "throw new Error('event rejection');",
            "Promise.reject(new Error('manual rejection'));",
        ] {
            let mut worker = Worker::start(handler);
            let event = worker.event();
            worker.commands.send(Command::Event(event)).unwrap();
            let UiOutput::Error { message, .. } =
                worker.output.recv_timeout(Duration::from_secs(3)).unwrap()
            else {
                panic!("expected rejection diagnostic");
            };
            assert!(message.contains("rejection"));
            worker.stop();
        }
    }
    fn press(batch: &crate::api::ui::UiBatch) -> UiEvent {
        let (node, handler) = batch
            .ops
            .iter()
            .rev()
            .find_map(|op| match op {
                UiOp::Listen {
                    id,
                    handler: Some(handler),
                    event,
                } if event == "onPress" => Some((*id, *handler)),
                _ => None,
            })
            .unwrap();
        UiEvent {
            surface: "test".into(),
            generation: 1,
            seq: batch.seq,
            node,
            handler,
            event: "onPress".into(),
            payload: UiValue::Null,
        }
    }
    fn sets(batch: &crate::api::ui::UiBatch, key: &str, value: &str) -> bool {
        batch.ops.iter().any(|op| {
            matches!(op, UiOp::Set { props, .. } if props.get(key) == Some(&UiValue::String(value.into())))
        })
    }
    #[test]
    fn error_boundary_contains_event_failures_and_resets() {
        for handler in [
            "()=>{throw new Error('boom');}",
            "async()=>{await 0;throw new Error('boom');}",
        ] {
            let mut worker = Worker::from_source(format!(
                r#"globalThis.__revericView={{mount(context){{const ui=__revericUi;
                  ui.mount(()=>ui.ErrorBoundary({{
                    fallback:(error,reset)=>ui.element('Button',{{label:'Failed '+error.message,onPress:reset}}),
                    get children(){{return ui.element('Button',{{label:'Go',onPress:{handler}}});}},
                  }}),context.root);
                }}}};"#
            ));
            let batch = worker.batch();
            assert!(sets(&batch, "label", "Go"));
            worker.commands.send(Command::Ack(1)).unwrap();
            worker.commands.send(Command::Event(press(&batch))).unwrap();
            let batch = worker.batch();
            assert!(sets(&batch, "label", "Failed boom"));
            worker.commands.send(Command::Ack(2)).unwrap();
            worker.commands.send(Command::Event(press(&batch))).unwrap();
            assert!(sets(&worker.batch(), "label", "Go"));
            worker.stop();
        }
    }
    #[test]
    fn invalid_props_name_component_and_view_frame() {
        let worker = Worker::from_source(
            "globalThis.__revericView={mount(context){const ui=__revericUi;\nui.mount(()=>ui.element('Text',{text:'x',tone:'loud'}),context.root);}};".into(),
        );
        let UiOutput::Error { message, .. } =
            worker.output.recv_timeout(Duration::from_secs(3)).unwrap()
        else {
            panic!("expected validation error");
        };
        assert!(
            message.contains("Invalid Text.tone: expected default | muted"),
            "{message}"
        );
        assert!(message.contains("plugin-view.js:2"), "{message}");
    }
    #[test]
    fn view_cannot_run_strings_or_patch_shared_prototypes() {
        let worker = Worker::from_source(
            r#"globalThis.__revericView={mount(context){const ui=__revericUi;
              const throws=f=>{try{f();return false}catch(e){return e instanceof TypeError}};
              const patched=!throws(()=>{Array.prototype.evil=1});
              function Sub(){} Sub.prototype.constructor=Sub;
              const own={}; own.toString=()=>'own';
              const checks=[typeof eval==='undefined',throws(()=>Function('return 1')),
                throws(()=>(async()=>{}).constructor('return 1')),throws(()=>(function*(){}).constructor('')),
                !patched&&!('evil' in []),Object.isFrozen(Object.prototype),Sub.prototype.constructor===Sub,
                String(own)==='own',({}).toString()==='[object Object]'];
              ui.mount(()=>ui.element('Text',{text:checks.join(',')}),context.root);}};"#
                .into(),
        );
        let batch = worker.batch();
        let expected = vec!["true"; 9].join(",");
        assert!(
            batch.ops.iter().any(|op| matches!(op, UiOp::Set { props, .. } if props.get("text") == Some(&UiValue::String(expected.clone())))),
            "{:?}",
            batch.ops
        );
    }
    #[test]
    fn text_values_echo_normalization_even_when_the_last_sent_value_matches() {
        for component in ["TextField", "SearchField"] {
            let mut worker = Worker::from_source(format!(
                r#"globalThis.__revericView={{mount(context){{const ui=__revericUi;
                  ui.mount(()=>{{const raw=ui.signal('A');
                    return ui.element('{component}',{{get value(){{return raw().toUpperCase();}},
                      onChange:event=>raw.set(event.value)}});
                  }},context.root);
                }}}};"#
            ));
            let batch = worker.batch();
            assert!(sets(&batch, "value", "A"));
            let (node, handler) = batch
                .ops
                .iter()
                .find_map(|op| match op {
                    UiOp::Listen {
                        id,
                        handler: Some(handler),
                        event,
                    } if event == "onChange" => Some((*id, *handler)),
                    _ => None,
                })
                .unwrap();
            worker.commands.send(Command::Ack(batch.seq)).unwrap();
            worker
                .commands
                .send(Command::Event(UiEvent {
                    surface: "test".into(),
                    generation: 1,
                    seq: batch.seq,
                    node,
                    handler,
                    event: "onChange".into(),
                    payload: UiValue::Object(std::collections::HashMap::from([
                        ("value".into(), UiValue::String("a".into())),
                        ("editRevision".into(), UiValue::Number(1.0)),
                    ])),
                }))
                .unwrap();
            let batch = worker.batch();
            assert!(
                batch.ops.iter().any(|op| matches!(op,
                    UiOp::Set { id, props, edit_revision: Some(1), .. }
                        if *id == node && props.get("value") == Some(&UiValue::String("A".into()))
                )),
                "{:?}",
                batch.ops
            );
            worker.stop();
        }
    }
    #[test]
    fn submit_records_the_edit_revision_its_writes_answer() {
        let mut worker = Worker::from_source(
            r#"globalThis.__revericView={mount(context){const n=__revericNative;
              n.root(()=>{const field=n.create('TextField');n.set(field,{value:'draft'});
                n.listen(field,'onSubmit',()=>n.set(field,{value:''}));n.insert(context.root,field,'children',null);});
            }};"#
                .into(),
        );
        let batch = worker.batch();
        let (node, handler) = batch
            .ops
            .iter()
            .find_map(|op| match op {
                UiOp::Listen {
                    id,
                    handler: Some(handler),
                    ..
                } => Some((*id, *handler)),
                _ => None,
            })
            .unwrap();
        worker.commands.send(Command::Ack(1)).unwrap();
        let payload = std::collections::HashMap::from([
            ("value".to_string(), UiValue::String("typed".into())),
            ("editRevision".to_string(), UiValue::Number(3.0)),
        ]);
        worker
            .commands
            .send(Command::Event(UiEvent {
                surface: "test".into(),
                generation: 1,
                seq: batch.seq,
                node,
                handler,
                event: "onSubmit".into(),
                payload: UiValue::Object(payload),
            }))
            .unwrap();
        let batch = worker.batch();
        assert!(
            batch.ops.iter().any(|op| matches!(op, UiOp::Set { props, edit_revision: Some(3), .. } if props.get("value") == Some(&UiValue::String(String::new())))),
            "{:?}",
            batch.ops
        );
        worker.stop();
    }
    #[test]
    fn native_thread_close_cancels_pending_host_promise() {
        let mut worker = Worker::start(
            "await n.call('http.fetch',{url:'https://example.com'});n.set(button,{label:'late'});",
        );
        let event = worker.event();
        worker.commands.send(Command::Event(event)).unwrap();
        assert!(matches!(
            worker.output.recv_timeout(Duration::from_secs(2)).unwrap(),
            UiOutput::HostCall { .. }
        ));
        worker.closed.store(true, Ordering::Release);
        worker.commands.send(Command::Close).unwrap();
        assert!(matches!(
            worker.output.recv_timeout(Duration::from_secs(3)).unwrap(),
            UiOutput::Closed
        ));
        assert!(
            worker
                .output
                .recv_timeout(Duration::from_millis(20))
                .is_err()
        );
        worker.stop();
    }
}
