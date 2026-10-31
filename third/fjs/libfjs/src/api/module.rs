//! # JavaScript Module System
//!
//! This module provides comprehensive support for JavaScript module loading,
//! resolution, and management within the FJS runtime. It implements both
//! static module registration and dynamic module loading capabilities.
//!
//! ## Features
//!
//! - **Dynamic Module Loading**: Load modules at runtime from files or inline code
//! - **Module Resolution**: Resolve module imports with custom resolvers
//! - **Global Attachments**: Initialize global objects and functions
//! - **Module Builders**: Fluent API for configuring runtime modules
//! - **Node.js Compatibility**: Support for standard Node.js modules
//!
//! ## Architecture
//!
//! The module system consists of several key components:
//!
//! - **Resolvers**: Handle module name resolution
//! - **Loaders**: Handle module content loading
//! - **Storage**: Manage dynamic module state
//! - **Builders**: Configure runtime module systems

use crate::api::source::JsBuiltinOptions;
use crate::bytecode_support::load_module_bytecode_checked;
use flutter_rust_bridge::frb;
use llrt_utils::module::ModuleInfo;
use rquickjs::loader::{ImportAttributes, Loader, ModuleLoader, Resolver};
use rquickjs::module::ModuleDef;
use rquickjs::{Ctx, Function, JsLifetime, Module, Value};
use std::collections::{HashMap, HashSet};
use std::marker::PhantomData;
use std::sync::{Arc, RwLock};

/// Dynamic module data stored on a context.
#[frb(ignore)]
#[derive(Debug, Clone)]
pub enum DynamicModuleEntry {
    /// UTF-8 JavaScript source bytes compiled under the registered module name when loaded.
    Source(Vec<u8>),
    /// QuickJS ES-module bytecode whose embedded module name must match the registered name.
    Bytecode(Vec<u8>),
}

// SAFETY: This type owns only Rust byte buffers and contains no context-bound
// JavaScript handles, so changing the marker lifetime cannot invalidate data.
unsafe impl<'js> JsLifetime<'js> for DynamicModuleEntry {
    type Changed<'to> = DynamicModuleEntry;
}

/// Shared storage for dynamically declared modules.
#[frb(ignore)]
pub type DynamicModuleStorage = Arc<RwLock<HashMap<String, DynamicModuleEntry>>>;

/// A resolver for dynamically loaded JavaScript modules.
///
/// This resolver handles the resolution of module names that have been
/// dynamically loaded at runtime. It works with the dynamic module storage
/// to provide access to modules that weren't available at compile time.
#[derive(Debug, Default)]
#[frb(ignore)]
pub struct DynamicModuleResolver {}

/// Tracks dynamic modules that have already been loaded into the QuickJS module cache.
///
/// Once a module name enters this set, it cannot be replaced or unloaded without
/// recreating the context.
#[frb(ignore)]
#[derive(Debug, Default)]
pub struct LoadedDynamicModules {
    names: RwLock<HashSet<String>>,
}

// SAFETY: This type owns only a lock-protected set of Rust strings and contains
// no context-bound JavaScript handles, so it is unchanged across JS lifetimes.
unsafe impl<'js> JsLifetime<'js> for LoadedDynamicModules {
    type Changed<'to> = LoadedDynamicModules;
}

impl LoadedDynamicModules {
    fn insert(&self, name: impl Into<String>) {
        self.names
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(name.into());
    }

    fn contains(&self, name: &str) -> bool {
        self.names
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(name)
    }

    fn snapshot(&self) -> Vec<String> {
        let mut names: Vec<_> = self
            .names
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .cloned()
            .collect();
        names.sort();
        names
    }
}

pub(crate) fn mark_dynamic_module_loaded(ctx: &Ctx<'_>, name: &str) {
    if let Some(loaded_modules) = crate::runtime::context_data::get::<LoadedDynamicModules>(&ctx) {
        loaded_modules.insert(name.to_string());
    }
}

pub(crate) fn is_dynamic_module_loaded(ctx: &Ctx<'_>, name: &str) -> bool {
    crate::runtime::context_data::get::<LoadedDynamicModules>(&ctx)
        .is_some_and(|loaded_modules| loaded_modules.contains(name))
}

pub(crate) fn get_loaded_dynamic_module_names(ctx: &Ctx<'_>) -> Vec<String> {
    crate::runtime::context_data::get::<LoadedDynamicModules>(&ctx)
        .map_or_else(Vec::new, |loaded_modules| loaded_modules.snapshot())
}

