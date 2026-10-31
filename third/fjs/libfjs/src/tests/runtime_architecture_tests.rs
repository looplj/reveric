//! Tests for the production runtime execution architecture.

use crate::api::engine::JsEngine;
use crate::api::error::{JsError, JsResult};
use crate::api::runtime::{JsAsyncContext, JsAsyncRuntime};
use crate::api::source::{
    JsBuiltinOptions, JsCode, JsModule, JsModuleBytecode, JsModuleBytecodeBundle, JsScriptBytecode,
};
use crate::api::value::JsValue;
use crate::tests::timers_only;
use rquickjs::CatchResultExt;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::oneshot;

const DEEP_RECURSION_PROBE: &str = r#"
globalThis.__fjsDepthProbe = function(limit) {
  let depth = 0;
  function visit() {
    depth += 1;
    if (depth < limit) visit();
  }
  try {
    visit();
    return { ok: true, depth };
  } catch (error) {
    return { ok: false, name: error.name, message: String(error.message), depth };
  }
};
"#;

async fn install_depth_probe(context: &JsAsyncContext) {
    context
        .with_js(async |ctx| {
            ctx.eval::<(), _>(DEEP_RECURSION_PROBE).catch(&ctx).unwrap();
        })
        .await;
}

async fn probe_depth(context: &JsAsyncContext, limit: usize) -> (bool, i64, String) {
    context
        .with_js(async move |ctx| {
            let script = format!("globalThis.__fjsDepthProbe({limit})");
            let object: rquickjs::Object = ctx.eval(script).catch(&ctx).unwrap();
            let ok: bool = object.get("ok").unwrap();
            let depth: i64 = object.get("depth").unwrap();
            let name: String = object.get("name").unwrap_or_default();
            (ok, depth, name)
        })
        .await
}

async fn runtime_and_context_from_new() -> (JsAsyncRuntime, JsAsyncContext) {
    let runtime = JsAsyncRuntime::new().unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();
    install_depth_probe(&context).await;
    (runtime, context)
}

