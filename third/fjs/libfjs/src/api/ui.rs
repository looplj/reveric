//! Typed protocol and asynchronous command handle for native plugin pages.
use crate::{api::error::JsError, frb_generated::StreamSink, ui::session};
use flutter_rust_bridge::frb;
use std::collections::HashMap;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
    mpsc::{SyncSender, sync_channel},
};

/// Values permitted in UI properties, events and host messages.
#[derive(Debug, Clone, PartialEq)]
pub enum UiValue {
    /// JSON null.
    Null,
    /// Boolean value.
    Boolean(bool),
    /// Finite JavaScript number.
    Number(f64),
    /// UTF-8 text.
    String(String),
    /// Ordered values.
    Array(Vec<UiValue>),
    /// Named values.
    Object(HashMap<String, UiValue>),
}

/// A single ordered tree operation. IDs are scoped to one surface generation.
#[derive(Debug, Clone)]
#[allow(missing_docs)]
pub enum UiOp {
    Create {
        id: u64,
        component: String,
    },
    Set {
        id: u64,
        props: HashMap<String, UiValue>,
        unset: Vec<String>,
        edit_revision: Option<u64>,
    },
    Insert {
        parent: u64,
        child: u64,
        slot: String,
        before: Option<u64>,
    },
    Remove {
        parent: u64,
        child: u64,
        slot: String,
    },
    Listen {
        id: u64,
        event: String,
        handler: Option<u64>,
    },
    Release {
        id: u64,
    },
}

/// Atomic tree update awaiting a matching acknowledgement.
#[derive(Debug, Clone)]
#[allow(missing_docs)]
pub struct UiBatch {
    pub surface: String,
    pub generation: u32,
    pub seq: u64,
    pub ops: Vec<UiOp>,
}

/// A host event referencing an already committed tree.
#[derive(Debug, Clone)]
#[allow(missing_docs)]
pub struct UiEvent {
    pub surface: String,
    pub generation: u32,
    pub seq: u64,
    pub node: u64,
    pub handler: u64,
    pub event: String,
    pub payload: UiValue,
}

/// The only messages emitted by a page's native thread.
#[derive(Debug, Clone)]
#[allow(missing_docs)]
pub enum UiOutput {
    Batch(UiBatch),
    HostCall {
        call_id: u64,
        method: String,
        args: UiValue,
    },
    Error {
        code: String,
        message: String,
    },
    Closed,
}

/// Sendable command handle. JavaScript values never leave the worker thread.
#[frb(opaque)]
pub struct UiSession {
    sender: Mutex<Option<SyncSender<session::Command>>>,
    closed: Arc<AtomicBool>,
    queued_bytes: Arc<AtomicUsize>,
    worker: Mutex<Option<std::thread::JoinHandle<()>>>,
}

impl UiSession {
    /// Allocate a handle before subscribing to its output stream.
    #[frb(sync)]
    pub fn create() -> Self {
        Self {
            sender: Mutex::new(None),
            closed: Arc::new(AtomicBool::new(false)),
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            worker: Mutex::new(None),
        }
    }

    /// Start exactly one dedicated QuickJS thread; root node ID is always 1.
    pub fn start(
        &self,
        surface: String,
        generation: u32,
        source: String,
        scope: UiValue,
        environment: UiValue,
        output: StreamSink<UiOutput>,
    ) -> Result<(), JsError> {
        self.start_worker(
            surface,
            generation,
            source,
            scope,
            environment,
            move |value| output.add(value).map_err(|_| ()),
        )
    }

    fn start_worker(
        &self,
        surface: String,
        generation: u32,
        source: String,
        scope: UiValue,
        environment: UiValue,
        output: impl Fn(UiOutput) -> Result<(), ()> + Send + 'static,
    ) -> Result<(), JsError> {
        if source.len() > 2 * 1024 * 1024 || surface.is_empty() {
            return Err(JsError::engine("Invalid UI source or surface"));
        }
        let mut sender = self
            .sender
            .lock()
            .map_err(|_| JsError::engine("UI handle poisoned"))?;
        if sender.is_some() || self.closed.load(Ordering::Acquire) {
            return Err(JsError::engine("UI session already started or closed"));
        }
        let (tx, rx) = sync_channel(256);
        *sender = Some(tx);
        let closed = self.closed.clone();
        let queued = self.queued_bytes.clone();
        let worker = std::thread::Builder::new()
            .name(format!("plugin-ui-{surface}"))
            .spawn(move || {
                session::run(
                    surface,
                    generation,
                    source,
                    scope,
                    environment,
                    output,
                    rx,
                    closed,
                    queued,
                );
            })
            .map_err(|error| JsError::engine(error.to_string()))?;
        *self
            .worker
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(worker);
        Ok(())
    }

    /// Read actual worker/runtime counts and opt in to quiescent graph snapshots.
    #[frb(sync)]
    pub fn resource_counts() -> HashMap<String, u64> {
        crate::ui::telemetry::counts()
    }

