import 'dart:async';
import 'dart:convert';

import 'package:fjs/fjs.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// JavaScript execution modes
enum JsExecutionMode {
  /// Script mode - uses eval(), does not support import statements
  script,

  /// Module mode - supports import/export statements
  module,
}

class FjsService extends ChangeNotifier {
  static const JsBuiltinOptions _builtinOptions = JsBuiltinOptions(
    console: true,
    fetch: true,
    timers: true,
    url: true,
  );
  static final RegExp _moduleSyntaxPattern = RegExp(
    '^\\s*(?:export\\b|import\\s+(?:["\\\'])|import\\s+.+\\s+from\\b)',
    multiLine: true,
  );

  JsEngine? _engine;
  _FjsSession? _sharedSession;
  _FjsModuleAssets? _moduleAssets;
  Completer<void>? _initializing;
  bool _isInitialized = false;
  bool _isExecuting = false;
  bool _isDisposed = false;
  String? _lastError;
  String? _lastExecutionResult;
  JsExecutionMode _lastExecutionMode = JsExecutionMode.script;

  bool get isInitialized => _isInitialized;

  bool get isExecuting => _isExecuting;

  String? get lastError => _lastError;

  String? get lastExecutionResult => _lastExecutionResult;

  JsExecutionMode get lastExecutionMode => _lastExecutionMode;

  JsExecutionMode inferExecutionMode(String code) {
    return _moduleSyntaxPattern.hasMatch(code)
        ? JsExecutionMode.module
        : JsExecutionMode.script;
  }

  Future<void> initialize() async {
    _ensureNotDisposed();

    if (_sharedSession != null) {
      return;
    }

    final inFlight = _initializing;
    if (inFlight != null) {
      return inFlight.future;
    }

    final completer = Completer<void>();
    _initializing = completer;

    try {
      _moduleAssets ??= await _loadModuleAssets();
      final session = await _createSession();

      if (_isDisposed) {
        await session.dispose();
        throw StateError('FjsService was disposed during initialization');
      }

      _sharedSession = session;
      _engine = session.engine;
      _isInitialized = true;
      _lastError = null;
      _notifyListeners();
      completer.complete();
    } catch (e, stackTrace) {
      _sharedSession = null;
      _engine = null;
      _isInitialized = false;
      _lastError = 'Failed to initialize FJS service: $e';
      _notifyListeners();
      completer.completeError(e, stackTrace);
      rethrow;
    } finally {
      if (identical(_initializing, completer)) {
        _initializing = null;
      }
    }
  }

  // ========== Basic Execution ==========

  /// Execute JavaScript code in Script mode
  ///
  /// Script mode uses eval() and does not support static import statements.
  /// If you need to use modules, use dynamic import() or executeAsModule().
  Future<JsValue> executeAsScript(String code) async {
    return _executeCode(code, JsExecutionMode.script);
  }

  /// Execute JavaScript code in Module mode
  ///
  /// Module mode supports import/export statements.
  /// Code will be wrapped as a module and evaluated.
  Future<JsValue> executeAsModule(String code) async {
    return _executeCode(code, JsExecutionMode.module);
  }

  /// Internal execution method
  Future<JsValue> _executeCode(String code, JsExecutionMode mode) async {
    _ensureNotDisposed();

    if (_isExecuting) {
      throw StateError('Another execution is in progress');
    }

    if (code.trim().isEmpty) {
      _lastError = null;
      _lastExecutionResult = '';
      _lastExecutionMode = mode;
      _notifyListeners();
      return const JsValue.string('');
    }

    await initialize();

    _isExecuting = true;
    _lastError = null;
    _lastExecutionResult = null;
    _lastExecutionMode = mode;
    _notifyListeners();

    try {
      final result = mode == JsExecutionMode.module
          ? await _executeModuleIsolated(code)
          : await _executeAsScript(code);

      _lastExecutionResult = _formatValue(result.value);
      return result;
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    } finally {
      _isExecuting = false;
      _notifyListeners();
    }
  }

  /// Execute in Script mode
  Future<JsValue> _executeAsScript(String code) async {
    final engine = await _sharedEngine();
    return engine.eval(source: JsCode.code(code));
  }