async fn runtime_and_context_from_create() -> (JsAsyncRuntime, JsAsyncContext) {
    let runtime = JsAsyncRuntime::create(None, None).await.unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();
    install_depth_probe(&context).await;
    (runtime, context)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn async_runtime_constructors_apply_same_generous_stack_default() {
    let (_new_runtime, new_context) = runtime_and_context_from_new().await;
    let (_created_runtime, created_context) = runtime_and_context_from_create().await;

    let new_result = probe_depth(&new_context, 500).await;
    let created_result = probe_depth(&created_context, 500).await;

    assert!(
        new_result.0,
        "new() runtime should reach depth 500 by default, got {new_result:?}"
    );
    assert!(
        created_result.0,
        "create() runtime should reach depth 500 by default, got {created_result:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn async_stack_limit_zero_is_clamped_to_catchable_range_error() {
    let (runtime, context) = runtime_and_context_from_new().await;
    runtime.set_max_stack_size(0).await;

    let result = probe_depth(&context, 100_000).await;

    assert!(!result.0, "oversized recursion should not complete");
    assert_eq!(result.2, "RangeError");
    assert!(result.1 > 0, "RangeError should happen after entering JS");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn async_eval_runs_on_fjs_js_thread() {
    let runtime = JsAsyncRuntime::new().unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    let thread_name = context
        .with_js(async |ctx| {
            let globals = ctx.globals();
            let current_thread_name = rquickjs::Function::new(ctx.clone(), || {
                std::thread::current()
                    .name()
                    .unwrap_or("unnamed")
                    .to_string()
            })
            .catch(&ctx)
            .unwrap();
            globals
                .set("currentThreadName", current_thread_name)
                .catch(&ctx)
                .unwrap();
            ctx.eval::<String, _>("currentThreadName()")
                .catch(&ctx)
                .unwrap()
        })
        .await;

    assert_eq!(thread_name, "fjs-js");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn execute_pending_job_runs_on_fjs_js_thread() {
    let runtime = JsAsyncRuntime::new().unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    context
        .with_js(async |ctx| {
            let globals = ctx.globals();
            let current_thread_name = rquickjs::Function::new(
                ctx.clone(),
                || std::thread::current().name().unwrap_or("unnamed").to_string(),
            )
            .catch(&ctx)
            .unwrap();
            globals
                .set("currentThreadName", current_thread_name)
                .catch(&ctx)
                .unwrap();
            ctx.eval::<(), _>(
                "Promise.resolve().then(() => { globalThis.__jobThreadName = currentThreadName(); });",
            )
            .catch(&ctx)
            .unwrap();
        })
        .await;

    while runtime.execute_pending_job().await.unwrap() {}

    let thread_name = context
        .with_js(async |ctx| {
            ctx.eval::<String, _>("globalThis.__jobThreadName")
                .catch(&ctx)
                .unwrap()
        })
        .await;

    assert_eq!(thread_name, "fjs-js");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_background_driver_progresses_detached_timers_without_manual_pump() {
    let engine = JsEngine::create(Some(timers_only()), None, None)
        .await
        .unwrap();
    engine.init_without_bridge().await.unwrap();

    let scheduled = engine
        .eval(
            JsCode::Code(
                r#"
                setTimeout(() => {
                  globalThis.__driverTimerDone = true;
                }, 10);
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await;
    assert!(matches!(scheduled, Ok(JsValue::String(ref value)) if value == "scheduled"));

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let done = engine
            .eval(
                JsCode::Code("globalThis.__driverTimerDone === true".to_string()),
                None,
            )
            .await
            .unwrap();
        if matches!(done, JsValue::Boolean(true)) {
            break;
        }
        assert!(Instant::now() < deadline, "background timer did not fire");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn background_driver_wakes_for_timers_without_foreground_polling() {
    let engine = JsEngine::create(Some(timers_only()), None, None)
        .await
        .unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .eval(
            JsCode::Code(
                r#"
                globalThis.__timerStart = Date.now();
                globalThis.__timerFiredAt = 0;
                setTimeout(() => {
                  globalThis.__timerFiredAt = Date.now();
                }, 50);
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    // No foreground traffic while the timer is pending: the driver must be
    // woken by the runtime schedular itself, well before the 1s fallback tick.
    tokio::time::sleep(Duration::from_millis(400)).await;

    let elapsed = engine
        .eval(
            JsCode::Code(
                "globalThis.__timerFiredAt > 0 \
                 ? globalThis.__timerFiredAt - globalThis.__timerStart : -1"
                    .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    let ms = match elapsed {
        JsValue::Integer(ms) => ms as f64,
        JsValue::Float(ms) => ms,
        other => panic!("unexpected eval result: {other:?}"),
    };
    assert!(
        ms >= 0.0,
        "detached timer did not fire during the idle window"
    );
    assert!(
        ms < 350.0,
        "detached timer fired too late ({ms} ms); driver was likely only \
         woken by the fallback poll"
    );

    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_job_error_contains_original_javascript_exception() {
    let runtime = JsAsyncRuntime::new().unwrap();
    runtime.stop_driver().await;
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    context
        .with_js(async |ctx| {
            let failing_job: rquickjs::Function = ctx
                .eval("() => { throw new Error('fjs explicit job failure'); }")
                .catch(&ctx)
                .unwrap();
            failing_job.defer(()).catch(&ctx).unwrap();
        })
        .await;

    let mut error = None;
    for _ in 0..16 {
        match runtime.execute_pending_job().await {
            Ok(true) => continue,
            Ok(false) => tokio::task::yield_now().await,
            Err(err) => {
                error = Some(err.to_string());
                break;
            }
        }
    }

    let error = error.expect("expected explicit job error");
    assert!(error.contains("fjs explicit job failure"), "{error}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn background_driver_errors_are_drainable() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .eval(
            JsCode::Code(
                r#"
                globalThis.__backgroundBoom = () => {
                  throw new Error('fjs background job failure');
                };
                Promise.resolve().then(() => globalThis.__backgroundBoom());
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let errors = engine.drain_unhandled_job_errors();
        if errors
            .iter()
            .any(|error| error.contains("fjs background job failure"))
        {
            break;
        }
        assert!(Instant::now() < deadline, "background error was not queued");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn background_driver_timer_callback_errors_are_drainable() {
    let engine = JsEngine::create(Some(timers_only()), None, None)
        .await
        .unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .eval(
            JsCode::Code(
                r#"
                setTimeout(() => {
                  throw new Error('fjs timer callback failure');
                }, 10);
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let errors = engine.drain_unhandled_job_errors();
        if errors
            .iter()
            .any(|error| error.contains("fjs timer callback failure"))
        {
            break;
        }
        assert!(Instant::now() < deadline, "timer error was not queued");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn timer_callback_error_does_not_break_later_timers() {
    let engine = JsEngine::create(Some(timers_only()), None, None)
        .await
        .unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .eval(
            JsCode::Code(
                r#"
                setTimeout(() => {
                  throw new Error('fjs recoverable timer failure');
                }, 10);
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let errors = engine.drain_unhandled_job_errors();
        if errors
            .iter()
            .any(|error| error.contains("fjs recoverable timer failure"))
        {
            break;
        }
        assert!(Instant::now() < deadline, "timer error was not queued");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    engine
        .eval(
            JsCode::Code(
                r#"
                setTimeout(() => {
                  globalThis.__fjsTimerRecovered = true;
                }, 10);
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let done = engine
            .eval(
                JsCode::Code("globalThis.__fjsTimerRecovered === true".to_string()),
                None,
            )
            .await
            .unwrap();
        if matches!(done, JsValue::Boolean(true)) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "runtime did not recover after timer callback error"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn interval_callback_error_does_not_break_later_ticks() {
    let engine = JsEngine::create(Some(timers_only()), None, None)
        .await
        .unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .eval(
            JsCode::Code(
                r#"
                globalThis.__fjsIntervalTicks = 0;
                const interval = setInterval(() => {
                  globalThis.__fjsIntervalTicks += 1;
                  if (globalThis.__fjsIntervalTicks === 1) {
                    throw new Error('fjs interval recoverable failure');
                  }
                  if (globalThis.__fjsIntervalTicks >= 3) {
                    clearInterval(interval);
                  }
                }, 10);
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let errors = engine.drain_unhandled_job_errors();
        if errors
            .iter()
            .any(|error| error.contains("fjs interval recoverable failure"))
        {
            break;
        }
        assert!(Instant::now() < deadline, "interval error was not queued");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let ticks = engine
            .eval(
                JsCode::Code("globalThis.__fjsIntervalTicks".to_string()),
                None,
            )
            .await
            .unwrap();
        if matches!(ticks, JsValue::Integer(value) if value >= 3) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "interval did not continue after callback error"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_surfaces_unhandled_background_error_on_next_operation() {
    let engine = JsEngine::create(Some(timers_only()), None, None)
        .await
        .unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .eval(
            JsCode::Code(
                r#"
                setTimeout(() => {
                  throw new Error('fjs automatic background error');
                }, 10);
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    let error = loop {
        match engine.eval(JsCode::Code("1 + 1".to_string()), None).await {
            Ok(_) => {
                assert!(
                    Instant::now() < deadline,
                    "background error was not surfaced automatically"
                );
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            Err(error) => break error.to_string(),
        }
    };

    assert!(error.contains("fjs automatic background error"));
    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn detached_promise_error_caught_in_javascript_is_not_surfaced_to_dart() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .eval(
            JsCode::Code(
                r#"
                Promise.resolve()
                  .then(() => {
                    throw new Error('fjs handled detached failure');
                  })
                  .catch((error) => {
                    globalThis.__fjsHandledDetachedFailure = String(error);
                  });
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let result = engine
            .eval(
                JsCode::Code(
                    "globalThis.__fjsHandledDetachedFailure?.includes('fjs handled detached failure') === true"
                        .to_string(),
                ),
                None,
            )
            .await
            .unwrap();
        if matches!(result, JsValue::Boolean(true)) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "JavaScript .catch() did not observe detached failure"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    engine
        .eval(JsCode::Code("1 + 1".to_string()), None)
        .await
        .unwrap();
    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_surfaces_unhandled_background_error() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .runtime_for_test()
        .driver
        .push_error("fjs close background error".to_string());

    let error = engine.close().await.unwrap_err().to_string();
    assert!(error.contains("fjs close background error"));
    assert!(engine.closed());
    assert!(!engine.driver_running().await.unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_gracefully_surfaces_background_timer_error_raised_during_teardown() {
    let engine = JsEngine::create(Some(timers_only()), None, None)
        .await
        .unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .eval(
            JsCode::Code(
                r#"
                setTimeout(() => {
                  throw new Error('fjs close teardown timer failure');
                }, 10);
                'scheduled'
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap();

    let error = engine.close_gracefully().await.unwrap_err().to_string();
    assert!(error.contains("fjs close teardown timer failure"));
    assert!(engine.closed());
    assert!(!engine.driver_running().await.unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_direct_eval_error_is_not_replayed_as_background_error() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();

    let error = engine
        .eval(
            JsCode::Code(
                r#"
                function recurse() {
                  return recurse() + 1;
                }
                recurse();
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap_err()
        .to_string();
    assert!(error.contains("Maximum call stack size exceeded"));

    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_foreground_error_does_not_acknowledge_detached_background_promise_error() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();

    let error = engine
        .eval(
            JsCode::Code(
                r#"
                Promise.reject(new Error('fjs duplicate'));
                throw new Error('fjs duplicate');
                "#
                .to_string(),
            ),
            None,
        )
        .await
        .unwrap_err()
        .to_string();
    assert!(error.contains("fjs duplicate"));

    let close_error = engine.close().await.unwrap_err().to_string();
    assert!(close_error.contains("fjs duplicate"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_call_rejected_promise_error_is_not_replayed_as_background_error() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();

    engine
        .evaluate_module(JsModule::code(
            "/foreground-call-error".to_string(),
            "export async function run() { throw new Error('fjs call foreground failure'); }"
                .to_string(),
        ))
        .await
        .unwrap();

    let error = engine
        .call(
            "/foreground-call-error".to_string(),
            "run".to_string(),
            None,
        )
        .await
        .unwrap_err()
        .to_string();
    assert!(error.contains("fjs call foreground failure"));

    engine.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn async_context_eval_function_rejected_promise_error_is_not_replayed_as_background_error() {
    let runtime = JsAsyncRuntime::create(
        None,
        Some(vec![JsModule::code(
            "/foreground-context-error".to_string(),
            "export async function run() { throw new Error('fjs context foreground failure'); }"
                .to_string(),
        )]),
    )
    .await
    .unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    let result = context
        .eval_function(
            "/foreground-context-error".to_string(),
            "run".to_string(),
            None,
        )
        .await;
    let error = match result {
        JsResult::Err(error) => error.to_string(),
        JsResult::Ok(value) => panic!("expected foreground error, got {value:?}"),
    };
    assert!(error.contains("fjs context foreground failure"));

    let result = context.eval("1 + 1".to_string()).await;
    assert!(result.is_ok(), "foreground error was replayed: {result:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn background_driver_raw_quickjs_job_errors_are_drainable() {
    let runtime = JsAsyncRuntime::new().unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    context
        .with_js(async |ctx| {
            let failing_job: rquickjs::Function = ctx
                .eval("() => { throw new Error('fjs raw background job failure'); }")
                .catch(&ctx)
                .unwrap();
            failing_job.defer(()).catch(&ctx).unwrap();
        })
        .await;

    runtime.start_driver().await;

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let errors = runtime.drain_unhandled_job_errors().await;
        if errors
            .iter()
            .any(|error| error.contains("fjs raw background job failure"))
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "raw QuickJS job error was not queued"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    runtime.stop_driver().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn async_runtime_starts_background_driver_automatically() {
    let runtime = JsAsyncRuntime::create(Some(timers_only()), None)
        .await
        .unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    let scheduled = context
        .eval(
            r#"
            setTimeout(() => {
              globalThis.__fjsAutomaticDriverTimerDone = true;
            }, 10);
            "scheduled";
            "#
            .to_string(),
        )
        .await;
    assert!(matches!(scheduled, JsResult::Ok(JsValue::String(ref value)) if value == "scheduled"));

    let deadline = Instant::now() + Duration::from_secs(2);
    let mut fired = false;
    while Instant::now() < deadline {
        let result = context
            .eval("globalThis.__fjsAutomaticDriverTimerDone === true".to_string())
            .await;
        if matches!(result, JsResult::Ok(JsValue::Boolean(true))) {
            fired = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    runtime.idle().await;
    assert!(fired, "automatic background driver did not fire timer");
    runtime.stop_driver().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn async_context_surfaces_unhandled_background_error_automatically() {
    let runtime = JsAsyncRuntime::create(Some(timers_only()), None)
        .await
        .unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    let scheduled = context
        .eval(
            r#"
            setTimeout(() => {
              throw new Error('fjs context background error');
            }, 10);
            "scheduled";
            "#
            .to_string(),
        )
        .await;
    assert!(matches!(scheduled, JsResult::Ok(JsValue::String(ref value)) if value == "scheduled"));

    let deadline = Instant::now() + Duration::from_secs(2);
    let error = loop {
        match context.eval("1 + 1".to_string()).await {
            JsResult::Ok(_) => {
                assert!(
                    Instant::now() < deadline,
                    "context background error was not surfaced automatically"
                );
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            JsResult::Err(error) => break error.to_string(),
        }
    };

    assert!(error.contains("fjs context background error"));
    runtime.stop_driver().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropping_pumped_runtime_and_context_without_close_does_not_abort() {
    let runtime = JsAsyncRuntime::create(Some(timers_only()), None)
        .await
        .unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    let scheduled = context
        .eval(
            r#"
            setTimeout(() => {
              globalThis.__fjsDropTimerDone = true;
            }, 10);
            "scheduled";
            "#
            .to_string(),
        )
        .await;
    assert!(scheduled.is_ok());

    runtime.stop_driver().await;

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        runtime.execute_pending_job().await.unwrap();
        let result = context
            .eval("globalThis.__fjsDropTimerDone === true".to_string())
            .await;
        if matches!(result, JsResult::Ok(JsValue::Boolean(true))) {
            break;
        }
        assert!(Instant::now() < deadline, "manual pump timer did not fire");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    drop(context);
    drop(runtime);
    tokio::task::yield_now().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn background_driver_does_not_keep_runtime_alive_after_drop() {
    let runtime = JsAsyncRuntime::new().unwrap();
    runtime.start_driver().await;
    let driver = runtime.driver.clone();
    assert!(driver.running());

    drop(runtime);

    let deadline = Instant::now() + Duration::from_secs(2);
    while driver.running() {
        assert!(
            Instant::now() < deadline,
            "driver kept the async runtime alive after all host references were dropped"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_runtime_and_context_drop_stops_background_driver() {
    let runtime = JsAsyncRuntime::new().unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();
    let driver = runtime.driver.clone();
    crate::api::runtime::install_runtime_drop_barrier(runtime.runtime_lifetime.as_ref().unwrap());

    let runtime_drop = std::thread::spawn(move || drop(runtime));
    let context_drop = std::thread::spawn(move || drop(context));
    runtime_drop.join().unwrap();
    context_drop.join().unwrap();
    crate::api::runtime::clear_runtime_drop_barrier();

    let deadline = Instant::now() + Duration::from_millis(300);
    while driver.running() && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let stopped_automatically = !driver.running();
    if !stopped_automatically {
        driver.stop().await;
    }

    assert!(
        stopped_automatically,
        "concurrent final runtime owners skipped background driver cleanup"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn opposite_context_and_runtime_drop_winners_still_stop_driver() {
    let runtime = JsAsyncRuntime::new().unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();
    let context_clone = context.clone();
    let driver = runtime.driver.clone();
    let (first_paused, release_first) = crate::api::runtime::install_context_drop_order_barrier(
        context.context_lifetime.as_ref().unwrap(),
    );

    drop(runtime);
    let first_drop = std::thread::spawn(move || drop(context));
    first_paused.wait();
    let second_drop = std::thread::spawn(move || drop(context_clone));
    second_drop.join().unwrap();
    release_first.wait();
    first_drop.join().unwrap();
    crate::api::runtime::clear_context_drop_order_barrier();

    let deadline = Instant::now() + Duration::from_millis(300);
    while driver.running() && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let stopped_automatically = !driver.running();
    if !stopped_automatically {
        driver.stop().await;
    }

    assert!(
        stopped_automatically,
        "different runtime/context drop winners skipped background driver cleanup"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn runtime_driver_stop_returns_and_allows_restart() {
    let runtime = JsAsyncRuntime::create(Some(timers_only()), None)
        .await
        .unwrap();

    runtime.start_driver().await;
    assert!(runtime.driver_running().await);

    tokio::time::timeout(Duration::from_secs(2), runtime.stop_driver())
        .await
        .expect("stop_driver should not hang");
    assert!(!runtime.driver_running().await);

    runtime.start_driver().await;
    assert!(runtime.driver_running().await);

    tokio::time::timeout(Duration::from_secs(2), runtime.stop_driver())
        .await
        .expect("restarted driver should stop cleanly");
    assert!(!runtime.driver_running().await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn restarted_runtime_driver_progresses_timer_scheduled_while_stopped() {
    let runtime = JsAsyncRuntime::create(Some(timers_only()), None)
        .await
        .unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    runtime.start_driver().await;
    runtime.stop_driver().await;

    let scheduled = context
        .eval(
            r#"
            setTimeout(() => {
              globalThis.__fjsRestartedDriverTimerDone = true;
            }, 10);
            "scheduled";
            "#
            .to_string(),
        )
        .await;
    assert!(matches!(scheduled, JsResult::Ok(JsValue::String(ref value)) if value == "scheduled"));

    runtime.start_driver().await;

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let result = context
            .eval("globalThis.__fjsRestartedDriverTimerDone === true".to_string())
            .await;
        if matches!(result, JsResult::Ok(JsValue::Boolean(true))) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "restarted background driver did not fire stopped timer"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    runtime.stop_driver().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_is_idempotent_and_stops_driver() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();
    assert!(engine.driver_running().await.unwrap());

    engine.close().await.unwrap();
    assert!(!engine.driver_running().await.unwrap());

    engine.close().await.unwrap();
    assert!(!engine.driver_running().await.unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_cancels_pending_eval_without_draining_timer_work() {
    let engine = Arc::new(
        JsEngine::create(Some(timers_only()), None, None)
            .await
            .unwrap(),
    );
    engine.init_without_bridge().await.unwrap();

    let pending_engine = engine.clone();
    let pending = tokio::spawn(async move {
        pending_engine
            .eval(
                JsCode::Code(
                    r#"
                    await new Promise((resolve) => setTimeout(resolve, 700));
                    "done";
                    "#
                    .to_string(),
                ),
                None,
            )
            .await
    });

    tokio::time::sleep(Duration::from_millis(50)).await;

    let started = Instant::now();
    engine.close().await.unwrap();
    let elapsed = started.elapsed();

    assert!(
        elapsed < Duration::from_millis(200),
        "close should not drain pending timer work, elapsed {elapsed:?}"
    );

    let result = tokio::time::timeout(Duration::from_millis(200), pending)
        .await
        .expect("pending eval should be cancelled promptly")
        .expect("eval task should not panic");
    assert!(
        matches!(result, Err(JsError::Cancelled(_))),
        "pending eval should be cancelled, got {result:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_gracefully_drains_pending_eval_work() {
    let engine = Arc::new(
        JsEngine::create(Some(timers_only()), None, None)
            .await
            .unwrap(),
    );
    engine.init_without_bridge().await.unwrap();

    let pending_engine = engine.clone();
    let pending = tokio::spawn(async move {
        pending_engine
            .eval(
                JsCode::Code(
                    r#"
                    await new Promise((resolve) => setTimeout(resolve, 80));
                    "done";
                    "#
                    .to_string(),
                ),
                None,
            )
            .await
    });

    tokio::time::sleep(Duration::from_millis(20)).await;

    let started = Instant::now();
    engine.close_gracefully().await.unwrap();
    let elapsed = started.elapsed();

    assert!(
        elapsed >= Duration::from_millis(40),
        "closeGracefully should drain pending timer work, elapsed {elapsed:?}"
    );

    let result = pending.await.expect("eval task should not panic").unwrap();
    assert!(matches!(result, JsValue::String(ref value) if value == "done"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_interrupts_cpu_bound_eval() {
    let engine = Arc::new(JsEngine::create(None, None, None).await.unwrap());
    engine.init_without_bridge().await.unwrap();

    let pending_engine = engine.clone();
    let pending = tokio::spawn(async move {
        pending_engine
            .eval(
                JsCode::Code(
                    r#"
                    while (true) {}
                    "#
                    .to_string(),
                ),
                None,
            )
            .await
    });

    tokio::time::sleep(Duration::from_millis(50)).await;

    tokio::time::timeout(Duration::from_millis(500), engine.close())
        .await
        .expect("close should interrupt CPU-bound JavaScript promptly")
        .unwrap();

    let result = tokio::time::timeout(Duration::from_millis(200), pending)
        .await
        .expect("CPU-bound eval should finish after close")
        .expect("eval task should not panic");
    assert!(
        matches!(result, Err(JsError::Cancelled(_))),
        "CPU-bound eval should be cancelled, got {result:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_cancels_pending_module_call() {
    let engine = Arc::new(
        JsEngine::create(Some(timers_only()), None, None)
            .await
            .unwrap(),
    );
    engine.init_without_bridge().await.unwrap();
    engine
        .evaluate_module(JsModule::code(
            "/slow-call".to_string(),
            r#"
            export async function run() {
              await new Promise((resolve) => setTimeout(resolve, 700));
              return "done";
            }
            "#
            .to_string(),
        ))
        .await
        .unwrap();

    let pending_engine = engine.clone();
    let pending = tokio::spawn(async move {
        pending_engine
            .call("/slow-call".to_string(), "run".to_string(), None)
            .await
    });

    tokio::time::sleep(Duration::from_millis(50)).await;
    engine.close().await.unwrap();

    let result = tokio::time::timeout(Duration::from_millis(200), pending)
        .await
        .expect("pending call should be cancelled promptly")
        .expect("call task should not panic");
    assert!(
        matches!(result, Err(JsError::Cancelled(_))),
        "pending call should be cancelled, got {result:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_cancels_pending_bridge_call() {
    let engine = Arc::new(JsEngine::create(None, None, None).await.unwrap());
    let (started_tx, started_rx) = oneshot::channel::<()>();
    let started_tx = Arc::new(std::sync::Mutex::new(Some(started_tx)));
    let (_release_tx, release_rx) = oneshot::channel::<()>();
    let release_rx = Arc::new(std::sync::Mutex::new(Some(release_rx)));

    engine
        .init({
            let started_tx = started_tx.clone();
            let release_rx = release_rx.clone();
            move |_value| {
                let started_tx = started_tx
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .take();
                let release_rx = release_rx
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .take();
                Box::pin(async move {
                    if let Some(started_tx) = started_tx {
                        let _ = started_tx.send(());
                    }
                    if let Some(release_rx) = release_rx {
                        let _ = release_rx.await;
                    }
                    JsResult::Ok(JsValue::String("bridge done".to_string()))
                })
            }
        })
        .await
        .unwrap();

    let pending_engine = engine.clone();
    let pending = tokio::spawn(async move {
        pending_engine
            .eval(
                JsCode::Code(r#"await fjs.bridge_call("wait")"#.to_string()),
                None,
            )
            .await
    });

    started_rx.await.expect("bridge callback should start");
    engine.close().await.unwrap();

    let result = tokio::time::timeout(Duration::from_millis(200), pending)
        .await
        .expect("pending bridge eval should be cancelled promptly")
        .expect("eval task should not panic");
    assert!(
        matches!(result, Err(JsError::Cancelled(_))),
        "pending bridge eval should be cancelled, got {result:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_drops_pending_bridge_future_without_host_release() {
    struct PendingBridgeFuture {
        dropped: Option<oneshot::Sender<()>>,
    }

    impl std::future::Future for PendingBridgeFuture {
        type Output = JsResult;

        fn poll(
            self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<Self::Output> {
            std::task::Poll::Pending
        }
    }

    impl Drop for PendingBridgeFuture {
        fn drop(&mut self) {
            if let Some(dropped) = self.dropped.take() {
                let _ = dropped.send(());
            }
        }
    }

    let engine = Arc::new(JsEngine::create(None, None, None).await.unwrap());
    let (started_tx, started_rx) = oneshot::channel::<()>();
    let started_tx = Arc::new(std::sync::Mutex::new(Some(started_tx)));
    let (dropped_tx, dropped_rx) = oneshot::channel::<()>();
    let dropped_tx = Arc::new(std::sync::Mutex::new(Some(dropped_tx)));

    engine
        .init({
            let started_tx = started_tx.clone();
            let dropped_tx = dropped_tx.clone();
            move |_value| {
                let started_tx = started_tx
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .take();
                let dropped = dropped_tx
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .take();
                Box::pin(async move {
                    if let Some(started_tx) = started_tx {
                        let _ = started_tx.send(());
                    }
                    PendingBridgeFuture { dropped }.await
                })
            }
        })
        .await
        .unwrap();

    let pending_engine = engine.clone();
    let pending = tokio::spawn(async move {
        pending_engine
            .eval(
                JsCode::Code(r#"await fjs.bridge_call("wait")"#.to_string()),
                None,
            )
            .await
    });

    started_rx.await.expect("bridge callback should start");
    engine.close().await.unwrap();

    let result = tokio::time::timeout(Duration::from_millis(200), pending)
        .await
        .expect("pending bridge eval should be cancelled promptly")
        .expect("eval task should not panic");
    assert!(
        matches!(result, Err(JsError::Cancelled(_))),
        "pending bridge eval should be cancelled, got {result:?}"
    );

    tokio::time::timeout(Duration::from_millis(300), dropped_rx)
        .await
        .expect("pending bridge callback future should be dropped after close")
        .expect("drop notification should be sent");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn engine_close_cancels_mixed_in_flight_eval_call_and_bridge_operations() {
    let engine = Arc::new(
        JsEngine::create(Some(timers_only()), None, None)
            .await
            .unwrap(),
    );
    let (bridge_started_tx, bridge_started_rx) = oneshot::channel::<()>();
    let bridge_started_tx = Arc::new(std::sync::Mutex::new(Some(bridge_started_tx)));

    engine
        .init({
            let bridge_started_tx = bridge_started_tx.clone();
            move |_value| {
                let bridge_started_tx = bridge_started_tx
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .take();
                Box::pin(async move {
                    if let Some(bridge_started_tx) = bridge_started_tx {
                        let _ = bridge_started_tx.send(());
                    }
                    std::future::pending::<JsResult>().await
                })
            }
        })
        .await
        .unwrap();

    engine
        .evaluate_module(JsModule::code(
            "/mixed-close".to_string(),
            r#"
            export async function slow() {
              await new Promise((resolve) => setTimeout(resolve, 700));
              return "call done";
            }
            "#
            .to_string(),
        ))
        .await
        .unwrap();

    let eval_task = {
        let engine = engine.clone();
        tokio::spawn(async move {
            engine
                .eval(
                    JsCode::Code(
                        r#"
                        await new Promise((resolve) => setTimeout(resolve, 700));
                        "eval done";
                        "#
                        .to_string(),
                    ),
                    None,
                )
                .await
        })
    };
    let call_task = {
        let engine = engine.clone();
        tokio::spawn(async move {
            engine
                .call("/mixed-close".to_string(), "slow".to_string(), None)
                .await
        })
    };
    let bridge_task = {
        let engine = engine.clone();
        tokio::spawn(async move {
            engine
                .eval(
                    JsCode::Code(r#"await fjs.bridge_call("mixed")"#.to_string()),
                    None,
                )
                .await
        })
    };

    bridge_started_rx
        .await
        .expect("bridge operation should be in flight");
    tokio::time::sleep(Duration::from_millis(50)).await;
    engine.close().await.unwrap();

    for (name, task) in [
        ("eval", eval_task),
        ("call", call_task),
        ("bridge", bridge_task),
    ] {
        let result = tokio::time::timeout(Duration::from_millis(250), task)
            .await
            .unwrap_or_else(|_| panic!("{name} operation should finish after close"))
            .unwrap_or_else(|error| panic!("{name} task should not panic: {error}"));
        assert!(
            matches!(result, Err(JsError::Cancelled(_))),
            "{name} operation should be cancelled, got {result:?}"
        );
    }

    assert!(engine.closed());
    assert!(!engine.driver_running().await.unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_gracefully_allows_pending_module_call_to_complete() {
    let engine = Arc::new(
        JsEngine::create(Some(timers_only()), None, None)
            .await
            .unwrap(),
    );
    engine.init_without_bridge().await.unwrap();
    engine
        .evaluate_module(JsModule::code(
            "/graceful-call".to_string(),
            r#"
            export async function run() {
              await new Promise((resolve) => setTimeout(resolve, 60));
              return "done";
            }
            "#
            .to_string(),
        ))
        .await
        .unwrap();

    let pending_engine = engine.clone();
    let pending = tokio::spawn(async move {
        pending_engine
            .call("/graceful-call".to_string(), "run".to_string(), None)
            .await
    });

    tokio::time::sleep(Duration::from_millis(20)).await;
    engine.close_gracefully().await.unwrap();

    let result = pending.await.expect("call task should not panic").unwrap();
    assert!(matches!(result, JsValue::String(ref value) if value == "done"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_close_and_close_gracefully_are_cross_idempotent() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();

    engine.close().await.unwrap();
    engine.close_gracefully().await.unwrap();
    engine.close().await.unwrap();
    assert!(engine.closed());
    assert!(!engine.driver_running().await.unwrap());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_rejects_high_level_apis_after_close() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();
    engine.close().await.unwrap();

    assert!(
        engine
            .eval(JsCode::Code("1 + 1".to_string()), None)
            .await
            .unwrap_err()
            .to_string()
            .contains("Engine is closed")
    );
    assert!(
        engine
            .declare_new_module(JsModule::code(
                "/closed".to_string(),
                "export {}".to_string()
            ))
            .await
            .unwrap_err()
            .to_string()
            .contains("Engine is closed")
    );
    assert!(
        engine
            .call("/closed".to_string(), "run".to_string(), None)
            .await
            .unwrap_err()
            .to_string()
            .contains("Engine is closed")
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_rejects_all_public_work_apis_after_close() {
    fn assert_engine_closed<T>(result: Result<T, JsError>) {
        match result {
            Err(error) => assert!(
                error.to_string().contains("Engine is closed"),
                "expected closed engine error, got {error}"
            ),
            Ok(_) => panic!("expected closed engine error"),
        }
    }

    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();
    engine.close().await.unwrap();

    let module = JsModule::code("/closed".to_string(), "export const value = 1;".to_string());
    let bytecode = JsModuleBytecode::new("/closed-bytecode".to_string(), vec![0]);
    let bundle = JsModuleBytecodeBundle::new(Some("/closed-entry".to_string()), vec![]);
    let script = JsScriptBytecode::new("closed.js".to_string(), vec![0]);

    assert_engine_closed(engine.memory_usage().await);
    assert_engine_closed(engine.run_gc().await);
    assert_engine_closed(engine.set_gc_threshold(1024).await);
    assert_engine_closed(engine.set_info("closed".to_string()).await);
    assert_engine_closed(engine.set_max_stack_size(1024).await);
    assert_engine_closed(engine.set_memory_limit(1024).await);
    assert_engine_closed(engine.eval(JsCode::Code("1 + 1".to_string()), None).await);
    assert_engine_closed(engine.declare_new_bytecode_module(bytecode.clone()).await);
    assert_engine_closed(
        engine
            .declare_new_bytecode_modules(vec![bytecode.clone()])
            .await,
    );
    assert_engine_closed(engine.declare_new_bytecode_bundle(bundle.clone()).await);
    assert_engine_closed(engine.declare_new_module(module.clone()).await);
    assert_engine_closed(engine.declare_new_modules(vec![module.clone()]).await);
    assert_engine_closed(engine.evaluate_module(module.clone()).await);
    assert_engine_closed(engine.evaluate_bytecode_module(bytecode.clone()).await);
    assert_engine_closed(engine.evaluate_bytecode_bundle(bundle).await);
    assert_engine_closed(engine.evaluate_script_bytecode(script).await);
    assert_engine_closed(engine.clear_pending_modules().await);
    assert_engine_closed(engine.get_declared_modules().await);
    assert_engine_closed(engine.get_available_modules().await);
    assert_engine_closed(engine.is_module_declared("/closed".to_string()).await);
    assert_engine_closed(engine.is_module_available("/closed".to_string()).await);
    assert_engine_closed(
        engine
            .call("/closed".to_string(), "run".to_string(), None)
            .await,
    );

    assert!(engine.closed());
    assert!(!engine.running());
    assert!(engine.drain_unhandled_job_errors().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn async_context_eval_observes_runtime_shutdown_token() {
    let runtime = JsAsyncRuntime::create(Some(timers_only()), None)
        .await
        .unwrap();
    let context = Arc::new(JsAsyncContext::from(&runtime).await.unwrap());

    let pending_context = context.clone();
    let pending = tokio::spawn(async move {
        pending_context
            .eval(
                r#"
                await new Promise((resolve) => setTimeout(resolve, 700));
                "done";
                "#
                .to_string(),
            )
            .await
    });

    tokio::time::sleep(Duration::from_millis(50)).await;
    runtime.request_shutdown();
    runtime.stop_driver().await;

    let result = tokio::time::timeout(Duration::from_millis(200), pending)
        .await
        .expect("pending context eval should be cancelled promptly")
        .expect("eval task should not panic");
    assert!(
        matches!(result, JsResult::Err(JsError::Cancelled(_))),
        "pending context eval should be cancelled, got {result:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropping_initialized_bridge_engine_without_close_does_not_abort() {
    let engine = Arc::new(JsEngine::create(None, None, None).await.unwrap());
    engine
        .init(|value| Box::pin(async move { JsResult::Ok(value) }))
        .await
        .unwrap();

    drop(engine);

    tokio::task::yield_now().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropping_essential_bridge_engine_with_loaded_module_without_close_does_not_abort() {
    let engine = Arc::new(
        JsEngine::create(
            Some(timers_only()),
            Some(vec![crate::api::source::JsModule::code(
                "drop-fixture".to_string(),
                "export const value = 42;".to_string(),
            )]),
            None,
        )
        .await
        .unwrap(),
    );
    engine
        .init(|value| Box::pin(async move { JsResult::Ok(value) }))
        .await
        .unwrap();

    engine
        .evaluate_module(crate::api::source::JsModule::code(
            "/drop-test".to_string(),
            "import { value } from 'drop-fixture'; export async function run() { return await fjs.bridge_call(value); }".to_string(),
        ))
        .await
        .unwrap();

    let value = engine
        .call("/drop-test".to_string(), "run".to_string(), None)
        .await
        .unwrap();
    assert!(matches!(value, JsValue::Integer(42)));

    drop(engine);

    tokio::task::yield_now().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn codemode_close_interrupts_microtasks_and_pending_promises() {
    for source in [
        "await (async () => { while (true) { await Promise.resolve(); } })()",
        "await new Promise(() => {})",
    ] {
        let engine = Arc::new(
            JsEngine::create(Some(JsBuiltinOptions::none()), None, None)
                .await
                .unwrap(),
        );
        engine.init_without_bridge().await.unwrap();
        let eval_engine = engine.clone();
        let pending =
            tokio::spawn(async move { eval_engine.eval(JsCode::Code(source.into()), None).await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        tokio::time::timeout(Duration::from_secs(1), async {
            engine.close().await.unwrap();
            let result = pending.await.unwrap();
            assert!(
                matches!(result, Err(JsError::Cancelled(_))),
                "unexpected result: {result:?}"
            );
        })
        .await
        .expect("eval and close must settle within one second");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn codemode_close_interrupts_two_busy_engines() {
    let mut engines = Vec::new();
    let mut pending = Vec::new();
    // Initialize both engines before occupying the two JS executor workers.
    for _ in 0..2 {
        let engine = Arc::new(
            JsEngine::create(Some(JsBuiltinOptions::none()), None, None)
                .await
                .unwrap(),
        );
        engine.init_without_bridge().await.unwrap();
        engines.push(engine);
    }
    for engine in &engines {
        let engine = engine.clone();
        pending.push(tokio::spawn(async move {
            engine
                .eval(JsCode::Code("while (true) {}".into()), None)
                .await
        }));
    }
    tokio::time::sleep(Duration::from_millis(50)).await;
    tokio::time::timeout(Duration::from_secs(1), async {
        for engine in engines {
            engine.close().await.unwrap();
        }
        for eval in pending {
            let result = eval.await.unwrap();
            assert!(
                matches!(result, Err(JsError::Cancelled(_))),
                "unexpected result: {result:?}"
            );
        }
    })
    .await
    .expect("saturated executor must not block closing either engine");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn task_execution_budget_interrupts_cpu_and_microtasks() {
    for source in ["while(true){}", "while(true){await Promise.resolve();}"] {
        let engine = JsEngine::create(None, None, None).await.unwrap();
        engine.init_without_bridge().await.unwrap();
        engine.set_execution_time_limit(Some(50)).await.unwrap();
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            engine.eval(JsCode::Code(source.into()), None),
        )
        .await
        .expect("native budget must interrupt");
        assert!(result.is_err());
        engine.close().await.unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn task_execution_budget_excludes_host_wait_but_not_detached_cpu() {
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine
        .init(|_| {
            Box::pin(async {
                tokio::time::sleep(Duration::from_millis(120)).await;
                JsResult::Ok(JsValue::Integer(7))
            })
        })
        .await
        .unwrap();
    engine.set_execution_time_limit(Some(40)).await.unwrap();
    let result = engine
        .eval(
            JsCode::Code("await fjs.bridge_call('wait'); 9".into()),
            None,
        )
        .await;
    assert_eq!(result.unwrap(), JsValue::Integer(9));
    engine.close().await.unwrap();

    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine
        .init(|_| {
            Box::pin(async {
                tokio::time::sleep(Duration::from_millis(120)).await;
                JsResult::Ok(JsValue::Integer(7))
            })
        })
        .await
        .unwrap();
    engine.set_execution_time_limit(Some(40)).await.unwrap();
    let result = tokio::time::timeout(
        Duration::from_secs(2),
        engine.eval(
            JsCode::Code("void fjs.bridge_call('wait'); while(true){}".into()),
            None,
        ),
    )
    .await
    .expect("pending Host I/O cannot hide runnable CPU");
    assert!(result.is_err());
    if let Err(error) = engine.close().await {
        assert!(
            error.to_string().contains("continuous JavaScript"),
            "{error}"
        );
    }
    assert!(engine.closed());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_group_shares_runtime_but_isolates_globals_and_native_bridges() {
    use crate::api::engine::JsEngineGroup;
    let group = JsEngineGroup::create(None).await.unwrap();
    let a = group.create_engine().await.unwrap();
    let b = group.create_engine().await.unwrap();
    let ar = a.runtime_for_test();
    let br = b.runtime_for_test();
    assert!(Arc::ptr_eq(
        ar.runtime_lifetime.as_ref().unwrap(),
        br.runtime_lifetime.as_ref().unwrap()
    ));
    a.init(|_| Box::pin(async { JsResult::Ok(JsValue::String("A".into())) }))
        .await
        .unwrap();
    b.init(|_| Box::pin(async { JsResult::Ok(JsValue::String("B".into())) }))
        .await
        .unwrap();
    a.eval(JsCode::Code("globalThis.leaked = 1; Object.prototype.poison = 1; JSON.stringify = () => 'poison'; globalThis.savedBridge = fjs.bridge_call;".into()), None).await.unwrap();
    let result = b.eval(JsCode::Code("JSON.stringify([typeof leaked, typeof ({}).poison, typeof savedBridge, await fjs.bridge_call('same-token')])".into()), None).await.unwrap();
    assert_eq!(
        result,
        JsValue::String(r#"["undefined","undefined","undefined","B"]"#.into())
    );
    assert_eq!(
        a.eval(JsCode::Code("await savedBridge('same-token')".into()), None)
            .await
            .unwrap(),
        JsValue::String("A".into())
    );
    a.close().await.unwrap();
    assert_eq!(
        b.eval(JsCode::Code("21*2".into()), None).await.unwrap(),
        JsValue::Integer(42)
    );
    b.close().await.unwrap();
    group.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_group_context_close_cancels_host_wait_without_stopping_sibling() {
    use crate::api::engine::JsEngineGroup;
    let group = JsEngineGroup::create(None).await.unwrap();
    let a = Arc::new(group.create_engine().await.unwrap());
    let b = group.create_engine().await.unwrap();
    let entered = Arc::new(tokio::sync::Notify::new());
    let signal = entered.clone();
    a.init(move |_| {
        let signal = signal.clone();
        Box::pin(async move {
            signal.notify_one();
            std::future::pending::<JsResult>().await
        })
    })
    .await
    .unwrap();
    b.init_without_bridge().await.unwrap();
    let caller = a.clone();
    let pending = tokio::spawn(async move {
        caller
            .eval(JsCode::Code("await fjs.bridge_call('wait')".into()), None)
            .await
    });
    tokio::time::timeout(Duration::from_secs(2), entered.notified())
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(2), a.close())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(pending.await.unwrap(), Err(JsError::Cancelled(_))));
    assert_eq!(
        b.eval(JsCode::Code("42".into()), None).await.unwrap(),
        JsValue::Integer(42)
    );
    assert!(b.driver_running().await.unwrap());
    b.close().await.unwrap();
    group.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_group_background_errors_stay_with_their_context() {
    use crate::api::engine::JsEngineGroup;
    let group = JsEngineGroup::create(None).await.unwrap();
    let a = group.create_engine().await.unwrap();
    let b = group.create_engine().await.unwrap();
    a.init_without_bridge().await.unwrap();
    b.init_without_bridge().await.unwrap();
    a.eval(
        JsCode::Code("Promise.reject(new Error('A-only')); 1".into()),
        None,
    )
    .await
    .unwrap();
    assert_eq!(
        b.eval(JsCode::Code("42".into()), None).await.unwrap(),
        JsValue::Integer(42)
    );
    assert!(b.drain_unhandled_job_errors().is_empty());
    // A resident context keeps serving calls; its queued failure stays drainable.
    assert_eq!(
        a.eval(JsCode::Code("1".into()), None).await.unwrap(),
        JsValue::Integer(1)
    );
    assert!(
        a.drain_unhandled_job_errors()
            .iter()
            .any(|message| message.contains("A-only"))
    );
    a.close().await.unwrap();
    b.close().await.unwrap();
    group.close().await.unwrap();
}

#[test]
fn driver_error_cap_is_per_context_scope() {
    let driver = crate::runtime::driver::DriverController::default();
    let noisy = driver.context_scope();
    let quiet = driver.context_scope();
    quiet.push_error("quiet".to_string());
    for index in 0..40 {
        noisy.push_error(format!("noisy-{index}"));
    }
    assert_eq!(quiet.drain_errors(), vec!["quiet".to_string()]);
    let noisy_errors = noisy.drain_errors();
    assert_eq!(noisy_errors.len(), 32);
    assert_eq!(noisy_errors.first().map(String::as_str), Some("noisy-8"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_group_runtime_timeout_reaches_every_context() {
    use crate::api::engine::JsEngineGroup;
    let group = JsEngineGroup::create(None).await.unwrap();
    group.set_execution_time_limit(Some(30)).await.unwrap();
    let a = group.create_engine().await.unwrap();
    let b = group.create_engine().await.unwrap();
    a.init_without_bridge().await.unwrap();
    b.init_without_bridge().await.unwrap();
    assert!(matches!(
        a.eval(JsCode::Code("while(true){}".into()), None).await,
        Err(JsError::Timeout { .. })
    ));
    assert!(matches!(
        b.eval(JsCode::Code("42".into()), None).await,
        Err(JsError::Timeout { .. })
    ));
    a.close().await.unwrap();
    b.close().await.unwrap();
    group.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_group_modules_and_value_intrinsics_are_context_local() {
    use crate::api::engine::JsEngineGroup;
    let group = JsEngineGroup::create(None).await.unwrap();
    let a = group.create_engine().await.unwrap();
    let b = group.create_engine().await.unwrap();
    a.init_without_bridge().await.unwrap();
    b.init_without_bridge().await.unwrap();
    for (engine, value) in [(&a, "A"), (&b, "B")] {
        engine
            .declare_new_module(JsModule::code(
                "private".into(),
                format!("export const identity = '{value}';"),
            ))
            .await
            .unwrap();
    }
    a.declare_new_module(JsModule::code(
        "only-a".into(),
        "export const secret = 'A-secret';".into(),
    ))
    .await
    .unwrap();
    for (engine, value) in [(&a, "A"), (&b, "B")] {
        assert_eq!(
            engine
                .eval(
                    JsCode::Code("(await import('private')).identity".into()),
                    None
                )
                .await
                .unwrap(),
            JsValue::String(value.into())
        );
    }
    assert!(!b.is_module_declared("only-a".into()).await.unwrap());
    assert!(
        b.eval(JsCode::Code("await import('only-a')".into()), None)
            .await
            .is_err()
    );
    a.eval(
        JsCode::Code("Date.prototype.getTime = () => 999;".into()),
        None,
    )
    .await
    .unwrap();
    assert_eq!(
        b.eval(
            JsCode::Code("[new Date(123), new Uint8Array([1,2])]".into()),
            None
        )
        .await
        .unwrap(),
        JsValue::Array(vec![JsValue::Date(123), JsValue::Bytes(vec![1, 2])])
    );
    a.close().await.unwrap();
    assert_eq!(
        b.eval(
            JsCode::Code("(await import('private')).identity".into()),
            None
        )
        .await
        .unwrap(),
        JsValue::String("B".into())
    );
    b.close().await.unwrap();
    group.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn engine_group_saved_native_bridge_is_revoked_on_context_close() {
    use crate::api::engine::JsEngineGroup;
    use std::sync::atomic::{AtomicUsize, Ordering};
    let group = JsEngineGroup::create(None).await.unwrap();
    let a = group.create_engine().await.unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let called = calls.clone();
    a.init(move |_| {
        called.fetch_add(1, Ordering::AcqRel);
        Box::pin(async { JsResult::Ok(JsValue::None) })
    })
    .await
    .unwrap();
    a.eval(
        JsCode::Code("globalThis.saved = fjs.bridge_call; await saved('before');".into()),
        None,
    )
    .await
    .unwrap();
    assert_eq!(calls.load(Ordering::Acquire), 1);
    let raw_context = a.context_for_test();
    a.close().await.unwrap();
    // Exercise the actual saved native function, bypassing the public eval guard.
    raw_context
        .with_js(async |ctx| {
            assert!(
                ctx.eval::<rquickjs::Value, _>("saved('after')")
                    .catch(&ctx)
                    .is_err()
            );
        })
        .await;
    assert_eq!(calls.load(Ordering::Acquire), 1);
    drop(raw_context);
    group.close().await.unwrap();
}
