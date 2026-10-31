use crate::api::error::JsError;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use tokio::sync::Notify;

#[derive(Clone, Default)]
pub(crate) struct RuntimeShutdown {
    inner: Arc<RuntimeShutdownState>,
}

#[derive(Default)]
struct RuntimeShutdownState {
    cause: AtomicU8,
    timeout_millis: AtomicU64,
    notify: Notify,
}

impl RuntimeShutdown {
    pub(crate) fn request(&self) {
        if self
            .inner
            .cause
            .compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            self.inner.notify.notify_waiters();
        }
    }

    pub(crate) fn request_timeout(&self, millis: u64) {
        self.inner.timeout_millis.store(millis, Ordering::Relaxed);
        if self
            .inner
            .cause
            .compare_exchange(0, 2, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            self.inner.notify.notify_waiters();
        }
    }

    pub(crate) fn requested(&self) -> bool {
        self.inner.cause.load(Ordering::Acquire) != 0
    }

    pub(crate) fn error(&self) -> JsError {
        if self.inner.cause.load(Ordering::Acquire) == 2 {
            JsError::timeout(
                "continuous JavaScript",
                self.inner.timeout_millis.load(Ordering::Relaxed),
            )
        } else {
            JsError::cancelled("JavaScript engine was closed")
        }
    }

    pub(crate) async fn cancelled(&self) {
        loop {
            if self.requested() {
                return;
            }
            let notified = self.inner.notify.notified();
            if self.requested() {
                return;
            }
            notified.await;
        }
    }
}