/// Resolves a relative specifier (`./x`, `../y`) against the importing
/// module's path. `base` is the importer; its last segment is dropped before
/// applying `name`'s segments. A rooted base remains rooted after resolution.
pub(crate) fn resolve_relative_specifier(base: &str, name: &str) -> String {
    let rooted = base.starts_with('/');
    let mut segments: Vec<&str> = base
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect();
    if !segments.is_empty() {
        segments.pop();
    }

    for segment in name.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                segments.pop();
            }
            value => segments.push(value),
        }
    }

    let resolved = segments.join("/");
    if rooted {
        format!("/{resolved}")
    } else {
        resolved
    }
}

fn normalize_dynamic_module_name(base: &str, name: &str) -> Option<String> {
    name.starts_with('.')
        .then(|| resolve_relative_specifier(base, name))
}

impl Resolver for DynamicModuleResolver {
    /// Resolves a dynamic module name.
    ///
    /// This method checks if the module exists in the dynamic module storage.
    /// If found, returns the module name; otherwise returns a resolving error.
    ///
    /// # Parameters
    ///
    /// - `ctx`: The JavaScript context
    /// - `base`: The base path for resolution
    /// - `name`: The module name to resolve
    ///
    /// # Returns
    ///
    /// Returns the resolved module name if found in storage.
    fn resolve<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        base: &str,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<String> {
        if let Some(modules_storage) =
            crate::runtime::context_data::get::<DynamicModuleStorage>(&ctx)
        {
            let modules = modules_storage
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if modules.contains_key(name) {
                return Ok(name.to_string());
            }
            if let Some(normalized) = normalize_dynamic_module_name(base, name)
                && modules.contains_key(&normalized)
            {
                return Ok(normalized);
            }
        }
        // Not found in dynamic storage, let other resolvers try
        Err(rquickjs::Error::new_resolving(base, name))
    }
}

/// A loader for dynamically loaded JavaScript modules.
///
/// This loader handles the actual loading of module content from the
/// dynamic module storage. It retrieves source code that has been
/// previously stored during runtime.
#[derive(Debug, Default)]
#[frb(ignore)]
pub struct DynamicModuleLoader {}

impl Loader for DynamicModuleLoader {
    /// Loads a dynamic module from storage.
    ///
    /// This method retrieves the source code for a module from the
    /// dynamic module storage and creates a declared module instance.
    ///
    /// # Parameters
    ///
    /// - `ctx`: The JavaScript context
    /// - `name`: The module name to load
    /// - `_attributes`: Import attributes (not used for dynamic modules)
    ///
    /// # Returns
    ///
    /// Returns a declared module or an error if the module is not found.
    fn load<'js>(
        &mut self,
        ctx: &Ctx<'js>,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<Module<'js, rquickjs::module::Declared>> {
        if let Some(modules_storage) =
            crate::runtime::context_data::get::<DynamicModuleStorage>(&ctx)
        {
            let entry = modules_storage
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get(name)
                .cloned();
            if let Some(entry) = entry {
                let module = match entry {
                    DynamicModuleEntry::Source(source) => {
                        Module::declare(ctx.clone(), name, source)?
                    }
                    DynamicModuleEntry::Bytecode(bytecode) => {
                        let module = load_module_bytecode_checked(ctx.clone(), name, &bytecode)?;
                        let embedded_name: String = module.name()?;
                        if embedded_name != name {
                            return Err(rquickjs::Error::new_loading_message(
                                name,
                                format!(
                                    "Bytecode module name mismatch: expected '{}', found '{}'",
                                    name, embedded_name
                                ),
                            ));
                        }
                        module
                    }
                };
                mark_dynamic_module_loaded(ctx, name);
                return Ok(module);
            }
        }
        Err(rquickjs::Error::new_loading(name))
    }
}

/// Stores a set of module names for a specific JavaScript context.
///
/// This struct maintains a list of available module names within a
/// specific context lifecycle. It uses a phantom marker to ensure
/// lifetime safety.
#[frb(ignore)]
pub struct ModuleNames<'js> {
    /// The set of module names
    list: HashSet<String>,
    /// Phantom data for lifetime tracking
    _marker: PhantomData<&'js ()>,
}

// SAFETY: `ModuleNames` owns its strings; its `'js` parameter appears only in
// `PhantomData` and does not guard a reference or a context-bound JS handle.
unsafe impl<'js> JsLifetime<'js> for ModuleNames<'js> {
    /// Allows the module names to be tracked across different lifetimes.
    ///
    /// This implementation enables safe usage of module names across
    /// different JavaScript context lifetimes while maintaining type safety.
    type Changed<'to> = ModuleNames<'to>;
}

