//! # Runtime and Context Management
//!
//! This module provides the core runtime and context types for JavaScript execution.
//! It includes both synchronous and asynchronous variants with a unified interface.

use crate::api::error::{JsError, JsResult};
use crate::api::module::{
    DynamicModuleEntry, DynamicModuleLoader, DynamicModuleResolver, DynamicModuleStorage,
    GlobalAttachment, LoadedDynamicModules, ModuleBuilder, get_available_module_names,
};
use crate::api::source::{
    JsBuiltinOptions, JsCode, JsEvalOptions, JsModule, get_raw_source_code,
    get_raw_source_code_sync,
};
use crate::api::value::{JsValue, install_value_intrinsics};
use crate::runtime::driver::DriverErrorSource;
use crate::runtime::shutdown::RuntimeShutdown;
use flutter_rust_bridge::frb;
use rquickjs::loader::{BuiltinLoader, BuiltinResolver};
use rquickjs::promise::MaybePromise;
use rquickjs::{CatchResultExt, FromJs, Module, Promise};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};

fn file_eval_options(path: &str, options: JsEvalOptions) -> rquickjs::context::EvalOptions {
    let mut options: rquickjs::context::EvalOptions = options.into();
    options.filename = Some(std::path::Path::new(path).file_name().map_or_else(
        || path.to_string(),
        |name| name.to_string_lossy().into_owned(),
    ));
    options
}

#[cfg(test)]
struct RuntimeDropBarrier {
    lifetime: std::sync::Weak<()>,
    barrier: Arc<std::sync::Barrier>,
}

#[cfg(test)]
static RUNTIME_DROP_BARRIER: std::sync::Mutex<Option<RuntimeDropBarrier>> =
    std::sync::Mutex::new(None);

#[cfg(test)]
struct ContextDropOrderBarrier {
    lifetime: std::sync::Weak<()>,
    first_paused: Arc<std::sync::Barrier>,
    release_first: Arc<std::sync::Barrier>,
}

#[cfg(test)]
static CONTEXT_DROP_ORDER_BARRIER: std::sync::Mutex<Option<ContextDropOrderBarrier>> =
    std::sync::Mutex::new(None);

#[cfg(test)]
fn wait_at_runtime_drop_barrier(lifetime: &Arc<()>) {
    let barrier = RUNTIME_DROP_BARRIER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .filter(|hook| hook.lifetime.as_ptr() == Arc::as_ptr(lifetime))
        .map(|hook| hook.barrier.clone());
    if let Some(barrier) = barrier {
        barrier.wait();
    }
}

fn take_last_owner(lifetime: &mut Option<Arc<()>>) -> bool {
    // Unlike a strong-count check followed by drop, concurrent `into_inner`
    // calls guarantee that exactly one consumed token becomes the final owner.
    lifetime.take().and_then(Arc::into_inner).is_some()
}

#[cfg(test)]
pub(crate) fn install_runtime_drop_barrier(lifetime: &Arc<()>) {
    *RUNTIME_DROP_BARRIER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(RuntimeDropBarrier {
        lifetime: Arc::downgrade(lifetime),
        barrier: Arc::new(std::sync::Barrier::new(2)),
    });
}

#[cfg(test)]
pub(crate) fn clear_runtime_drop_barrier() {
    RUNTIME_DROP_BARRIER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
}

#[cfg(test)]
fn pause_non_last_runtime_owner_before_context_drop(
    context_lifetime: &Arc<()>,
    is_last_runtime_owner: bool,
) {
    if is_last_runtime_owner {
        return;
    }
    let barriers = CONTEXT_DROP_ORDER_BARRIER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .filter(|hook| hook.lifetime.as_ptr() == Arc::as_ptr(context_lifetime))
        .map(|hook| (hook.first_paused.clone(), hook.release_first.clone()));
    if let Some((first_paused, release_first)) = barriers {
        first_paused.wait();
        release_first.wait();
    }
}

#[cfg(test)]
pub(crate) fn install_context_drop_order_barrier(
    context_lifetime: &Arc<()>,
) -> (Arc<std::sync::Barrier>, Arc<std::sync::Barrier>) {
    let first_paused = Arc::new(std::sync::Barrier::new(2));
    let release_first = Arc::new(std::sync::Barrier::new(2));
    *CONTEXT_DROP_ORDER_BARRIER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(ContextDropOrderBarrier {
        lifetime: Arc::downgrade(context_lifetime),
        first_paused: first_paused.clone(),
        release_first: release_first.clone(),
    });
    (first_paused, release_first)
}

#[cfg(test)]
pub(crate) fn clear_context_drop_order_barrier() {
    CONTEXT_DROP_ORDER_BARRIER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take();
}

/// Memory usage statistics for the JavaScript runtime.
///
/// This struct provides detailed information about memory allocation
/// and usage within the JavaScript runtime, useful for monitoring
/// and debugging memory-related issues.
///
/// ## Example
///
/// ```dart
/// final runtime = await JsAsyncRuntime.create(builtins: JsBuiltinOptions.all());
/// final engine = await JsEngine.create(builtins: JsBuiltinOptions.all());
/// await engine.initWithoutBridge();
///
/// final memory = await runtime.memoryUsage();
/// print('Memory used: ${memory.totalMemory} bytes');
/// print('Allocations: ${memory.totalAllocations}');
/// ```
#[frb(opaque)]
#[derive(Clone)]
pub struct MemoryUsage(pub(crate) rquickjs::qjs::JSMemoryUsage);

macro_rules! proxy_memory_usage_getter {
    ($($name:ident => $doc:literal),+ $(,)?) => {
        impl MemoryUsage {
            $(
                #[doc = $doc]
                #[frb(sync, getter)]
                pub fn $name(&self) -> i64 { self.0.$name }
            )+
        }
    };
}

proxy_memory_usage_getter!(
    malloc_size => "Returns the number of bytes currently reserved by QuickJS's allocator, including allocator overhead.",
    malloc_limit => "Returns the configured QuickJS allocator limit in bytes.",
    memory_used_size => "Returns QuickJS's estimated live runtime memory in bytes, excluding allocator overhead.",
    malloc_count => "Returns the number of live allocations tracked by QuickJS's allocator.",
    memory_used_count => "Returns the estimated number of live allocations represented by `memory_used_size`.",
    atom_count => "Returns the number of live interned atoms.",
    atom_size => "Returns the estimated memory occupied by interned atoms, in bytes.",
    str_count => "Returns the number of live JavaScript strings.",
    str_size => "Returns the estimated memory occupied by JavaScript strings, in bytes.",
    obj_count => "Returns the number of live JavaScript objects.",
    obj_size => "Returns the estimated memory occupied by JavaScript object headers, in bytes.",
    prop_count => "Returns the number of live object properties.",
    prop_size => "Returns the estimated memory occupied by object property storage, in bytes.",
    shape_count => "Returns the number of live QuickJS object shapes.",
    shape_size => "Returns the estimated memory occupied by object shapes, in bytes.",
    js_func_count => "Returns the number of live JavaScript bytecode functions.",
    js_func_size => "Returns the estimated memory occupied by JavaScript function metadata and closures, in bytes.",
    js_func_code_size => "Returns the total JavaScript function bytecode size, in bytes.",
    js_func_pc2line_count => "Returns the number of JavaScript functions that have source-position tables.",
    js_func_pc2line_size => "Returns the total size of JavaScript source-position tables, in bytes.",
    c_func_count => "Returns the number of live native C function objects exposed to JavaScript.",
    array_count => "Returns the number of live JavaScript arrays.",
    fast_array_count => "Returns the number of live arrays using QuickJS's dense fast-array representation.",
    fast_array_elements => "Returns the number of elements stored across dense fast arrays.",
    binary_object_count => "Returns the number of binary objects deserialized by QuickJS contexts in this runtime.",
    binary_object_size => "Returns the total input size, in bytes, of binary objects deserialized by QuickJS contexts in this runtime."
);

