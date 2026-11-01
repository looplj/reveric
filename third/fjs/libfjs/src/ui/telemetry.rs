//! Read-only lifecycle/resource diagnostics; graph snapshots are opt-in.
use std::collections::HashMap;
use std::sync::{
    LazyLock, Mutex,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
static ENABLED: AtomicBool = AtomicBool::new(false);
static NEXT: AtomicU64 = AtomicU64::new(1);
static WORKERS: LazyLock<Mutex<HashMap<u64, HashMap<String, u64>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Counts are process-wide: tests that start workers hold a read guard, and
/// tests asserting exact counts hold the write guard so nothing overlaps.
#[cfg(test)]
pub(crate) static TEST_COUNTS: std::sync::RwLock<()> = std::sync::RwLock::new(());

pub(crate) struct Worker(pub u64);
impl Worker {
    pub fn new() -> Self {
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        WORKERS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, HashMap::from([("threads".into(), 1)]));
        Self(id)
    }
    pub fn engine(&self) -> Engine {
        WORKERS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_mut(&self.0)
            .unwrap()
            .insert("engines".into(), 1);
        Engine(self.0)
    }
    pub fn elapsed(&self, key: &str, start: std::time::Instant) {
        if !ENABLED.load(Ordering::Relaxed) {
            return;
        }
        let micros = start.elapsed().as_micros() as u64;
        if let Some(row) = WORKERS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_mut(&self.0)
        {
            *row.entry(key.into()).or_default() += micros;
        }
    }
    pub fn snapshot(&self, values: [(&str, usize); 6]) {
        if !ENABLED.load(Ordering::Relaxed) {
            return;
        }
        let mut workers = WORKERS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(row) = workers.get_mut(&self.0) {
            for (name, value) in values {
                row.insert(name.into(), value as u64);
            }
        }
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        WORKERS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.0);
    }
}
pub(crate) struct Engine(u64);
impl Drop for Engine {
    fn drop(&mut self) {
        if let Some(row) = WORKERS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_mut(&self.0)
        {
            row.retain(|key, _| key == "threads");
        }
    }
}
pub(crate) fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

pub(crate) fn counts() -> HashMap<String, u64> {
    ENABLED.store(true, Ordering::Relaxed);
    let mut result: HashMap<String, u64> = [
        "threads",
        "engines",
        "ui_nodes",
        "graph_nodes",
        "subscriptions",
        "timers",
        "pending_host",
        "event_handlers",
        "js_reactive_us",
        "native_batch_us",
    ]
    .into_iter()
    .map(|name| (name.into(), 0))
    .collect();
    for row in WORKERS.lock().unwrap_or_else(|e| e.into_inner()).values() {
        for (name, value) in row {
            *result.entry(name.clone()).or_default() += value;
        }
    }
    result
}
