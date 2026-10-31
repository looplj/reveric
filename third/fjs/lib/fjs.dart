/// FJS - Flutter JavaScript Engine
///
/// A comprehensive Flutter library for executing JavaScript code within Flutter applications.
/// Built on top of the QuickJS engine, FJS provides a seamless integration between Dart and JavaScript,
/// enabling developers to run JavaScript code, use Node.js modules, and create hybrid applications.
///
/// ## Features
///
/// - **Synchronous and Asynchronous Execution**: Support for both sync and async JavaScript operations
/// - **Module System**: Full ES6 module support with dynamic loading capabilities
/// - **Node.js Compatibility**: Built-in support for common Node.js modules
/// - **Bidirectional Communication**: Call JavaScript from Dart and Dart from JavaScript
/// - **Memory Management**: Fine-grained control over memory usage and garbage collection
/// - **Type Safety**: Type-safe conversion between Dart and JavaScript values
/// - **Automatic Async Work**: Detached timers, Promises, fetches, and spawned JS work are driven internally
/// - **Error Handling**: Foreground failures throw a typed [JsError] classified from the real QuickJS
///   exception (syntax/type/reference/stack-overflow/memory-limit, with line, column, and stack text);
///   unhandled background JS errors surface on the next public operation, on `close()`, or via
///   `drainUnhandledJobErrors()`
///
/// ## Basic Usage
///
/// ```dart
/// import 'package:fjs/fjs.dart';
///
/// // Create an engine
/// final engine = await JsEngine.create(
///   builtins: JsBuiltinOptions.all(),
/// );
///
/// // Initialize the engine
/// await engine.initWithoutBridge();
///
/// // Execute JavaScript code
/// final result = await engine.eval(
///   source: JsCode.code('Math.random() * 100'),
/// );
///
/// print('Random number: ${result.value}');
///
/// await engine.close();
/// ```
///
/// Detached asynchronous JavaScript work is scheduled automatically after
/// `JsEngine.init()` or `JsEngine.initWithoutBridge()`. Use JavaScript
/// `.catch()` for expected detached failures. Unhandled background failures are
/// reported by a later `eval()`, `call()`, context operation, or `close()`.
/// In `3.2.0+`, `JsEngine.close()` is immediate and cancels in-flight
/// foreground work with `JsError.cancelled`; use `closeGracefully()` only when
/// shutdown should wait for already-scheduled JavaScript work to finish.
///
/// ## Module Usage
///
/// ```dart
/// // Load a module from file
/// await engine.declareNewModule(
///   module: JsModule.path(module: 'utils', path: '/path/to/utils.js'),
/// );
///
/// // Execute a function from a module
/// final result = await engine.eval(
///   source: JsCode.code('''
///     const { add } = await import('utils');
///     add(2, 3);
///   '''),
/// );
/// ```
///
/// ## Bridge Communication
///
/// ```dart
/// await engine.init(
///   bridge: (value) async {
///     print('JavaScript called: ${value.value}');
///     return JsResult.ok(JsValue.string('Hello from Dart!'));
///   },
/// );
/// ```

library;

// JavaScript API with high-level abstractions
export 'src/frb/api/bytecode.dart';
export 'src/frb/api/engine.dart';

// Dedicated native plugin UI sessions and typed tree protocol.
export 'src/frb/api/ui.dart';

// Error handling
export 'src/frb/api/error.dart';

// Runtime and context
export 'src/frb/api/runtime.dart';

// Source code and modules
export 'src/frb/api/source.dart';

// Value conversion and type handling
export 'src/frb/api/value.dart';

// Low-level generated bindings
export 'src/frb/frb_generated.dart' show LibFjs;