  /// Execute in Module mode using an isolated session so repeated executions
  /// do not permanently pollute the shared module cache.
  Future<JsValue> _executeModuleIsolated(String code) async {
    final session = await _createSession();

    try {
      // Generate unique module name
      final moduleName = '_module_${DateTime.now().microsecondsSinceEpoch}';

      await session.engine.evaluateModule(
        module: JsModule.code(module: moduleName, code: code),
      );

      // If the module exports default, return it. Otherwise return the namespace.
      final importCode =
          '''
(async () => {
  const module = await import('$moduleName');
  return module.default !== undefined ? module.default : module;
})()
    ''';

      return await session.engine.eval(source: JsCode.code(importCode));
    } finally {
      await session.dispose();
    }
  }

  // ========== Module Management ==========

  /// Declare a new module without executing it
  ///
  /// The module will be available for import in subsequent evaluations.
  Future<Map<String, dynamic>> declareModule({
    required String moduleName,
    required String code,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final engine = await _sharedEngine();
      await engine.declareNewModule(
        module: JsModule.code(module: moduleName, code: code),
      );
      return {'success': true, 'moduleName': moduleName, 'action': 'declared'};
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'action': 'declare_module',
      };
    }
  }

  /// Evaluate a module (declare and execute it)
  ///
  /// Unlike declareModule, this also executes the module's top-level code
  /// and returns its result.
  Future<Map<String, dynamic>> evaluateModuleWrapper({
    required String moduleName,
    required String code,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final engine = await _sharedEngine();
      final result = await engine.evaluateModule(
        module: JsModule.code(module: moduleName, code: code),
      );
      return {
        'success': true,
        'moduleName': moduleName,
        'action': 'evaluated',
        'result': result.value,
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'action': 'evaluate_module',
      };
    }
  }

  /// Declare multiple modules at once
  Future<Map<String, dynamic>> declareMultipleModules({
    required List<Map<String, String>> modules,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final jsModules = modules
          .map((m) => JsModule.code(module: m['name']!, code: m['code']!))
          .toList();

      final engine = await _sharedEngine();
      await engine.declareNewModules(modules: jsModules);
      return {
        'success': true,
        'count': modules.length,
        'action': 'declared_multiple',
        'modules': modules.map((m) => m['name']).toList(),
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'action': 'declare_multiple_modules',
      };
    }
  }

  /// Clear pending dynamic module registrations that have not been loaded yet
  Future<Map<String, dynamic>> clearPendingModules() async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final engine = await _sharedEngine();
      await engine.clearPendingModules();
      return {'success': true, 'action': 'cleared_pending_modules'};
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'action': 'clear_pending_modules',
      };
    }
  }

  /// Get all declared module names
  Future<Map<String, dynamic>> getDeclaredModules() async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final engine = await _sharedEngine();
      final modules = await engine.getDeclaredModules();
      return {
        'success': true,
        'action': 'get_declared_modules',
        'modules': modules,
        'count': modules.length,
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'action': 'get_declared_modules',
      };
    }
  }

  /// Check if a module is declared
  Future<Map<String, dynamic>> isModuleDeclared({
    required String moduleName,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final engine = await _sharedEngine();
      final isDeclared = await engine.isModuleDeclared(moduleName: moduleName);
      return {
        'success': true,
        'action': 'is_module_declared',
        'moduleName': moduleName,
        'isDeclared': isDeclared,
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'action': 'is_module_declared',
      };
    }
  }

  /// Run comprehensive module test suite
  ///
  /// This method runs a series of tests to demonstrate module functionality.
  /// Returns a list of test results with success/failure status.
  Future<List<Map<String, dynamic>>> runTestSuite() async {
    final results = <Map<String, dynamic>>[];

    // Test 1: Declare a simple module
    results.add(
      await declareModule(
        moduleName: 'math-utils',
        code: '''
        export function add(a, b) {
          return a + b;
        }
        export function multiply(a, b) {
          return a * b;
        }
        export const PI = 3.14159;
      ''',
      ),
    );

    // Test 2: Check if module is declared
    results.add(await isModuleDeclared(moduleName: 'math-utils'));

    // Test 3: Get all declared modules
    results.add(await getDeclaredModules());

    // Test 4: Declare multiple modules
    results.add(
      await declareMultipleModules(
        modules: [
          {
            'name': 'string-utils',
            'code': '''
          export function reverse(str) {
            return str.split('').reverse().join('');
          }
          export function capitalize(str) {
            return str.charAt(0).toUpperCase() + str.slice(1);
          }
        ''',
          },
          {
            'name': 'array-utils',
            'code': '''
          export function sum(arr) {
            return arr.reduce((a, b) => a + b, 0);
          }
          export function unique(arr) {
            return [...new Set(arr)];
          }
        ''',
          },
        ],
      ),
    );

    // Test 5: Module dependencies - use modules in another module
    results.add(
      await evaluateModuleWrapper(
        moduleName: 'calculator-test',
        code: '''
        import { add, multiply } from 'math-utils';

        export default {
          sum: add(5, 3),
          product: multiply(4, 7),
        };
      ''',
      ),
    );

    // Test 6: Named exports
    results.add(
      await evaluateModuleWrapper(
        moduleName: 'date-utils',
        code: '''
        export function getCurrentDate() {
          return new Date().toISOString().split('T')[0];
        }
        export function formatTimestamp(date) {
          return date.toISOString();
        }
        export default {
          description: 'Date utility module',
          createdAt: new Date().toISOString(),
        };
      ''',
      ),
    );

    // Test 7: Dynamic import in module
    results.add(
      await evaluateModuleWrapper(
        moduleName: 'dynamic-test',
        code: '''
        export async function getMathUtils() {
          const utils = await import('math-utils');
          return {
            add: utils.add,
            multiply: utils.multiply,
            PI: utils.PI,
          };
        }
        export default {
          description: 'Module with dynamic imports',
          createdAt: new Date().toISOString(),
        };
      ''',
      ),
    );

    // Test 8: Clear modules
    results.add(await clearPendingModules());

    return results;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _isInitialized = false;
    _isExecuting = false;

    final session = _sharedSession;
    _sharedSession = null;
    _engine = null;
    _initializing = null;

    if (session != null) {
      unawaited(session.dispose());
    }

    super.dispose();
  }

  Future<_FjsModuleAssets> _loadModuleAssets() async {
    final bundles = await Future.wait([
      rootBundle.load('assets/examples/linkedom.bundle.mjs'),
      rootBundle.load('assets/examples/canvas.bundle.mjs'),
    ]);

    return _FjsModuleAssets(
      linkedomBundle: bundles[0].buffer.asUint8List(
        bundles[0].offsetInBytes,
        bundles[0].lengthInBytes,
      ),
      canvasBundle: bundles[1].buffer.asUint8List(
        bundles[1].offsetInBytes,
        bundles[1].lengthInBytes,
      ),
    );
  }

  Future<_FjsSession> _createSession() async {
    final assets = _moduleAssets ??= await _loadModuleAssets();
    final engine = await JsEngine.create(
      builtins: _builtinOptions,
      modules: assets.additionalModules(),
    );
    await engine.initWithoutBridge();
    return _FjsSession(engine: engine);
  }

  Future<JsEngine> _sharedEngine() async {
    await initialize();
    final engine = _engine;
    if (engine == null) {
      throw StateError('FJS engine is not initialized');
    }
    return engine;
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('FjsService has been disposed');
    }
  }

  void _notifyListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  String _formatValue(dynamic value) {
    if (value == null || value is String) {
      return value?.toString() ?? 'null';
    }

    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }
}

final class _FjsSession {
  final JsEngine engine;

  const _FjsSession({required this.engine});

  Future<void> dispose() => engine.close();
}

final class _FjsModuleAssets {
  final Uint8List linkedomBundle;
  final Uint8List canvasBundle;

  const _FjsModuleAssets({
    required this.linkedomBundle,
    required this.canvasBundle,
  });

  List<JsModule> additionalModules() {
    return [
      JsModule(name: 'canvas', source: JsCode.bytes(canvasBundle)),
      JsModule(name: 'linkedom', source: JsCode.bytes(linkedomBundle)),
    ];
  }
}