impl ModuleNames<'_> {
    /// Creates a new module names storage with the given set of names.
    ///
    /// # Parameters
    ///
    /// - `names`: The initial set of module names
    ///
    /// # Returns
    ///
    /// Returns a new `ModuleNames` instance.
    pub fn new(names: HashSet<String>) -> Self {
        Self {
            list: names,
            _marker: PhantomData,
        }
    }

    /// Returns a copy of the module names list.
    ///
    /// # Returns
    ///
    /// Returns a cloned `HashSet` containing all module names.
    #[allow(dead_code)]
    pub fn get_list(&self) -> HashSet<String> {
        self.list.clone()
    }
}

pub(crate) fn get_available_module_names(ctx: &Ctx<'_>) -> Vec<String> {
    let mut names = HashSet::new();

    if let Some(module_names) = crate::runtime::context_data::get::<ModuleNames>(&ctx) {
        names.extend(module_names.list.iter().cloned());
    }

    if let Some(modules_storage) = crate::runtime::context_data::get::<DynamicModuleStorage>(&ctx) {
        names.extend(
            modules_storage
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .keys()
                .cloned(),
        );
    }

    let mut names: Vec<_> = names.into_iter().collect();
    names.sort();
    names
}

/// Manages global object attachments for JavaScript contexts.
///
/// This struct handles the attachment of global objects, functions,
/// and module names to JavaScript contexts. Each context will be
/// initialized independently when attach() is called.
#[frb(ignore)]
#[derive(Debug, Default, Clone)]
pub struct GlobalAttachment {
    /// Inner implementation with initialization data
    inner: Arc<GlobalAttachmentInner>,
}

/// Marker type to track if a context has been initialized with global attachments.
#[frb(ignore)]
pub(crate) struct GlobalAttachmentInitialized {}

// SAFETY: This zero-sized marker contains no references or context-bound
// JavaScript handles, so it is valid for every JavaScript lifetime.
unsafe impl<'js> JsLifetime<'js> for GlobalAttachmentInitialized {
    type Changed<'to> = GlobalAttachmentInitialized;
}

