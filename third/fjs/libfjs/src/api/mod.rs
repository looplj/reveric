//! # JavaScript API Module
//!
//! This module provides the core JavaScript execution API for Flutter integration.
//! It contains submodules for different aspects of JavaScript runtime management:
//!
//! - **runtime**: Runtime and context management
//! - **engine**: High-level engine with action processing
//! - **value**: Type-safe value conversion between Rust and JavaScript
//! - **error**: Comprehensive error types
//! - **source**: Source code and module definitions
//! - **module**: Module system and dynamic loading capabilities
//!
//! ## Initialization
//!
//! The `init_app()` function sets up the Flutter Rust bridge with default utilities.
//! This function should be called once during application initialization.

pub mod bytecode;
pub mod engine;
pub mod error;
pub mod module;
pub mod runtime;
pub mod source;
pub mod ui;
pub mod value;

// Re-export main types for convenience
pub use bytecode::JsBytecode;
pub use engine::{JsEngine, JsEngineRuntimeOptions};
pub use error::{JsError, JsResult};
pub use module::{DynamicModuleLoader, DynamicModuleResolver, GlobalAttachment, ModuleBuilder};
pub use runtime::{JsAsyncContext, JsAsyncRuntime, JsContext, JsRuntime, MemoryUsage};
pub use source::{
    JsBuiltinOptions, JsBytecodeEndianness, JsCode, JsEvalOptions, JsModule, JsModuleBytecode,
    JsModuleBytecodeBundle, JsModuleBytecodeOptions, JsScriptBytecode, JsScriptBytecodeOptions,
};
pub use value::JsValue;

/// Initializes the Flutter Rust bridge with default user utilities.
///
/// This function sets up the bridge configuration required for communication
/// between Flutter (Dart) and Rust code. It should be called once during
/// application startup before any other FJS functionality is used.
///
/// # Safety
///
/// This function is safe to call multiple times, but subsequent calls will
/// have no effect as the bridge is already initialized.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
}
