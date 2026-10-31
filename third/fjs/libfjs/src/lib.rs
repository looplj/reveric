//! # FJS - Flutter JavaScript Engine
//!
//! This library provides a Flutter-compatible JavaScript runtime environment
//! built on top of the QuickJS engine. It enables execution of JavaScript code
//! within Flutter applications with support for both synchronous and asynchronous
//! operations, module systems, and bidirectional communication between Dart and JavaScript.
//!
//! ## Features
//!
//! - Synchronous and asynchronous JavaScript execution
//! - Module system support (ES6 modules and CommonJS)
//! - Built-in Node.js compatibility modules
//! - Memory management and garbage collection control
//! - Bidirectional Dart-JavaScript communication
//! - Error handling and debugging capabilities
//!
//! ## Architecture
//!
//! The library is organized into several key components:
//!
//! - **Runtime Management**: Core runtime and context handling
//! - **Value Conversion**: Type-safe conversion between Dart and JavaScript values
//! - **Module System**: Dynamic module loading and resolution
//! - **Error Handling**: Comprehensive error types and propagation
//!
//! ## Usage
//!
//! ```rust,ignore
//! use libfjs::api::{JsContext, JsRuntime};
//!
//! // Create a runtime and context
//! let runtime = JsRuntime::new()?;
//! let context = JsContext::from(&runtime)?;
//!
//! // Execute JavaScript code (returns a JsResult)
//! let result = context.eval("1 + 41".to_string());
//! assert!(result.is_ok());
//! ```

#![deny(missing_docs)]
#![deny(unsafe_op_in_unsafe_fn)]
#![warn(clippy::undocumented_unsafe_blocks)]

pub mod api;
mod bytecode_support;
#[allow(
    missing_docs,
    unsafe_op_in_unsafe_fn,
    clippy::undocumented_unsafe_blocks
)]
mod frb_generated;
mod runtime;
mod ui;

#[cfg(test)]
mod tests;