impl MemoryUsage {
    /// Returns total memory used in bytes.
    ///
    /// This represents the total amount of memory currently allocated
    /// by the JavaScript runtime.
    ///
    /// ## Returns
    ///
    /// Total memory usage in bytes
    #[frb(sync, getter)]
    pub fn total_memory(&self) -> i64 {
        self.0.memory_used_size
    }

    /// Returns total allocation count.
    ///
    /// This represents the total number of memory allocations
    /// performed by the JavaScript runtime.
    ///
    /// ## Returns
    ///
    /// Total number of allocations
    #[frb(sync, getter)]
    pub fn total_allocations(&self) -> i64 {
        self.0.malloc_count
    }

    /// Returns a human-readable summary of memory usage.
    ///
    /// Provides a formatted string containing key memory statistics
    /// including total memory, object count, function count, and string count.
    ///
    /// ## Returns
    ///
    /// A formatted string summarizing memory usage
    ///
    /// ## Example
    ///
    /// ```dart
    /// final memory = await runtime.memoryUsage();
    /// print(memory.summary());
    /// // Output: Memory: 123456 bytes, Objects: 42, Functions: 10, Strings: 25
    /// ```
    #[frb(sync)]
    pub fn summary(&self) -> String {
        format!(
            "Memory: {} bytes, Objects: {}, Functions: {}, Strings: {}",
            self.0.memory_used_size, self.0.obj_count, self.0.js_func_count, self.0.str_count
        )
    }
}

type RuntimeResolverStack = (
    crate::api::module::ModuleResolver,
    BuiltinResolver,
    BuiltinResolver,
    DynamicModuleResolver,
);

type RuntimeLoaderStack = (
    rquickjs::loader::ModuleLoader,
    BuiltinLoader,
    BuiltinLoader,
    DynamicModuleLoader,
);

// Only host-registered in-memory modules may resolve. Never fall through to
// filesystem or native-library loaders, even when all builtins are disabled.
fn make_loader_stack(
    module_resolver: crate::api::module::ModuleResolver,
    module_loader: rquickjs::loader::ModuleLoader,
    additional_resolver: BuiltinResolver,
    additional_loader: BuiltinLoader,
) -> (RuntimeResolverStack, RuntimeLoaderStack) {
    let resolver = (
        module_resolver,
        additional_resolver,
        BuiltinResolver::default(),
        DynamicModuleResolver::default(),
    );
    let loader = (
        module_loader,
        additional_loader,
        BuiltinLoader::default(),
        DynamicModuleLoader::default(),
    );
    (resolver, loader)
}

fn install_default_async_loaders(runtime: &rquickjs::AsyncRuntime) {
    let (module_resolver, module_loader, _) = ModuleBuilder::new().build();
    let (resolver, loader) = make_loader_stack(
        module_resolver,
        module_loader,
        BuiltinResolver::default(),
        BuiltinLoader::default(),
    );
    futures::executor::block_on(runtime.set_loader(resolver, loader));
}

/// A synchronous JavaScript runtime.
///
/// `JsRuntime` provides a synchronous execution environment for JavaScript code.
/// It manages the underlying QuickJS runtime and handles module loading,
/// garbage collection, and memory management.
///
/// ## Example
///
/// ```dart
/// final runtime = JsRuntime();
/// final context = JsContext.from(runtime: runtime);
/// final result = context.eval(code: '1 + 1');
/// print(result.value); // 2
/// ```
#[frb(opaque)]
#[derive(Clone)]
pub struct JsRuntime {
    pub(crate) rt: rquickjs::Runtime,
    pub(crate) global_attachment: Option<GlobalAttachment>,
}

impl JsRuntime {
    /// Creates a new JavaScript runtime with default configuration.
    ///
    /// The runtime is created with no builtin modules. Use `create()`
    /// to create a runtime with custom builtin modules.
    ///
    /// ## Returns
    ///
    /// A new `JsRuntime` instance
    ///
    /// ## Example
    ///
    /// ```dart
    /// final runtime = JsRuntime();
    /// ```
    #[frb(sync)]
    pub fn new() -> Result<Self, JsError> {
        let runtime = rquickjs::Runtime::new()?;
        runtime.set_max_stack_size(crate::runtime::stack::SYNC_MAX_STACK_SIZE);
        let (module_resolver, module_loader, _) = ModuleBuilder::new().build();
        let (resolver, loader) = make_loader_stack(
            module_resolver,
            module_loader,
            BuiltinResolver::default(),
            BuiltinLoader::default(),
        );
        runtime.set_loader(resolver, loader);
        Ok(Self {
            rt: runtime,
            global_attachment: None,
        })
    }

    /// Creates a new JavaScript runtime with custom builtin modules.
    ///
    /// This method creates a runtime with support for Node.js-compatible
    /// builtin modules and custom modules.
    ///
    /// ## Parameters
    /// - `builtins`: Optional builtin module configuration (e.g., console, fs, crypto)
    /// - `modules`: Optional list of additional modules to register
    ///
    /// ## Returns
    ///
    /// A new `JsRuntime` instance with configured modules
    ///
    /// ## Example
    ///
    /// ```dart
    /// final runtime = await JsRuntime.create(
    ///   builtins: JsBuiltinOptions.all(),
    ///   modules: [
    ///     JsModule.code(module: 'my-utils', code: 'export const foo = "bar";'),
    ///   ],
    /// );
    /// ```
    pub async fn create(
        builtins: Option<JsBuiltinOptions>,
        modules: Option<Vec<JsModule>>,
    ) -> Result<Self, JsError> {
        let runtime = rquickjs::Runtime::new()?;
        runtime.set_max_stack_size(crate::runtime::stack::SYNC_MAX_STACK_SIZE);
        let (
            module_resolver,
            module_loader,
            additional_resolver,
            additional_loader,
            global_attachment,
        ) = Self::build_loaders(builtins, modules).await?;

        let (resolver, loader) = make_loader_stack(
            module_resolver,
            module_loader,
            additional_resolver,
            additional_loader,
        );
        runtime.set_loader(resolver, loader);

        Ok(Self {
            rt: runtime,
            global_attachment: Some(global_attachment),
        })
    }

    async fn build_loaders(
        builtins: Option<JsBuiltinOptions>,
        modules: Option<Vec<JsModule>>,
    ) -> Result<
        (
            crate::api::module::ModuleResolver,
            rquickjs::loader::ModuleLoader,
            BuiltinResolver,
            BuiltinLoader,
            GlobalAttachment,
        ),
        JsError,
    > {
        // Reveric build: fail fast instead of silently omitting a requested builtin.
        if let Some(builtin_options) = &builtins {
            let unsupported = builtin_options.unsupported_builtins();
            if !unsupported.is_empty() {
                return Err(JsError::runtime(format!(
                    "Builtins not compiled into this build: {}",
                    unsupported.join(", ")
                )));
            }
        }
        let (module_resolver, module_loader, mut global_attachment) =
            if let Some(builtin_options) = builtins {
                builtin_options.to_module_builder().build()
            } else {
                ModuleBuilder::new().build()
            };

        let mut additional_resolver = BuiltinResolver::default();
        let mut additional_loader = BuiltinLoader::default();

        if let Some(named_modules) = modules {
            for module in named_modules {
                let code = get_raw_source_code(module.source).await?;
                additional_resolver = additional_resolver.with_module(&module.name);
                additional_loader = additional_loader.with_module(&module.name, code);
                global_attachment = global_attachment.add_name(module.name);
            }
        }

        Ok((
            module_resolver,
            module_loader,
            additional_resolver,
            additional_loader,
            global_attachment,
        ))
    }

    /// Sets the memory limit for the runtime.
    ///
    /// Once the memory limit is reached, JavaScript execution will fail
    /// with a memory limit error.
    ///
    /// ## Parameters
    ///
    /// - `limit`: Maximum memory in bytes
    ///
    /// ## Example
    ///
    /// ```dart
    /// runtime.setMemoryLimit(limit: 16 * 1024 * 1024); // 16 MB
    /// ```
    #[frb(sync)]
    pub fn set_memory_limit(&self, limit: usize) {
        self.rt.set_memory_limit(limit);
    }