    /// Enqueue an event without waiting for JavaScript or any host promise.
    pub fn dispatch(&self, event: UiEvent) -> Result<(), JsError> {
        self.send(session::Command::Event(event))
    }
    /// Resolve or reject an asynchronous host request on the owning thread.
    pub fn reply_host(
        &self,
        call_id: u64,
        value: UiValue,
        error: Option<String>,
    ) -> Result<(), JsError> {
        self.send(session::Command::Reply {
            call_id,
            value,
            error,
        })
    }
    /// Confirm an atomic Flutter tree update.
    pub fn ack_batch(&self, seq: u64) -> Result<(), JsError> {
        self.send(session::Command::Ack(seq))
    }
    /// Update viewport, theme, locale, platform and visibility.
    pub fn set_environment(&self, environment: UiValue) -> Result<(), JsError> {
        self.send(session::Command::Environment(environment))
    }
    /// Invalidate immediately, then wait off the UI thread for native teardown.
    pub fn close(&self) {
        self.request_close();
        self.join_worker();
    }
    fn request_close(&self) {
        self.closed.store(true, Ordering::Release);
        let sender = self
            .sender
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if let Some(sender) = sender.as_ref() {
            let _ = sender.try_send(session::Command::Close);
        }
    }
    fn join_worker(&self) {
        // Keep the lock while joining: every concurrent close observes the same
        // completed teardown, rather than treating a taken handle as completion.
        let mut worker = self
            .worker
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if let Some(thread) = worker.take() {
            let _ = thread.join();
        }
    }
    fn send(&self, command: session::Command) -> Result<(), JsError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(JsError::engine("UI session is closed"));
        }
        let guard = self
            .sender
            .lock()
            .map_err(|_| JsError::engine("UI handle poisoned"))?;
        let sender = guard
            .as_ref()
            .ok_or_else(|| JsError::engine("UI session has not started"))?;
        let size = command.size();
        let previous = self.queued_bytes.fetch_add(size, Ordering::AcqRel);
        if previous + size > 1024 * 1024 {
            self.queued_bytes.fetch_sub(size, Ordering::AcqRel);
            return Err(JsError::engine(
                "plugin_ui_busy: command byte budget exceeded",
            ));
        }
        let result = sender.try_send(command);
        if result.is_err() {
            self.queued_bytes.fetch_sub(size, Ordering::AcqRel);
            return Err(JsError::engine(
                "plugin_ui_busy: command queue is full or closed",
            ));
        }
        Ok(())
    }
}
impl Drop for UiSession {
    fn drop(&mut self) {
        self.request_close();
        if let Some(worker) = self
            .worker
            .get_mut()
            .unwrap_or_else(|error| error.into_inner())
            .take()
        {
            // Opaque finalization may run through synchronous FFI. Preserve the
            // join on a reaper instead of blocking the Dart UI thread.
            std::thread::spawn(move || {
                let _ = worker.join();
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::mpsc::channel,
        time::{Duration, Instant},
    };
    #[test]
    fn production_handle_joins_slow_cleanup_for_concurrent_close_callers() {
        let _counts = crate::ui::telemetry::TEST_COUNTS
            .write()
            .unwrap_or_else(|e| e.into_inner());
        assert!(
            UiSession::resource_counts()
                .values()
                .all(|count| *count == 0)
        );
        let page = Arc::new(UiSession::create());
        let (tx, rx) = channel();
        page.start_worker(
            "join-test".into(),
            1,
            r#"
var __revericView={mount(context){
 const ui=__revericNative;
 __revericUi.mount(()=>{ui.cleanup(()=>{const end=Date.now()+180;while(Date.now()<end){}});
 const node=ui.create('Text');ui.set(node,{text:'ready'});return node;
 }, context.root);
}};
"#
            .into(),
            UiValue::Object(HashMap::new()),
            UiValue::Null,
            move |value| tx.send(value).map_err(|_| ()),
        )
        .unwrap();
        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(3)).unwrap(),
            UiOutput::Batch(_)
        ));
        assert_eq!(UiSession::resource_counts()["engines"], 1);
        let started = Instant::now();
        let first = page.clone();
        let first = std::thread::spawn(move || first.close());
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(UiSession::resource_counts()["engines"], 1);
        page.close();
        first.join().unwrap();
        assert!(started.elapsed() >= Duration::from_millis(150));
        assert!(
            UiSession::resource_counts()
                .values()
                .all(|count| *count == 0)
        );
    }
    #[test]
    fn production_drop_joins_bounded_cleanup_and_releases_pending_host() {
        let _counts = crate::ui::telemetry::TEST_COUNTS
            .write()
            .unwrap_or_else(|e| e.into_inner());
        assert!(
            UiSession::resource_counts()
                .values()
                .all(|count| *count == 0)
        );
        let page = UiSession::create();
        let (tx, rx) = channel();
        page.start_worker(
            "drop-test".into(),
            1,
            r#"
var __revericView={mount(context){
 const ui=__revericNative;
 __revericUi.mount(()=>{ui.cleanup(()=>{while(true){}});
 ui.call('storage.get',{key:'pending'});
 const node=ui.create('Text');ui.set(node,{text:'ready'});return node;
 }, context.root);
}};
"#
            .into(),
            UiValue::Object(HashMap::new()),
            UiValue::Null,
            move |value| tx.send(value).map_err(|_| ()),
        )
        .unwrap();
        loop {
            if matches!(
                rx.recv_timeout(Duration::from_secs(3)).unwrap(),
                UiOutput::HostCall { .. }
            ) {
                break;
            }
        }
        assert_eq!(UiSession::resource_counts()["pending_host"], 1);
        let started = Instant::now();
        drop(page);
        assert!(started.elapsed() < Duration::from_millis(100));
        assert_eq!(UiSession::resource_counts()["engines"], 1);
        while UiSession::resource_counts()
            .values()
            .any(|count| *count != 0)
        {
            assert!(started.elapsed() < Duration::from_secs(4));
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(started.elapsed() >= Duration::from_secs(1));
    }
}