/// Inner implementation of global attachment management.
///
/// This struct contains the actual data for global attachments,
/// including module names and initialization functions.
#[frb(ignore)]
#[derive(Debug, Default)]
struct GlobalAttachmentInner {
    /// Set of module names to attach
    names: HashSet<String>,
    /// List of initialization functions to call
    functions: Vec<fn(&Ctx<'_>) -> rquickjs::Result<()>>,
}

impl GlobalAttachment {
    /// Adds a global initialization function to the attachment.
    ///
    /// This function will be called when the attachment is applied to a context.
    /// It can be used to set up global objects, functions, or other runtime state.
    ///
    /// # Parameters
    ///
    /// - `init`: A function that takes a context and performs initialization
    ///
    /// # Returns
    ///
    /// Returns self for method chaining.
    ///
    /// # Panics
    ///
    /// This method will panic if called after the attachment has been shared.
    pub fn add_function(mut self, init: fn(&Ctx<'_>) -> rquickjs::Result<()>) -> Self {
        // Get mutable access to inner before it's shared
        let inner = Arc::get_mut(&mut self.inner)
            .expect("GlobalAttachment should not be shared during construction");
        inner.functions.push(init);
        self
    }

    /// Adds a module name to the attachment.
    ///
    /// This name will be registered as an available module when the attachment
    /// is applied to a context.
    ///
    /// # Parameters
    ///
    /// - `path`: The module name to add
    ///
    /// # Returns
    ///
    /// Returns self for method chaining.
    ///
    /// # Panics
    ///
    /// This method will panic if called after the attachment has been shared.
    pub fn add_name<P: Into<String>>(mut self, path: P) -> Self {
        let inner = Arc::get_mut(&mut self.inner)
            .expect("GlobalAttachment should not be shared during construction");
        inner.names.insert(path.into());
        self
    }

    /// Attaches the global state to a JavaScript context.
    ///
    /// This method applies all registered module names and initialization functions
    /// to the given context. It uses context-level userdata to ensure that each
    /// context is only initialized once.
    ///
    /// # Parameters
    ///
    /// - `ctx`: The JavaScript context to attach to
    ///
    /// # Returns
    ///
    /// Returns Ok if attachment succeeds, or an error if initialization fails.
    pub fn attach(&self, ctx: &Ctx<'_>) -> rquickjs::Result<()> {
        // Check if this context has already been initialized
        if crate::runtime::context_data::get::<GlobalAttachmentInitialized>(&ctx).is_some() {
            return Ok(());
        }

        if !self.inner.names.is_empty() {
            let _ = crate::runtime::context_data::store(
                &ctx,
                ModuleNames::new(self.inner.names.clone()),
            );
        }
        for init in &self.inner.functions {
            init(ctx)?;
        }

        // Only mark the context initialized after all setup completed successfully.
        let _ = crate::runtime::context_data::store(&ctx, GlobalAttachmentInitialized {});
        Ok(())
    }
}

/// A resolver for static module names.
///
/// This resolver handles the resolution of statically known module names
/// that are registered at runtime configuration time.
#[frb(ignore)]
#[derive(Debug, Default)]
pub struct ModuleResolver {
    /// Set of registered module names
    modules: HashSet<String>,
}

impl ModuleResolver {
    /// Adds a module name to the resolver.
    ///
    /// # Parameters
    ///
    /// - `path`: The module name to add
    ///
    /// # Returns
    ///
    /// Returns self for method chaining.
    #[must_use]
    pub fn add_name<P: Into<String>>(mut self, path: P) -> Self {
        self.modules.insert(path.into());
        self
    }
}

impl Resolver for ModuleResolver {
    /// Resolves a module name if it's in the registered set.
    ///
    /// This method handles Node.js-style module names by stripping the "node:"
    /// prefix and checking if the resulting name is in the registered module set.
    ///
    /// # Parameters
    ///
    /// - `_`: The context (not used)
    /// - `base`: The base path for resolution
    /// - `name`: The module name to resolve
    ///
    /// # Returns
    ///
    /// Returns the resolved module name or an error if not found.
    fn resolve<'js>(
        &mut self,
        _: &Ctx<'js>,
        base: &str,
        name: &str,
        _attributes: Option<ImportAttributes<'js>>,
    ) -> rquickjs::Result<String> {
        let name = name.trim_start_matches("node:");
        if self.modules.contains(name) {
            Ok(name.into())
        } else {
            Err(rquickjs::Error::new_resolving(base, name))
        }
    }
}

/// A builder for configuring JavaScript runtime module systems.
///
/// This struct provides a fluent API for configuring module resolvers,
/// loaders, and global attachments for JavaScript runtimes. It supports
/// both static module registration and dynamic module capabilities.
#[frb(ignore)]
pub struct ModuleBuilder {
    /// The module resolver to use
    module_resolver: ModuleResolver,
    /// The module loader to use
    module_loader: ModuleLoader,
    /// The global attachment configuration
    global_attachment: GlobalAttachment,
}

impl ModuleBuilder {
    /// Creates a new module builder with default configuration.
    ///
    /// # Returns
    ///
    /// Returns a new `ModuleBuilder` with empty resolver, loader, and attachment.
    pub fn new() -> Self {
        Self {
            module_resolver: ModuleResolver::default(),
            module_loader: ModuleLoader::default(),
            global_attachment: GlobalAttachment::default(),
        }
    }

    /// Adds a module to the builder configuration.
    ///
    /// This method registers a module with the resolver, loader, and global attachment.
    /// The module will be available for import and loading in the JavaScript runtime.
    ///
    /// # Parameters
    ///
    /// - `module`: The module definition and information
    ///
    /// # Returns
    ///
    /// Returns self for method chaining.
    pub fn with_module<M: ModuleDef, I: Into<ModuleInfo<M>>>(mut self, module: I) -> Self {
        let module_info: ModuleInfo<M> = module.into();

        self.module_resolver = self.module_resolver.add_name(module_info.name);
        self.module_loader = self
            .module_loader
            .with_module(module_info.name, module_info.module);
        self.global_attachment = self.global_attachment.add_name(module_info.name);
        self
    }