    /// Sets the maximum stack size.
    ///
    /// Limits the maximum depth of the JavaScript call stack to prevent
    /// stack overflow errors.
    ///
    /// ## Parameters
    ///
    /// - `limit`: Maximum stack size in bytes
    #[frb(sync)]
    pub fn set_max_stack_size(&self, limit: usize) {
        self.rt
            .set_max_stack_size(crate::runtime::stack::clamp_sync(limit));
    }

    /// Sets the garbage collection threshold.
    ///
    /// Configures when the runtime should trigger automatic garbage collection.
    ///
    /// ## Parameters
    ///
    /// - `threshold`: Memory threshold in bytes
    #[frb(sync)]
    pub fn set_gc_threshold(&self, threshold: usize) {
        self.rt.set_gc_threshold(threshold);
    }

    /// Forces garbage collection.
    ///
    /// Manually triggers garbage collection to free unused memory.
    /// This can be useful for memory management but should not be called
    /// excessively as it may impact performance.
    ///
    /// ## Example
    ///
    /// ```dart
    /// runtime.runGc();
    /// ```
    #[frb(sync)]
    pub fn run_gc(&self) {
        self.rt.run_gc();
    }

    /// Returns memory usage statistics.
    ///
    /// Provides detailed information about current memory allocation
    /// and usage patterns.
    ///
    /// ## Returns
    ///
    /// A `MemoryUsage` struct containing memory statistics
    ///
    /// ## Example
    ///
    /// ```dart
    /// final usage = runtime.memoryUsage();
    /// print('Total: ${usage.totalMemory} bytes');
    /// ```
    #[frb(sync)]
    pub fn memory_usage(&self) -> MemoryUsage {
        MemoryUsage(self.rt.memory_usage())
    }

    /// Checks whether the QuickJS job queue is non-empty.
    ///
    /// In the synchronous runtime this only reflects QuickJS jobs, such as
    /// pending Promise reaction callbacks created by already-resolved promises.
    /// It does not wait for external async work.
    ///
    /// ## Returns
    ///
    /// `true` if at least one QuickJS job is queued, `false` otherwise
    ///
    /// ## Example
    ///
    /// ```dart
    /// if (runtime.isJobPending()) {
    ///   runtime.executePendingJob();
    /// }
    /// ```
    #[frb(sync)]
    pub fn is_job_pending(&self) -> bool {
        self.rt.is_job_pending()
    }

    /// Executes one pending QuickJS job.
    ///
    /// This is a low-level pump for synchronous runtimes. It is mainly useful
    /// when you want explicit control over when Promise callbacks are drained.
    ///
    /// ## Returns
    ///
    /// `true` if one job was executed, `false` if the queue was empty
    ///
    /// ## Throws
    ///
    /// If the job throws while running
    ///
    /// ## Example
    ///
    /// ```dart
    /// while (runtime.isJobPending()) {
    ///   runtime.executePendingJob();
    /// }
    /// ```
    #[frb(sync)]
    pub fn execute_pending_job(&self) -> Result<bool, JsError> {
        self.rt
            .execute_pending_job()
            .map_err(|error| crate::runtime::job_error::sync_job_context(error.0))
    }

    /// Sets dump flags for debugging.
    ///
    /// Configures debug output flags for the QuickJS engine.
    /// Useful for development and troubleshooting.
    ///
    /// ## Parameters
    ///
    /// - `flags`: Debug flags to set
    #[frb(sync)]
    pub fn set_dump_flags(&self, flags: u64) {
        self.rt.set_dump_flags(flags);
    }

    /// Sets runtime info string.
    ///
    /// Sets informational metadata about the runtime instance.
    ///
    /// ## Parameters
    ///
    /// - `info`: Info string to set
    ///
    /// ## Throws
    ///
    /// If setting the info fails
    #[frb(sync)]
    pub fn set_info(&self, info: String) -> Result<(), JsError> {
        self.rt.set_info(info)?;
        Ok(())
    }
}

/// A synchronous JavaScript execution context.
///
/// `JsContext` provides a synchronous execution environment for JavaScript code.
/// Contexts are created from runtimes and maintain their own global state
/// while sharing the underlying runtime.
///
/// ## Note
///
/// Synchronous contexts do not support Promise/async operations.
/// Use `JsAsyncContext` for asynchronous code execution.
///
/// ## Example
///
/// ```dart
/// final runtime = JsRuntime();
/// final context = JsContext.from(runtime: runtime);
/// final result = context.eval(code: 'Math.sqrt(16)');
/// print(result.value); // 4
/// ```
#[frb(opaque)]
#[derive(Clone)]
pub struct JsContext {
    pub(crate) ctx: rquickjs::Context,
    pub(crate) global_attachment: Option<GlobalAttachment>,
}

impl JsContext {
    /// Creates a new context from a runtime.
    ///
    /// The context will inherit the runtime's module configuration
    /// and global attachments.
    ///
    /// ## Parameters
    ///
    /// - `runtime`: The runtime to create the context from
    ///
    /// ## Returns
    ///
    /// A new `JsContext` instance
    ///
    /// ## Throws
    ///
    /// If context creation fails
    ///
    /// ## Example
    ///
    /// ```dart
    /// final runtime = JsRuntime();
    /// final context = JsContext.from(runtime: runtime);
    /// ```
    #[frb(sync)]
    pub fn from(runtime: &JsRuntime) -> Result<Self, JsError> {
        let context = rquickjs::Context::full(&runtime.rt)?;
        context.with(|ctx| install_value_intrinsics(&ctx))?;
        Ok(Self {
            ctx: context,
            global_attachment: runtime.global_attachment.clone(),
        })
    }

    /// Evaluates JavaScript code.
    ///
    /// Evaluates the given code string with default options.
    /// Promise/async operations are not supported in sync context.
    ///
    /// ## Parameters
    ///
    /// - `code`: JavaScript code to evaluate
    ///
    /// ## Returns
    ///
    /// The result of evaluation as a `JsValue`
    ///
    /// ## Example
    ///
    /// ```dart
    /// final result = context.eval(code: '2 + 2');
    /// print(result.value); // 4
    /// ```
    #[frb(sync)]
    pub fn eval(&self, code: String) -> JsResult {
        self.eval_with_options(code, JsEvalOptions::defaults())
    }

    /// Evaluates JavaScript code with options.
    ///
    /// Provides fine-grained control over evaluation settings.
    /// Promise/async operations are not supported in sync context.
    ///
    /// ## Parameters
    ///
    /// - `code`: JavaScript code to evaluate
    /// - `options`: Evaluation options
    ///
    /// ## Returns
    ///
    /// The result of evaluation as a `JsValue`
    ///
    /// ## Throws
    ///
    /// - If promise option is enabled (not supported in sync context)
    /// - If code evaluation fails
    #[frb(sync)]
    pub fn eval_with_options(&self, code: String, options: JsEvalOptions) -> JsResult {
        if options.promise.unwrap_or(false) {
            return JsResult::Err(JsError::promise("Promise not supported in sync context"));
        }
        self.ctx.with(|ctx| {
            if let Some(attachment) = &self.global_attachment {
                if let Err(e) = attachment.attach(&ctx) {
                    return JsResult::Err(JsError::context(format!(
                        "Failed to attach global context: {}",
                        e
                    )));
                }
            }
            let res = ctx.eval_with_options(code, options.into());
            result_from_sync(&ctx, res)
        })
    }

    /// Evaluates JavaScript code from a file.
    ///
    /// Reads and executes JavaScript code from the specified file path.
    ///
    /// ## Parameters
    ///
    /// - `path`: Path to the JavaScript file
    ///
    /// ## Returns
    ///
    /// The result of evaluation as a `JsValue`
    ///
    /// ## Throws
    ///
    /// - If promise option is enabled (not supported in sync context)
    /// - If file cannot be read
    /// - If code evaluation fails
    ///
    /// ## Example
    ///
    /// ```dart
    /// final result = context.evalFile(path: '/path/to/script.js');
    /// ```
    #[frb(sync)]
    pub fn eval_file(&self, path: String) -> JsResult {
        self.eval_file_with_options(path, JsEvalOptions::defaults())
    }

