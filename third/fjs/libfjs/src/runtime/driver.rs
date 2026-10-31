use crate::runtime::executor;
use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::sync::Notify;

const MAX_ERRORS: usize = 32;
/// Defensive fallback: re-check the runtime even without an explicit wake, in
/// case a waker registration was lost (e.g. a foreground poll displaced the
/// driver's schedular waker without a follow-up notification).
const FALLBACK_POLL_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone, Default)]
pub(crate) struct DriverController {
    inner: Arc<DriverState>,
}

#[derive(Default)]
struct DriverState {
    execution_limit_us: AtomicU64,
    execution_started_us: AtomicU64,
    execution_expired: AtomicBool,
    clock: OnceLock<Instant>,
    next_task_id: AtomicU64,
    next_error_id: AtomicU64,
    lifecycle: Mutex<DriverLifecycle>,
    errors: Mutex<VecDeque<DriverError>>,
    stop_finished: Notify,
    work_added: Notify,
}

struct DriverError {
    id: u64,
    source: DriverErrorSource,
    message: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DriverErrorSource {
    Unattributed,
    Promise(JsValueIdentity),
}

impl DriverErrorSource {
    pub(crate) fn promise(value: &rquickjs::Value<'_>) -> Self {
        Self::Promise(JsValueIdentity::from_value(value))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct JsValueIdentity {
    tag: i32,
    bits: u64,
}

impl JsValueIdentity {
    fn from_value(value: &rquickjs::Value<'_>) -> Self {
        let raw = value.as_raw();
        Self {
            // SAFETY: `raw` is the valid `JSValue` representation borrowed from
            // `value`; reading its tag does not take ownership or mutate it.
            tag: unsafe { rquickjs::qjs::JS_VALUE_GET_TAG(raw) },
            // SAFETY: `raw` is the same valid `JSValue` representation. QuickJS's
            // accessor returns its payload bits without taking ownership.
            bits: unsafe { rquickjs::qjs::JS_VALUE_GET_FLOAT64(raw).to_bits() },
        }
    }
}

#[derive(Default)]
enum DriverLifecycle {
    #[default]
    Idle,
    Running {
        task_id: u64,
        handle: tokio::task::JoinHandle<()>,
    },
    Stopping {
        task_id: u64,
    },
}

impl DriverController {
    pub(crate) fn set_execution_time_limit(&self, limit_millis: Option<u32>) {
        self.inner.execution_started_us.store(0, Ordering::Release);
        self.inner.execution_expired.store(false, Ordering::Release);
        self.inner.execution_limit_us.store(
            u64::from(limit_millis.unwrap_or(0)) * 1000,
            Ordering::Release,
        );
    }
    fn clock_us(&self) -> u64 {
        self.inner
            .clock
            .get_or_init(Instant::now)
            .elapsed()
            .as_micros() as u64
            + 1
    }
    fn arm_execution(&self) {
        if self.inner.execution_limit_us.load(Ordering::Acquire) != 0 {
            let _ = self.inner.execution_started_us.compare_exchange(
                0,
                self.clock_us(),
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
    }
    fn idle_execution(&self) {
        self.inner.execution_started_us.store(0, Ordering::Release);
    }
    pub(crate) fn execution_interrupted(&self) -> bool {
        let limit = self.inner.execution_limit_us.load(Ordering::Acquire);
        if limit == 0 {
            return false;
        }
        if self.inner.execution_expired.load(Ordering::Acquire) {
            return true;
        }
        let started = self.inner.execution_started_us.load(Ordering::Acquire);
        if started != 0 && self.clock_us().saturating_sub(started) >= limit {
            self.inner.execution_expired.store(true, Ordering::Release);
            return true;
        }
        false
    }
    pub(crate) fn execution_timeout_millis(&self) -> u64 {
        self.inner.execution_limit_us.load(Ordering::Acquire) / 1000
    }
    pub(crate) async fn with_execution_budget<F: Future>(&self, future: F) -> F::Output {
        if self.inner.execution_limit_us.load(Ordering::Acquire) == 0 {
            return future.await;
        }
        let mut future = Box::pin(future);
        std::future::poll_fn(|cx| {
            self.arm_execution();
            let result = future.as_mut().poll(cx);
            if result.is_pending() {
                self.notify_work();
            }
            result
        })
        .await
    }

    pub(crate) fn start(&self, runtime: rquickjs::AsyncRuntime) {
        let driver = self.clone();
        self.start_task(async move {
            drive_runtime(runtime, driver).await;
        });
    }

    fn start_task<F>(&self, future: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        let mut lifecycle = self
            .inner
            .lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !matches!(*lifecycle, DriverLifecycle::Idle) {
            return;
        }

        let task_id = self.inner.next_task_id.fetch_add(1, Ordering::AcqRel);
        let state = self.inner.clone();
        let handle = executor::spawn_js(async move {
            let _guard = DriverTaskGuard {
                state: state.clone(),
                task_id,
            };
            future.await;
        });

        *lifecycle = DriverLifecycle::Running { task_id, handle };
    }

    pub(crate) async fn stop(&self) {
        match self.stop_action() {
            StopAction::Wait => self.wait_until_idle().await,
            StopAction::Done => {}
        }
    }

    fn stop_action(&self) -> StopAction {
        let mut lifecycle = self
            .inner
            .lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match std::mem::take(&mut *lifecycle) {
            DriverLifecycle::Running { task_id, handle } => {
                *lifecycle = DriverLifecycle::Stopping { task_id };
                self.spawn_abort_watcher(task_id, handle);
                StopAction::Wait
            }
            DriverLifecycle::Stopping { task_id } => {
                *lifecycle = DriverLifecycle::Stopping { task_id };
                StopAction::Wait
            }
            DriverLifecycle::Idle => StopAction::Done,
        }
    }

    fn spawn_abort_watcher(&self, task_id: u64, handle: tokio::task::JoinHandle<()>) {
        let state = self.inner.clone();
        // Keep teardown moving even if the caller cancels the stop() future.
        executor::spawn_js(async move {
            handle.abort();
            let _ = handle.await;
            state.mark_idle(task_id);
        });
    }

    async fn wait_until_idle(&self) {
        loop {
            let notified = self.inner.stop_finished.notified();
            if matches!(
                *self
                    .inner
                    .lifecycle
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner),
                DriverLifecycle::Idle
            ) {
                return;
            }
            notified.await;
        }
    }

    #[cfg(test)]
    pub(crate) fn running(&self) -> bool {
        matches!(
            *self
                .inner
                .lifecycle
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
            DriverLifecycle::Running { .. }
        )
    }

    pub(crate) fn push_error(&self, error: String) {
        self.push_error_from(DriverErrorSource::Unattributed, error);
    }

    pub(crate) fn push_error_from(&self, source: DriverErrorSource, error: String) {
        let id = self.inner.next_error_id.fetch_add(1, Ordering::AcqRel);
        let mut errors = self
            .inner
            .errors
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if errors.len() == MAX_ERRORS {
            errors.pop_front();
        }
        errors.push_back(DriverError {
            id,
            source,
            message: error,
        });
    }

    pub(crate) fn error_checkpoint(&self) -> u64 {
        self.inner.next_error_id.load(Ordering::Acquire)
    }

    /// Removes the newest queued error for `source`.
    ///
    /// Promise identities are raw value bits; after GC a new promise can reuse
    /// a dead promise's address. Removing only the newest match keeps a stale
    /// queued error for the dead promise from being silently swallowed when
    /// the new promise becomes handled.
    pub(crate) fn remove_error_source(&self, source: DriverErrorSource) {
        let mut errors = self
            .inner
            .errors
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(index) = errors.iter().rposition(|queued| queued.source == source) {
            errors.remove(index);
        }
    }

    pub(crate) fn remove_error_source_since(&self, checkpoint: u64, source: DriverErrorSource) {
        self.remove_errors_matching(|queued| queued.id >= checkpoint && queued.source == source);
    }

    fn remove_errors_matching(&self, mut matches_error: impl FnMut(&DriverError) -> bool) {
        self.inner
            .errors
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .retain(|queued| !matches_error(queued));
    }

    pub(crate) fn drain_errors(&self) -> Vec<String> {
        self.inner
            .errors
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .drain(..)
            .map(|error| error.message)
            .collect()
    }

    /// Signals the driver that foreground work may have scheduled new runtime
    /// jobs (timers, detached promises, spawned futures).
    pub(crate) fn notify_work(&self) {
        self.inner.work_added.notify_one();
    }
}

/// Completes the second time it is polled, i.e. as soon as the owning task is
/// woken for any reason. The QuickJS schedular forwards wakes from spawned
/// futures (timers, IO) to the waker of the task that last polled it, so any
/// wake of the driver task means the runtime may have runnable work again.
struct WokenAgain {
    polled: bool,
}

impl Future for WokenAgain {
    type Output = ();

    fn poll(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<()> {
        if self.polled {
            Poll::Ready(())
        } else {
            self.polled = true;
            Poll::Pending
        }
    }
}

async fn drive_runtime(runtime: rquickjs::AsyncRuntime, driver: DriverController) {
    loop {
        driver.arm_execution();
        match runtime.execute_pending_job().await {
            Ok(true) => continue,
            Ok(false) => {
                driver.idle_execution();
                // Nothing runnable right now. Park until something can change
                // that: an explicit work notification from a foreground call,
                // a schedular wake forwarded from a timer/IO/spawned future,
                // or the defensive fallback tick.
                tokio::select! {
                    biased;
                    _ = driver.inner.work_added.notified() => {}
                    _ = (WokenAgain { polled: false }) => {}
                    _ = tokio::time::sleep(FALLBACK_POLL_INTERVAL) => {}
                }
            }
            Err(error) => {
                let error = crate::runtime::job_error::async_job_context(error.0).await;
                driver.push_error(error.to_string());
            }
        }
    }
}

enum StopAction {
    Wait,
    Done,
}

struct DriverTaskGuard {
    state: Arc<DriverState>,
    task_id: u64,
}

impl Drop for DriverTaskGuard {
    fn drop(&mut self) {
        self.state.mark_idle(self.task_id);
    }
}

impl DriverState {
    fn mark_idle(&self, task_id: u64) {
        let mut lifecycle = self
            .lifecycle
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let matches_current_task = match &*lifecycle {
            DriverLifecycle::Running {
                task_id: current, ..
            }
            | DriverLifecycle::Stopping { task_id: current } => *current == task_id,
            DriverLifecycle::Idle => false,
        };

        if matches_current_task {
            *lifecycle = DriverLifecycle::Idle;
            self.stop_finished.notify_waiters();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{DriverController, DriverErrorSource, JsValueIdentity};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;
    use tokio::sync::oneshot;

    #[test]
    fn error_queue_keeps_newest_entries_when_full() {
        let driver = DriverController::default();

        for index in 0..40 {
            driver.push_error(format!("error {index}"));
        }

        let errors = driver.drain_errors();
        assert_eq!(errors.len(), 32);
        assert_eq!(errors.first().unwrap(), "error 8");
        assert_eq!(errors.last().unwrap(), "error 39");
        assert!(driver.drain_errors().is_empty());
    }

    #[test]
    fn error_queue_removes_handled_error() {
        let driver = DriverController::default();

        let handled = DriverErrorSource::Promise(JsValueIdentity { tag: -1, bits: 1 });
        let pending = DriverErrorSource::Promise(JsValueIdentity { tag: -1, bits: 2 });
        driver.push_error_from(handled, "first".to_string());
        driver.push_error_from(pending, "second".to_string());

        driver.remove_error_source(handled);

        assert_eq!(driver.drain_errors(), vec!["second"]);
    }

    #[test]
    fn error_queue_removes_handled_source_without_matching_same_message() {
        let driver = DriverController::default();
        let foreground = DriverErrorSource::Promise(JsValueIdentity { tag: -1, bits: 1 });
        let background = DriverErrorSource::Promise(JsValueIdentity { tag: -1, bits: 2 });

        driver.push_error_from(background, "Error: same message".to_string());
        driver.push_error_from(foreground, "Error: same message".to_string());

        driver.remove_error_source(foreground);

        assert_eq!(driver.drain_errors(), vec!["Error: same message"]);
    }

    #[test]
    fn error_queue_remove_handled_source_keeps_older_entry_with_reused_identity() {
        let driver = DriverController::default();
        let identity = DriverErrorSource::Promise(JsValueIdentity { tag: -1, bits: 7 });

        driver.push_error_from(identity, "stale promise error".to_string());
        driver.push_error_from(identity, "new promise error".to_string());

        driver.remove_error_source(identity);

        assert_eq!(driver.drain_errors(), vec!["stale promise error"]);
    }

    #[tokio::test]
    async fn stop_waits_for_driver_task_to_finish_before_restart() {
        let driver = DriverController::default();
        let dropped = Arc::new(AtomicBool::new(false));
        let dropped_for_task = dropped.clone();
        let (started_tx, started_rx) = oneshot::channel::<()>();
        let (_tx, rx) = oneshot::channel::<()>();

        driver.start_task(async move {
            let _guard = DriverDropFlag(dropped_for_task);
            let _ = started_tx.send(());
            let _ = rx.await;
        });
        started_rx.await.unwrap();
        assert!(driver.running());

        driver.stop().await;
        assert!(dropped.load(Ordering::Acquire));
        assert!(!driver.running());
    }

    #[tokio::test]
    async fn start_during_stop_does_not_restart_until_stop_finishes() {
        let driver = DriverController::default();
        let (started_tx, started_rx) = oneshot::channel::<()>();
        let (_tx, rx) = oneshot::channel::<()>();

        driver.start_task(async move {
            let _guard = SlowDropFlag;
            let _ = started_tx.send(());
            let _ = rx.await;
        });
        started_rx.await.unwrap();

        let stopping_driver = driver.clone();
        let stop_task = tokio::spawn(async move {
            stopping_driver.stop().await;
        });
        tokio::time::sleep(Duration::from_millis(10)).await;

        driver.start_task(async {});
        assert!(
            !driver.running(),
            "driver restarted while stop was still waiting for the old task"
        );

        stop_task.await.unwrap();
        assert!(!driver.running());
    }

    #[tokio::test]
    async fn overlapping_stops_keep_start_blocked_until_old_task_finishes() {
        let driver = DriverController::default();
        let (started_tx, started_rx) = oneshot::channel::<()>();
        let (_tx, rx) = oneshot::channel::<()>();

        driver.start_task(async move {
            let _guard = SlowDropFlag;
            let _ = started_tx.send(());
            let _ = rx.await;
        });
        started_rx.await.unwrap();

        let stopping_driver = driver.clone();
        let first_stop = tokio::spawn(async move {
            stopping_driver.stop().await;
        });
        tokio::time::sleep(Duration::from_millis(10)).await;

        let second_stop_driver = driver.clone();
        let second_stop = tokio::spawn(async move {
            second_stop_driver.stop().await;
        });
        tokio::time::sleep(Duration::from_millis(10)).await;

        driver.start_task(async {});

        assert!(
            !driver.running(),
            "driver restarted while an earlier stop was still awaiting the old task"
        );

        first_stop.await.unwrap();
        second_stop.await.unwrap();
        assert!(!driver.running());
    }

    #[tokio::test]
    async fn cancelled_stop_does_not_leave_driver_permanently_stopping() {
        let driver = DriverController::default();
        let (started_tx, started_rx) = oneshot::channel::<()>();
        let (_tx, rx) = oneshot::channel::<()>();

        driver.start_task(async move {
            let _guard = SlowDropFlag;
            let _ = started_tx.send(());
            let _ = rx.await;
        });
        started_rx.await.unwrap();

        let stopping_driver = driver.clone();
        let stop_task = tokio::spawn(async move {
            stopping_driver.stop().await;
        });
        tokio::time::sleep(Duration::from_millis(10)).await;

        stop_task.abort();
        let _ = stop_task.await;

        driver.start_task(async {
            std::future::pending::<()>().await;
        });
        assert!(
            !driver.running(),
            "driver restarted while a cancelled stop was still cleaning up the old task"
        );

        tokio::time::timeout(Duration::from_secs(2), driver.wait_until_idle())
            .await
            .expect("cancelled stop should eventually finish driver teardown");

        driver.start_task(async {
            std::future::pending::<()>().await;
        });

        assert!(
            driver.running(),
            "driver stayed permanently blocked after a cancelled stop"
        );
        driver.stop().await;
    }

    struct DriverDropFlag(Arc<AtomicBool>);

    impl Drop for DriverDropFlag {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Release);
        }
    }

    struct SlowDropFlag;

    impl Drop for SlowDropFlag {
        fn drop(&mut self) {
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}