    /// Adds a global initialization function to the builder.
    ///
    /// This function will be called when the module system is initialized
    /// and can be used to set up global objects, functions, or other state.
    ///
    /// # Parameters
    ///
    /// - `init`: The initialization function
    ///
    /// # Returns
    ///
    /// Returns self for method chaining.
    pub fn with_global(mut self, init: fn(&Ctx<'_>) -> rquickjs::Result<()>) -> Self {
        self.global_attachment = self.global_attachment.add_function(init);
        self
    }

    /// Builds the module system configuration.
    ///
    /// This method finalizes the configuration and returns the components
    /// needed to set up a JavaScript runtime with the configured modules.
    ///
    /// # Returns
    ///
    /// Returns a tuple containing the resolver, loader, and global attachment.
    pub fn build(self) -> (ModuleResolver, ModuleLoader, GlobalAttachment) {
        (
            self.module_resolver,
            self.module_loader,
            self.global_attachment,
        )
    }
}

impl Default for ModuleBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl JsBuiltinOptions {
    /// Converts builtin options to a module builder.
    ///
    /// Reveric build: only `timers` is compiled in. Callers must check
    /// [`JsBuiltinOptions::unsupported_builtins`] first; other options are
    /// rejected there instead of being silently ignored.
    #[frb(ignore)]
    pub fn to_module_builder(&self) -> ModuleBuilder {
        let mut builder = ModuleBuilder::new();

        if self.timers.unwrap_or(false) {
            builder = builder
                .with_global(init_guarded_timers)
                .with_module(llrt_timers::TimersModule);
        }

        builder
    }

    /// Names of enabled builtins that this build does not compile in.
    #[frb(ignore)]
    pub fn unsupported_builtins(&self) -> Vec<&'static str> {
        [
            ("abort", self.abort),
            ("assert", self.assert),
            ("asyncHooks", self.async_hooks),
            ("buffer", self.buffer),
            ("childProcess", self.child_process),
            ("console", self.console),
            ("crypto", self.crypto),
            ("dgram", self.dgram),
            ("dns", self.dns),
            ("events", self.events),
            ("exceptions", self.exceptions),
            ("fetch", self.fetch),
            ("fs", self.fs),
            ("https", self.https),
            ("intl", self.intl),
            ("navigator", self.navigator),
            ("net", self.net),
            ("os", self.os),
            ("path", self.path),
            ("perfHooks", self.perf_hooks),
            ("process", self.process),
            ("streamWeb", self.stream_web),
            ("stringDecoder", self.string_decoder),
            ("temporal", self.temporal),
            ("tty", self.tty),
            ("url", self.url),
            ("util", self.util),
            ("zlib", self.zlib),
            ("json", self.json),
        ]
        .into_iter()
        .filter(|(_, enabled)| enabled.unwrap_or(false))
        .map(|(name, _)| name)
        .collect()
    }
}

fn init_guarded_timers(ctx: &Ctx<'_>) -> rquickjs::Result<()> {
    llrt_timers::init(ctx)?;
    install_timer_callback_error_guard(ctx)
}

fn record_timer_callback_error<'js>(ctx: Ctx<'js>, error: Value<'js>) -> rquickjs::Result<bool> {
    if let Some(sink) =
        crate::runtime::context_data::get::<crate::runtime::error_sink::RuntimeErrorSink>(&ctx)
    {
        sink.push(crate::runtime::error_sink::format_value(&ctx, error));
        Ok(true)
    } else {
        Ok(false)
    }
}

fn install_timer_callback_error_guard(ctx: &Ctx<'_>) -> rquickjs::Result<()> {
    let reporter = Function::new(ctx.clone(), record_timer_callback_error)?;
    ctx.globals()
        .set("__fjsInstallTimerErrorReporter", reporter)?;
    ctx.eval::<(), _>(
        r#"
        (() => {
          const reporter = globalThis.__fjsInstallTimerErrorReporter;
          delete globalThis.__fjsInstallTimerErrorReporter;

          const guardDelayTimer = (nativeTimer) => function(callback, delay, ...args) {
            if (typeof callback !== "function") {
              return nativeTimer(callback, delay, ...args);
            }
            return nativeTimer(function() {
              try {
                return callback.apply(this, args);
              } catch (error) {
                if (!reporter(error)) {
                  throw error;
                }
              }
            }, delay);
          };

          const guardImmediate = (nativeTimer) => function(callback, ...args) {
            if (typeof callback !== "function") {
              return nativeTimer(callback, ...args);
            }
            return nativeTimer(function() {
              try {
                return callback.apply(this, args);
              } catch (error) {
                if (!reporter(error)) {
                  throw error;
                }
              }
            });
          };

          if (typeof globalThis.setTimeout === "function") {
            globalThis.setTimeout = guardDelayTimer(globalThis.setTimeout);
          }
          if (typeof globalThis.setInterval === "function") {
            globalThis.setInterval = guardDelayTimer(globalThis.setInterval);
          }
          if (typeof globalThis.setImmediate === "function") {
            globalThis.setImmediate = guardImmediate(globalThis.setImmediate);
          }
        })();
        "#,
    )
}