    /// Evaluates JavaScript code from a file with options.
    ///
    /// Reads and executes JavaScript code from the specified file path
    /// with custom evaluation options.
    ///
    /// ## Parameters
    ///
    /// - `path`: Path to the JavaScript file
    /// - `options`: Evaluation options
    ///
    /// ## Returns
    ///
    /// The result of evaluation as a `JsValue`
    ///
    /// ## Throws
    ///
    /// - If promise option is enabled (not supported in sync context)
    /// - If file cannot be read
    /// - If code evaluation fails
    #[frb(sync)]
    pub fn eval_file_with_options(&self, path: String, options: JsEvalOptions) -> JsResult {
        if options.promise.unwrap_or(false) {
            return JsResult::Err(JsError::promise("Promise not supported in sync context"));
        }
        let source = match get_raw_source_code_sync(JsCode::Path(path.clone())) {
            Ok(source) => source,
            Err(error) => return JsResult::Err(error),
        };
        let options = file_eval_options(&path, options);
        self.ctx.with(|ctx| {
            if let Some(attachment) = &self.global_attachment {
                if let Err(e) = attachment.attach(&ctx) {
                    return JsResult::Err(JsError::context(format!(
                        "Failed to attach global context: {}",
                        e
                    )));
                }
            }
            let res = ctx.eval_with_options(source, options);
            result_from_sync(&ctx, res)
        })
    }

    /// Returns all modules currently available in this context.
    ///
    /// This includes builtin modules, statically configured modules,
    /// and any dynamically declared modules attached to the context.
    #[frb(sync)]
    pub fn get_available_modules(&self) -> Result<Vec<String>, JsError> {
        self.ctx.with(|ctx| {
            if let Some(attachment) = &self.global_attachment {
                attachment.attach(&ctx).map_err(|e| {
                    JsError::context(format!("Failed to attach global context: {e}"))
                })?;
            }
            Ok(get_available_module_names(&ctx))
        })
    }
}

/// An asynchronous JavaScript runtime.
///
/// `JsAsyncRuntime` provides an asynchronous execution environment for JavaScript code.
/// It supports Promise/async operations and is recommended for most use cases.
///
/// ## Example
///
/// ```dart
/// final runtime = await JsAsyncRuntime.create(builtins: JsBuiltinOptions.all());
/// final context = await JsAsyncContext.from(runtime: runtime);
/// ```
#[frb(opaque)]
#[derive(Clone)]
pub struct JsAsyncRuntime {
    pub(crate) rt: rquickjs::AsyncRuntime,
    pub(crate) global_attachment: Option<GlobalAttachment>,
    pub(crate) driver: crate::runtime::driver::DriverController,
    pub(crate) shutdown: RuntimeShutdown,
    pub(crate) cleaned: Arc<AtomicBool>,
    pub(crate) runtime_lifetime: Option<Arc<()>>,
}

impl JsAsyncRuntime {
    fn start_driver_now(&self) {
        self.driver.start(self.rt.clone());
    }

    async fn install_error_tracker(
        runtime: &rquickjs::AsyncRuntime,
        driver: crate::runtime::driver::DriverController,
    ) {
        let rejection_driver = driver.clone();
        runtime
            .set_host_promise_rejection_tracker(Some(Box::new(
                move |ctx, promise, reason, is_handled| {
                    let source = DriverErrorSource::promise(&promise);
                    let error = crate::runtime::job_error::format_value(&ctx, reason);
                    if !is_handled {
                        rejection_driver.push_error_from(source, error);
                    } else {
                        rejection_driver.remove_error_source(source);
                    }
                },
            )))
            .await;
    }

    /// Creates a new async runtime with default configuration.
    ///
    /// The runtime is created with no builtin modules. Use `create()`
    /// to create a runtime with custom builtin modules.
    ///
    /// ## Returns
    ///
    /// A new `JsAsyncRuntime` instance
    ///
    /// ## Example
    ///
    /// ```dart
    /// final runtime = JsAsyncRuntime();
    /// ```
    #[frb(sync)]
    pub fn new() -> Result<Self, JsError> {
        let runtime = rquickjs::AsyncRuntime::new()?;
        crate::runtime::error_sink::install_llrt_spawn_error_handler();
        futures::executor::block_on(
            runtime.set_max_stack_size(crate::runtime::stack::ASYNC_MAX_STACK_SIZE),
        );
        let driver = crate::runtime::driver::DriverController::default();
        futures::executor::block_on(Self::install_error_tracker(&runtime, driver.clone()));
        let shutdown = RuntimeShutdown::default();
        let interrupt_shutdown = shutdown.clone();
        let interrupt_driver = driver.clone();
        futures::executor::block_on(runtime.set_interrupt_handler(Some(Box::new(move || {
            if !interrupt_shutdown.requested() && interrupt_driver.execution_interrupted() {
                interrupt_shutdown.request_timeout(interrupt_driver.execution_timeout_millis());
            }
            interrupt_shutdown.requested()
        }))));
        install_default_async_loaders(&runtime);
        let runtime = Self {
            rt: runtime,
            global_attachment: None,
            driver,
            shutdown,
            cleaned: Arc::new(AtomicBool::new(false)),
            runtime_lifetime: Some(Arc::new(())),
        };
        runtime.start_driver_now();
        Ok(runtime)
    }

    /// Creates a new async runtime with custom configuration.
    ///
    /// This method creates a runtime with support for Node.js-compatible
    /// builtin modules and custom modules.
    ///
    /// ## Parameters
    /// - `builtins`: Optional builtin module configuration (e.g., console, fs, crypto)
    /// - `modules`: Optional list of additional modules to register
    ///
    /// ## Returns
    ///
    /// A new `JsAsyncRuntime` instance with configured modules
    ///
    /// ## Example
    ///
    /// ```dart
    /// final runtime = await JsAsyncRuntime.create(
    ///   builtins: JsBuiltinOptions.all(),
    ///   modules: [
    ///     JsModule.code(module: 'my-utils', code: 'export const foo = "bar";'),
    ///   ],
    /// );
    /// ```
    pub async fn create(
        builtins: Option<JsBuiltinOptions>,
        modules: Option<Vec<JsModule>>,
    ) -> Result<Self, JsError> {
        let runtime = rquickjs::AsyncRuntime::new()?;
        crate::runtime::error_sink::install_llrt_spawn_error_handler();
        runtime
            .set_max_stack_size(crate::runtime::stack::ASYNC_MAX_STACK_SIZE)
            .await;
        let driver = crate::runtime::driver::DriverController::default();
        Self::install_error_tracker(&runtime, driver.clone()).await;
        let shutdown = RuntimeShutdown::default();
        let interrupt_shutdown = shutdown.clone();
        let interrupt_driver = driver.clone();
        runtime
            .set_interrupt_handler(Some(Box::new(move || {
                if !interrupt_shutdown.requested() && interrupt_driver.execution_interrupted() {
                    interrupt_shutdown.request_timeout(interrupt_driver.execution_timeout_millis());
                }
                interrupt_shutdown.requested()
            })))
            .await;
        let (
            module_resolver,
            module_loader,
            additional_resolver,
            additional_loader,
            global_attachment,
        ) = JsRuntime::build_loaders(builtins, modules).await?;

        let (resolver, loader) = make_loader_stack(
            module_resolver,
            module_loader,
            additional_resolver,
            additional_loader,
        );
        runtime.set_loader(resolver, loader).await;

        let runtime = Self {
            rt: runtime,
            global_attachment: Some(global_attachment),
            driver,
            shutdown,
            cleaned: Arc::new(AtomicBool::new(false)),
            runtime_lifetime: Some(Arc::new(())),
        };
        runtime.start_driver_now();
        Ok(runtime)
    }

    pub(crate) async fn cleanup_once(
        runtime: rquickjs::AsyncRuntime,
        driver: crate::runtime::driver::DriverController,
        shutdown: RuntimeShutdown,
        cleaned: Arc<AtomicBool>,
    ) {
        if cleaned.swap(true, Ordering::AcqRel) {
            return;
        }

        shutdown.request();
        driver.stop().await;
        if runtime.is_job_pending().await {
            runtime.idle().await;
        }
        runtime.run_gc().await;
    }

    pub(crate) async fn cleanup_after_context_drop(runtime: rquickjs::AsyncRuntime) {
        runtime.run_gc().await;
    }

    pub(crate) fn take_unhandled_job_errors(&self) -> Vec<String> {
        self.driver.drain_errors()
    }

    fn finalize_runtime_drop(
        runtime: rquickjs::AsyncRuntime,
        driver: crate::runtime::driver::DriverController,
        shutdown: RuntimeShutdown,
        cleaned: Arc<AtomicBool>,
    ) {
        // Drop must never block the calling thread (often the Dart main
        // thread); cleanup runs detached on the JS executor instead.
        crate::runtime::executor::spawn_js(async move {
            JsAsyncRuntime::cleanup_once(runtime, driver, shutdown, cleaned).await;
        });
    }

    fn finalize_context_drop(
        context: rquickjs::AsyncContext,
        runtime: rquickjs::AsyncRuntime,
        driver: crate::runtime::driver::DriverController,
        shutdown: RuntimeShutdown,
        cleaned: Arc<AtomicBool>,
        is_last_runtime_owner: bool,
    ) {
        crate::runtime::executor::spawn_js(async move {
            drop(context);
            JsAsyncRuntime::cleanup_after_context_drop(runtime.clone()).await;
            if is_last_runtime_owner {
                JsAsyncRuntime::cleanup_once(runtime, driver, shutdown, cleaned).await;
            }
        });
    }

    pub(crate) fn request_shutdown(&self) {
        self.shutdown.request();
    }

    pub(crate) fn shutdown(&self) -> RuntimeShutdown {
        self.shutdown.clone()
    }

    /// Sets the memory limit.
    ///
    /// Once the memory limit is reached, JavaScript execution will fail
    /// with a memory limit error.
    ///
    /// ## Parameters
    ///
    /// - `limit`: Maximum memory in bytes
    ///
    /// ## Example
    ///
    /// ```dart
    /// await runtime.setMemoryLimit(limit: 16 * 1024 * 1024); // 16 MB
    /// ```
    pub async fn set_memory_limit(&self, limit: usize) {
        self.rt.set_memory_limit(limit).await;
    }

    /// Sets the maximum stack size.
    ///
    /// Limits the maximum depth of the JavaScript call stack to prevent
    /// stack overflow errors.
    ///
    /// ## Parameters
    ///
    /// - `limit`: Maximum stack size in bytes
    pub async fn set_max_stack_size(&self, limit: usize) {
        self.rt
            .set_max_stack_size(crate::runtime::stack::clamp_async(limit))
            .await;
    }

    /// Sets the garbage collection threshold.
    ///
    /// Configures when the runtime should trigger automatic garbage collection.
    ///
    /// ## Parameters
    ///
    /// - `threshold`: Memory threshold in bytes
    pub async fn set_gc_threshold(&self, threshold: usize) {
        self.rt.set_gc_threshold(threshold).await;
    }

    /// Forces garbage collection.
    ///
    /// Manually triggers garbage collection to free unused memory.
    /// This can be useful for memory management but should not be called
    /// excessively as it may impact performance.
    ///
    /// ## Example
    ///
    /// ```dart
    /// await runtime.runGc();
    /// ```
    pub async fn run_gc(&self) {
        let runtime = self.rt.clone();
        crate::runtime::executor::run_js(async move {
            runtime.run_gc().await;
        })
        .await;
    }

    /// Returns memory usage statistics.
    ///
    /// Provides detailed information about current memory allocation
    /// and usage patterns.
    ///
    /// ## Returns
    ///
    /// A `MemoryUsage` struct containing memory statistics
    ///
    /// ## Example
    ///
    /// ```dart
    /// final usage = await runtime.memoryUsage();
    /// print('Total: ${usage.totalMemory} bytes');
    /// ```
    pub async fn memory_usage(&self) -> MemoryUsage {
        let runtime = self.rt.clone();
        crate::runtime::executor::run_js(async move { MemoryUsage(runtime.memory_usage().await) })
            .await
    }

    /// Checks whether the async runtime still has work to do.
    ///
    /// This reports both queued QuickJS jobs and background futures managed by
    /// the runtime scheduler, such as timers or other spawned async work.
    ///
    /// ## Returns
    ///
    /// `true` if the runtime still has queued jobs or scheduled async work,
    /// `false` otherwise
    ///
    /// ## Example
    ///
    /// ```dart
    /// if (await runtime.isJobPending()) {
    ///   await runtime.executePendingJob();
    /// }
    /// ```
    pub(crate) async fn is_job_pending(&self) -> bool {
        self.rt.is_job_pending().await
    }

    /// Advances the async runtime by one scheduler step.
    ///
    /// This may execute one queued QuickJS job or make progress on background
    /// runtime futures. A `false` return value only means this call did not make
    /// progress; it does not guarantee the runtime is fully drained. Use
    /// `idle()` when you explicitly want to run the runtime until quiescent.
    ///
    /// ## Returns
    ///
    /// `true` if this call executed a job or advanced pending async work,
    /// `false` if nothing progressed during this step
    ///
    /// ## Throws
    ///
    /// If a scheduled job throws while running
    ///
    /// ## Example
    ///
    /// ```dart
    /// while (await runtime.isJobPending()) {
    ///   final progressed = await runtime.executePendingJob();
    ///   if (!progressed) {
    ///     break;
    ///   }
    /// }
    /// ```
    #[cfg(test)]
    pub(crate) async fn execute_pending_job(&self) -> Result<bool, JsError> {
        let runtime = self.rt.clone();
        crate::runtime::executor::run_js(async move {
            match runtime.execute_pending_job().await {
                Ok(progressed) => Ok(progressed),
                Err(error) => Err(crate::runtime::job_error::async_job_context(error.0).await),
            }
        })
        .await
    }

    /// Runs the async runtime until no queued jobs or spawned futures remain.
    ///
    /// This is a full drain operation. It may execute timers, promise callbacks,
    /// and other background work unrelated to the call site, so it should be used
    /// deliberately for teardown, tests, or explicit "drain everything" flows.
    ///
    /// QuickJS job errors raised during this drain are handled by the underlying
    /// runtime and are not surfaced through this method.
    ///
    /// ## Example
    ///
    /// ```dart
    /// await runtime.idle();
    /// ```
    pub(crate) async fn idle(&self) {
        let runtime = self.rt.clone();
        crate::runtime::executor::run_js(async move {
            runtime.idle().await;
        })
        .await;
    }

    /// Starts the runtime background driver.
    ///
    /// The driver keeps timers, fetches, spawned futures, and queued Promise
    /// work moving without requiring the host to poll `execute_pending_job()`.
    /// Starting an already-running driver is a no-op.
    #[cfg(test)]
    pub(crate) async fn start_driver(&self) {
        self.start_driver_now();
    }

    /// Stops the runtime background driver.
    ///
    /// Stopping is idempotent. The runtime remains usable afterwards; callers
    /// can still evaluate code or restart the driver later.
    pub(crate) async fn stop_driver(&self) {
        self.driver.stop().await;
    }

    /// Returns whether the runtime background driver is currently running.
    #[cfg(test)]
    pub(crate) async fn driver_running(&self) -> bool {
        self.driver.running()
    }

    /// Drains unhandled asynchronous JavaScript errors captured by the runtime.
    ///
    /// The queue is bounded and stores formatted strings, so draining never
    /// exposes live JavaScript values or keeps QuickJS objects alive.
    #[cfg(test)]
    pub(crate) async fn drain_unhandled_job_errors(&self) -> Vec<String> {
        self.take_unhandled_job_errors()
    }

    /// Sets runtime info string.
    ///
    /// Sets informational metadata about the runtime instance.
    ///
    /// ## Parameters
    ///
    /// - `info`: Info string to set
    ///
    /// ## Throws
    ///
    /// If setting the info fails
    pub async fn set_info(&self, info: String) -> Result<(), JsError> {
        self.rt.set_info(info).await?;
        Ok(())
    }
}

impl Drop for JsAsyncRuntime {
    fn drop(&mut self) {
        #[cfg(test)]
        if let Some(lifetime) = &self.runtime_lifetime {
            wait_at_runtime_drop_barrier(lifetime);
        }
        if !take_last_owner(&mut self.runtime_lifetime) {
            return;
        }

        let runtime = self.rt.clone();
        let driver = self.driver.clone();
        let shutdown = self.shutdown.clone();
        let cleaned = self.cleaned.clone();
        JsAsyncRuntime::finalize_runtime_drop(runtime, driver, shutdown, cleaned);
    }
}

/// An asynchronous JavaScript execution context.
///
/// `JsAsyncContext` provides an asynchronous execution environment for JavaScript code.
/// It supports Promise/async operations and is the recommended context type for
/// most applications.
///
/// ## Example
///
/// ```dart
/// final runtime = await JsAsyncRuntime.create(builtins: JsBuiltinOptions.all());
/// final context = await JsAsyncContext.from(runtime: runtime);
/// final result = await context.eval(code: 'await Promise.resolve(42)');
/// print(result.value); // 42
/// ```
#[frb(opaque)]
#[derive(Clone)]
pub struct JsAsyncContext {
    pub(crate) ctx: Option<rquickjs::AsyncContext>,
    pub(crate) runtime: rquickjs::AsyncRuntime,
    pub(crate) driver: crate::runtime::driver::DriverController,
    pub(crate) shutdown: RuntimeShutdown,
    pub(crate) cleaned: Arc<AtomicBool>,
    pub(crate) runtime_lifetime: Option<Arc<()>>,
    pub(crate) context_lifetime: Option<Arc<()>>,
    pub(crate) global_attachment: Option<GlobalAttachment>,
}

impl JsAsyncContext {
    fn take_unhandled_job_error(&self) -> Option<JsError> {
        let errors = self.driver.drain_errors();
        if errors.is_empty() {
            None
        } else {
            Some(JsError::runtime(format!(
                "Unhandled JavaScript background error: {}",
                errors.join("\n")
            )))
        }
    }

    fn ensure_no_unhandled_job_errors(&self) -> Result<(), JsError> {
        if self.shutdown.requested() {
            return Err(self.shutdown.error());
        }
        if let Some(error) = self.take_unhandled_job_error() {
            Err(error)
        } else {
            Ok(())
        }
    }

    pub(crate) async fn with_foreground_js_result<F>(&self, f: F) -> JsResult
    where
        F: for<'js> AsyncFnOnce(rquickjs::Ctx<'js>, u64) -> JsResult + Send + 'static,
    {
        if self.shutdown.requested() {
            return JsResult::Err(self.shutdown.error());
        }
        let checkpoint = self.driver.error_checkpoint();
        let shutdown = self.shutdown.clone();
        self.with_js(async move |ctx| {
            if shutdown.requested() {
                return JsResult::Err(shutdown.error());
            }
            f(ctx, checkpoint).await
        })
        .await
    }

    pub(crate) async fn with_js<F, R>(&self, f: F) -> R
    where
        F: for<'js> AsyncFnOnce(rquickjs::Ctx<'js>) -> R + Send + 'static,
        R: Send + 'static,
    {
        let context = self
            .ctx
            .as_ref()
            .expect("JavaScript async context was already dropped")
            .clone();
        let driver = self.driver.clone();
        let result = crate::runtime::executor::run_js(async move {
            driver.with_execution_budget(context.async_with(f)).await
        })
        .await;
        // Foreground work may have scheduled timers, detached promises, or
        // spawned futures; wake the driver so it picks them up immediately.
        self.driver.notify_work();
        result
    }

    /// Creates a new async context from a runtime.
    ///
    /// The context will inherit the runtime's module configuration
    /// and global attachments, and will be initialized with support
    /// for dynamic module loading.
    ///
    /// ## Parameters
    ///
    /// - `runtime`: The runtime to create the context from
    ///
    /// ## Returns
    ///
    /// A new `JsAsyncContext` instance
    ///
    /// ## Throws
    ///
    /// If context creation or initialization fails
    ///
    /// ## Example
    ///
    /// ```dart
    /// final runtime = await JsAsyncRuntime.create(builtins: JsBuiltinOptions.all());
    /// final context = await JsAsyncContext.from(runtime: runtime);
    /// ```
    pub async fn from(runtime: &JsAsyncRuntime) -> Result<Self, JsError> {
        let runtime_handle = runtime.rt.clone();
        let context = crate::runtime::executor::run_js(async move {
            rquickjs::AsyncContext::full(&runtime_handle).await
        })
        .await?;
        let dynamic_modules: DynamicModuleStorage =
            Arc::new(RwLock::new(std::collections::HashMap::<
                String,
                DynamicModuleEntry,
            >::new()));
        let loaded_dynamic_modules = LoadedDynamicModules::default();

        let context_for_userdata = context.clone();
        let error_sink = crate::runtime::error_sink::RuntimeErrorSink::new(runtime.driver.clone());
        crate::runtime::executor::run_js(async move {
            context_for_userdata
                .async_with(async |ctx| {
                    ctx.store_userdata(error_sink).map_err(|e| {
                        JsError::storage(format!("Failed to store runtime error sink: {e:?}"))
                    })?;
                    ctx.store_userdata(dynamic_modules.clone()).map_err(|e| {
                        JsError::storage(format!("Failed to store dynamic modules: {e:?}"))
                    })?;
                    ctx.store_userdata(loaded_dynamic_modules).map_err(|e| {
                        JsError::storage(format!("Failed to store loaded dynamic modules: {e:?}"))
                    })?;
                    Ok::<(), JsError>(())
                })
                .await
        })
        .await?;

        let context_for_intrinsics = context.clone();
        crate::runtime::executor::run_js(async move {
            context_for_intrinsics
                .async_with(async |ctx| install_value_intrinsics(&ctx))
                .await
        })
        .await?;

        Ok(Self {
            ctx: Some(context),
            runtime: runtime.rt.clone(),
            driver: runtime.driver.clone(),
            shutdown: runtime.shutdown.clone(),
            cleaned: runtime.cleaned.clone(),
            runtime_lifetime: runtime.runtime_lifetime.clone(),
            context_lifetime: Some(Arc::new(())),
            global_attachment: runtime.global_attachment.clone(),
        })
    }

    /// Evaluates JavaScript code.
    ///
    /// Evaluates the given code string with promise support enabled.
    /// Top-level await is supported.
    ///
    /// ## Parameters
    ///
    /// - `code`: JavaScript code to evaluate
    ///
    /// ## Returns
    ///
    /// The result of evaluation as a `JsValue`
    ///
    /// ## Example
    ///
    /// ```dart
    /// final result = await context.eval(code: 'await Promise.resolve(42)');
    /// print(result.value); // 42
    /// ```
    pub async fn eval(&self, code: String) -> JsResult {
        self.eval_with_options(code, JsEvalOptions::with_promise())
            .await
    }

    /// Evaluates JavaScript code with options.
    ///
    /// Provides fine-grained control over evaluation settings.
    /// Promise support is automatically enabled.
    ///
    /// ## Parameters
    ///
    /// - `code`: JavaScript code to evaluate
    /// - `options`: Evaluation options
    ///
    /// ## Returns
    ///
    /// The result of evaluation as a `JsValue`
    ///
    /// ## Throws
    ///
    /// - If code evaluation fails
    /// - If global attachment fails
    pub async fn eval_with_options(&self, code: String, options: JsEvalOptions) -> JsResult {
        if self.shutdown.requested() {
            return JsResult::Err(self.shutdown.error());
        }
        if let Some(error) = self.take_unhandled_job_error() {
            return JsResult::Err(error);
        }

        let attachment = self.global_attachment.clone();
        let driver = self.driver.clone();
        let shutdown = self.shutdown.clone();
        self.with_foreground_js_result(async move |ctx, checkpoint| {
            if let Some(attachment) = &attachment
                && let Err(e) = attachment.attach(&ctx)
            {
                return JsResult::Err(JsError::context(e.to_string()));
            }
            let mut options = options;
            options.promise = Some(true);
            let res = ctx.eval_with_options(code, options.into());
            let driver = driver.clone();
            result_from_promise(&ctx, res, shutdown, move |source| {
                driver.remove_error_source_since(checkpoint, source);
            })
            .await
        })
        .await
    }

    /// Evaluates JavaScript code from a file.
    ///
    /// Reads and executes JavaScript code from the specified file path.
    /// Promise support is automatically enabled.
    ///
    /// ## Parameters
    ///
    /// - `path`: Path to the JavaScript file
    ///
    /// ## Returns
    ///
    /// The result of evaluation as a `JsValue`
    ///
    /// ## Throws
    ///
    /// - If file cannot be read
    /// - If code evaluation fails
    ///
    /// ## Example
    ///
    /// ```dart
    /// final result = await context.evalFile(path: '/path/to/script.js');
    /// ```
    pub async fn eval_file(&self, path: String) -> JsResult {
        self.eval_file_with_options(path, JsEvalOptions::with_promise())
            .await
    }

    /// Evaluates JavaScript code from a file with options.
    ///
    /// Reads and executes JavaScript code from the specified file path
    /// with custom evaluation options.
    ///
    /// ## Parameters
    ///
    /// - `path`: Path to the JavaScript file
    /// - `options`: Evaluation options
    ///
    /// ## Returns
    ///
    /// The result of evaluation as a `JsValue`
    ///
    /// ## Throws
    ///
    /// - If file cannot be read
    /// - If code evaluation fails
    pub async fn eval_file_with_options(&self, path: String, options: JsEvalOptions) -> JsResult {
        if self.shutdown.requested() {
            return JsResult::Err(self.shutdown.error());
        }
        if let Some(error) = self.take_unhandled_job_error() {
            return JsResult::Err(error);
        }

        let source = match get_raw_source_code(JsCode::Path(path.clone())).await {
            Ok(source) => source,
            Err(error) => return JsResult::Err(error),
        };
        let mut options = options;
        options.promise = Some(true);
        let options = file_eval_options(&path, options);

        let attachment = self.global_attachment.clone();
        let driver = self.driver.clone();
        let shutdown = self.shutdown.clone();
        self.with_foreground_js_result(async move |ctx, checkpoint| {
            if let Some(attachment) = &attachment
                && let Err(e) = attachment.attach(&ctx)
            {
                return JsResult::Err(JsError::context(e.to_string()));
            }
            let res = ctx.eval_with_options(source, options);
            let driver = driver.clone();
            result_from_promise(&ctx, res, shutdown, move |source| {
                driver.remove_error_source_since(checkpoint, source);
            })
            .await
        })
        .await
    }

    /// Evaluates a function from a module.
    ///
    /// Imports the specified module and invokes one of its exported functions.
    ///
    /// ## Parameters
    /// - `module`: The module name to import
    /// - `method`: The function name to call (must be exported from the module)
    /// - `params`: Optional parameters to pass to the function
    ///
    /// ## Returns
    ///
    /// The result of the function call as a `JsValue`
    ///
    /// ## Throws
    ///
    /// - If the module cannot be imported
    /// - If the function does not exist
    /// - If the function call fails
    ///
    /// ## Example
    ///
    /// ```dart
    /// // Call a function with parameters
    /// final result = await context.evalFunction(
    ///   module: 'math-utils',
    ///   method: 'add',
    ///   params: [JsValue.integer(1), JsValue.integer(2)],
    /// );
    /// print(result.value); // 3
    /// ```
    pub async fn eval_function(
        &self,
        module: String,
        method: String,
        params: Option<Vec<JsValue>>,
    ) -> JsResult {
        if self.shutdown.requested() {
            return JsResult::Err(self.shutdown.error());
        }
        if let Some(error) = self.take_unhandled_job_error() {
            return JsResult::Err(error);
        }

        let params = params.unwrap_or_default();
        let attachment = self.global_attachment.clone();
        let driver = self.driver.clone();
        let shutdown = self.shutdown.clone();
        self.with_foreground_js_result(async move |ctx, checkpoint| {
            if let Some(attachment) = &attachment
                && let Err(e) = attachment.attach(&ctx)
            {
                return JsResult::Err(JsError::context(format!(
                    "Failed to attach global context: {}",
                    e
                )));
            }
            let driver = driver.clone();
            call_module_method(&ctx, module, method, params, shutdown, move |source| {
                driver.remove_error_source_since(checkpoint, source);
            })
            .await
        })
        .await
    }

    /// Returns all modules currently available in this context.
    ///
    /// This includes builtin modules, statically configured modules,
    /// and any dynamically declared modules attached to the context.
    pub async fn get_available_modules(&self) -> Result<Vec<String>, JsError> {
        self.ensure_no_unhandled_job_errors()?;
        let attachment = self.global_attachment.clone();
        self.with_js(async move |ctx| {
            if let Some(attachment) = &attachment {
                attachment.attach(&ctx).map_err(|e| {
                    JsError::context(format!("Failed to attach global context: {e}"))
                })?;
            }
            Ok(get_available_module_names(&ctx))
        })
        .await
    }
}

impl Drop for JsAsyncContext {
    fn drop(&mut self) {
        #[cfg(test)]
        if let Some(lifetime) = &self.runtime_lifetime {
            wait_at_runtime_drop_barrier(lifetime);
        }
        let is_last_runtime_owner = take_last_owner(&mut self.runtime_lifetime);
        #[cfg(test)]
        if let Some(lifetime) = &self.context_lifetime {
            pause_non_last_runtime_owner_before_context_drop(lifetime, is_last_runtime_owner);
        }
        if !take_last_owner(&mut self.context_lifetime) {
            if is_last_runtime_owner {
                JsAsyncRuntime::finalize_runtime_drop(
                    self.runtime.clone(),
                    self.driver.clone(),
                    self.shutdown.clone(),
                    self.cleaned.clone(),
                );
            }
            return;
        }

        let Some(context) = self.ctx.take() else {
            return;
        };
        let runtime = self.runtime.clone();
        let driver = self.driver.clone();
        let shutdown = self.shutdown.clone();
        let cleaned = self.cleaned.clone();
        JsAsyncRuntime::finalize_context_drop(
            context,
            runtime,
            driver,
            shutdown,
            cleaned,
            is_last_runtime_owner,
        );
    }
}

/// Calls a method on a module.
pub(crate) async fn call_module_method<'js>(
    ctx: &rquickjs::Ctx<'js>,
    module: String,
    method: String,
    params: Vec<JsValue>,
    shutdown: RuntimeShutdown,
    acknowledge_error_source: impl Fn(DriverErrorSource),
) -> JsResult {
    let promise = match Module::import(ctx, module.clone()).catch(ctx) {
        Ok(p) => p,
        Err(e) => {
            return JsResult::Err(JsError::module(
                Some(module),
                None,
                format!("Failed to import: {}", e),
            ));
        }
    };

    let import_source = DriverErrorSource::promise(promise.as_ref());
    let module_value = match promise_value(ctx, promise, shutdown.clone()).await {
        Ok(v) => v,
        Err(e) => {
            if !matches!(e, JsError::Cancelled(_)) {
                acknowledge_error_source(import_source);
            }
            return JsResult::Err(JsError::module(
                Some(module),
                None,
                format!("Failed to import: {e}"),
            ));
        }
    };

    let obj = match module_value.as_object() {
        Some(o) => o,
        None => {
            return JsResult::Err(JsError::module(
                Some(module),
                None,
                "Module is not an object",
            ));
        }
    };

    let func_value: rquickjs::Result<rquickjs::Value> = obj.get(&method);
    let func = match func_value.catch(ctx) {
        Ok(v) if v.is_function() => match v.as_function() {
            Some(f) => f.clone(),
            None => {
                return JsResult::Err(JsError::module(
                    Some(module),
                    Some(method),
                    "Method is not a function",
                ));
            }
        },
        Ok(_) => {
            return JsResult::Err(JsError::module(
                Some(module),
                Some(method),
                "Method is not a function",
            ));
        }
        Err(e) => {
            return JsResult::Err(JsError::module(
                Some(module),
                Some(method),
                format!("Failed to get method: {}", e),
            ));
        }
    };

    let res = func.call::<_, MaybePromise>((rquickjs::function::Rest(params),));
    result_from_maybe_promise(ctx, res, shutdown, acknowledge_error_source).await
}

/// Helper function to convert sync result.
fn result_from_sync<'js>(
    ctx: &rquickjs::Ctx<'js>,
    res: rquickjs::Result<rquickjs::Value<'js>>,
) -> JsResult {
    match res.catch(ctx) {
        Ok(value) => match JsValue::from_js(ctx, value).catch(ctx) {
            Ok(value) => JsResult::Ok(value),
            Err(e) => JsResult::Err(JsError::from_caught(ctx, e)),
        },
        Err(e) => JsResult::Err(JsError::from_caught(ctx, e)),
    }
}

/// Helper function to convert promise result.
pub(crate) async fn result_from_promise<'js>(
    ctx: &rquickjs::Ctx<'js>,
    res: rquickjs::Result<Promise<'js>>,
    shutdown: RuntimeShutdown,
    acknowledge_error_source: impl Fn(DriverErrorSource),
) -> JsResult {
    match res.catch(ctx) {
        Ok(promise) => {
            let source = DriverErrorSource::promise(promise.as_ref());
            match promise_value(ctx, promise, shutdown.clone()).await {
                Ok(value) => {
                    result_from_value(ctx, value, shutdown, acknowledge_error_source).await
                }
                Err(e) => {
                    if !matches!(e, JsError::Cancelled(_)) {
                        acknowledge_error_source(source);
                    }
                    JsResult::Err(e)
                }
            }
        }
        Err(_) if shutdown.requested() => JsResult::Err(shutdown.error()),
        Err(e) => JsResult::Err(JsError::from_caught(ctx, e)),
    }
}

pub(crate) async fn result_from_maybe_promise<'js>(
    ctx: &rquickjs::Ctx<'js>,
    res: rquickjs::Result<MaybePromise<'js>>,
    shutdown: RuntimeShutdown,
    acknowledge_error_source: impl Fn(DriverErrorSource),
) -> JsResult {
    match res.catch(ctx) {
        Ok(value) => {
            let source = value
                .as_value()
                .as_promise()
                .map(|promise| DriverErrorSource::promise(promise.as_ref()));
            match maybe_promise_value(ctx, value, shutdown.clone()).await {
                Ok(value) => {
                    result_from_value(ctx, value, shutdown, acknowledge_error_source).await
                }
                Err(e) => {
                    if !matches!(e, JsError::Cancelled(_))
                        && let Some(source) = source
                    {
                        acknowledge_error_source(source);
                    }
                    JsResult::Err(e)
                }
            }
        }
        Err(_) if shutdown.requested() => JsResult::Err(shutdown.error()),
        Err(e) => JsResult::Err(JsError::from_caught(ctx, e)),
    }
}

/// Normalizes the single-field wrapper produced by QuickJS async evaluation.
///
/// `JS_EVAL_FLAG_ASYNC` exposes its resolved result as an object whose only
/// enumerable string key is `value`. Every asynchronous FJS result path uses
/// this helper after resolving a Promise or MaybePromise. Objects with any
/// additional enumerable string key are application values and stay intact.
fn normalize_quickjs_async_result<'js>(value: &mut rquickjs::Value<'js>) -> rquickjs::Result<()> {
    let Some(obj) = value.as_object() else {
        return Ok(());
    };

    let mut keys = obj.keys::<String>();
    let first_key = keys.next().transpose()?;
    let second_key = keys.next().transpose()?;

    if matches!(first_key.as_deref(), Some("value")) && second_key.is_none() {
        *value = obj.get("value")?;
    }

    Ok(())
}

async fn result_from_value<'js>(
    ctx: &rquickjs::Ctx<'js>,
    mut value: rquickjs::Value<'js>,
    shutdown: RuntimeShutdown,
    acknowledge_error_source: impl Fn(DriverErrorSource),
) -> JsResult {
    if shutdown.requested() {
        return JsResult::Err(shutdown.error());
    }
    if let Err(e) = normalize_quickjs_async_result(&mut value).catch(ctx) {
        if shutdown.requested() {
            return JsResult::Err(shutdown.error());
        }
        return JsResult::Err(JsError::from_caught(ctx, e));
    }

    while let Some(promise) = value.as_promise().cloned() {
        let source = DriverErrorSource::promise(promise.as_ref());
        value = match promise_value(ctx, promise, shutdown.clone()).await {
            Ok(v) => v,
            Err(e) => {
                if !matches!(e, JsError::Cancelled(_)) {
                    acknowledge_error_source(source);
                }
                return JsResult::Err(e);
            }
        };
        if let Err(e) = normalize_quickjs_async_result(&mut value).catch(ctx) {
            if shutdown.requested() {
                return JsResult::Err(shutdown.error());
            }
            return JsResult::Err(JsError::from_caught(ctx, e));
        }
    }

    while ctx.execute_pending_job() {
        if shutdown.requested() {
            return JsResult::Err(shutdown.error());
        }
        if ctx.has_exception() {
            return JsResult::Err(JsError::from_pending_exception(ctx));
        }
    }

    match JsValue::from_js(ctx, value).catch(ctx) {
        Ok(v) => JsResult::Ok(v),
        Err(_) if shutdown.requested() => JsResult::Err(shutdown.error()),
        Err(e) => JsResult::Err(JsError::from_caught(ctx, e)),
    }
}

async fn promise_value<'js>(
    ctx: &rquickjs::Ctx<'js>,
    promise: Promise<'js>,
    shutdown: RuntimeShutdown,
) -> Result<rquickjs::Value<'js>, JsError> {
    if shutdown.requested() {
        return Err(shutdown.error());
    }

    tokio::select! {
        result = promise.into_future::<rquickjs::Value>() => {
            match result.catch(ctx) {
                Ok(value) => Ok(value),
                Err(_) if shutdown.requested() => Err(shutdown.error()),
                Err(error) => Err(JsError::from_caught(ctx, error)),
            }
        }
        _ = shutdown.cancelled() => Err(shutdown.error()),
    }
}

async fn maybe_promise_value<'js>(
    ctx: &rquickjs::Ctx<'js>,
    value: MaybePromise<'js>,
    shutdown: RuntimeShutdown,
) -> Result<rquickjs::Value<'js>, JsError> {
    if shutdown.requested() {
        return Err(shutdown.error());
    }

    tokio::select! {
        result = value.into_future::<rquickjs::Value>() => {
            match result.catch(ctx) {
                Ok(value) => Ok(value),
                Err(_) if shutdown.requested() => Err(shutdown.error()),
                Err(error) => Err(JsError::from_caught(ctx, error)),
            }
        }
        _ = shutdown.cancelled() => Err(shutdown.error()),
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_quickjs_async_result;
    use crate::api::value::JsValue;
    use rquickjs::{Context, FromJs, Runtime};

    #[test]
    fn test_normalize_quickjs_async_result_wrapper_object() {
        let runtime = Runtime::new().unwrap();
        let context = Context::full(&runtime).unwrap();

        context.with(|ctx| {
            let mut value: rquickjs::Value = ctx.eval("({ value: 42 })").unwrap();
            normalize_quickjs_async_result(&mut value).unwrap();
            let js_value = JsValue::from_js(&ctx, value).unwrap();
            assert!(matches!(js_value, JsValue::Integer(42)));
        });
    }

    #[test]
    fn test_normalize_quickjs_async_result_preserves_multi_key_object() {
        let runtime = Runtime::new().unwrap();
        let context = Context::full(&runtime).unwrap();

        context.with(|ctx| {
            let mut value: rquickjs::Value = ctx.eval("({ value: 42, extra: true })").unwrap();
            normalize_quickjs_async_result(&mut value).unwrap();
            let js_value = JsValue::from_js(&ctx, value).unwrap();

            assert!(matches!(
                js_value,
                JsValue::Object(ref obj)
                    if matches!(obj.get("value"), Some(JsValue::Integer(42)))
                        && matches!(obj.get("extra"), Some(JsValue::Boolean(true)))
            ));
        });
    }
}
