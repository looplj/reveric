// 职责: 系统托盘退出回归测试 — 确保关闭流程不被原生窗口回包阻塞。
// 关联文件:
//   lib/shared/services/system_tray_service.dart

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/system_tray_service.dart';
import 'package:reveric/shared/logger/startup_failure_reporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowManagerChannel = MethodChannel('window_manager');
  const exitChannel = MethodChannel('reveric/process_exit');
  final calls = <String>[];
  Completer<Object?>? pendingWindowClose;
  var windowVisible = true;
  var windowMinimized = false;
  Completer<Object?>? pendingArm;
  var failArm = false;
  Completer<Object?>? pendingFocus;

  setUp(() {
    calls.clear();
    pendingWindowClose = null;
    windowVisible = true;
    windowMinimized = false;
    pendingArm = null;
    failArm = false;
    pendingFocus = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(exitChannel, (call) async {
          calls.add('process.${call.method}');
          if (failArm) {
            throw PlatformException(code: 'exit_watchdog_failed');
          }
          if (pendingArm != null) {
            return pendingArm!.future;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, (call) async {
          calls.add('window.${call.method}');
          if (call.method == 'isVisible') {
            return windowVisible;
          }
          if (call.method == 'isMinimized') {
            return windowMinimized;
          }
          if (call.method == 'focus' && pendingFocus != null) {
            return pendingFocus!.future;
          }
          if (call.method == 'close' && pendingWindowClose != null) {
            return pendingWindowClose!.future;
          }
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(exitChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, null);
  });

  test('tray quit cannot be vetoed by an exit guard', () async {
    final unregister = SystemTrayService().registerExitGuard(() async => false);
    await SystemTrayService().exitApplicationForTesting(
      (code) => calls.add('exit.$code'),
    );
    unregister();
    expect(calls, contains('exit.1'));
    await SystemTrayService().exitApplicationForTesting(
      (code) => calls.add('exit.$code'),
    );
    expect(calls, contains('exit.0'));
  });

  test('tray exit closes the window without invoking destroy', () async {
    await SystemTrayService().exitApplicationForTesting(
      (code) => calls.add('exit.$code'),
    );

    expect(calls, <String>[
      'process.arm',
      'window.setPreventClose',
      'window.close',
      'exit.0',
    ]);
    expect(calls, isNot(contains('window.destroy')));
  });

  test('activation waits for the native window to become visible', () async {
    windowVisible = false;
    final restore = Timer(const Duration(milliseconds: 80), () {
      windowVisible = true;
    });
    try {
      await SystemTrayService().showMainWindow();
      expect(windowVisible, isTrue);
    } finally {
      restore.cancel();
    }
  });

  test(
    'activation waits for minimization to clear and shares concurrent work',
    () async {
      windowMinimized = true;
      final restore = Timer(const Duration(milliseconds: 80), () {
        windowMinimized = false;
      });
      try {
        final service = SystemTrayService();
        final first = service.showMainWindow();
        final second = service.showMainWindow();
        expect(identical(first, second), isTrue);
        await Future.wait([first, second]);
        expect(calls.where((call) => call == 'window.show'), hasLength(1));
      } finally {
        restore.cancel();
      }
    },
  );

  test('a stuck native focus cannot outlive the activation deadline', () async {
    pendingFocus = Completer<Object?>();
    await expectLater(
      SystemTrayService().showMainWindow().timeout(const Duration(seconds: 2)),
      throwsStateError,
    );
    pendingFocus!.complete();
    pendingFocus = null;
    await SystemTrayService().showMainWindow();
  });

  test(
    'hidden window and stuck cleanup still exit within the deadline',
    () async {
      windowVisible = false;
      final hanging = Completer<bool>();
      final unregister = SystemTrayService().registerExitGuard(
        () => hanging.future,
      );
      var cleaned = false;
      try {
        await SystemTrayService()
            .exitApplicationForTesting(
              (code) => calls.add('exit.$code'),
              cleanExit: () async {
                cleaned = true;
              },
              closeContentDatabases: () async => calls.add('content.close'),
              closeAppDatabase: () async => calls.add('app.close'),
              unlock: () => calls.add('instance.unlock'),
              timeout: const Duration(milliseconds: 50),
            )
            .timeout(const Duration(seconds: 1));
        expect(calls.first, 'process.arm');
        expect(calls, contains('exit.1'));
        expect(calls, isNot(contains('window.show')));
        expect(cleaned, isFalse);
        expect(
          calls,
          containsAllInOrder([
            'content.close',
            'app.close',
            'instance.unlock',
            'exit.1',
          ]),
        );
      } finally {
        unregister();
        hanging.complete(true);
      }
    },
  );

  test('throwing cleanup cannot veto exit or skip other cleanup', () async {
    var saved = false;
    final unregisterSave = SystemTrayService().registerExitGuard(() async {
      saved = true;
      return true;
    });
    final unregisterFailure = SystemTrayService().registerExitGuard(() async {
      throw StateError('save failed');
    });
    try {
      await SystemTrayService().exitApplicationForTesting(
        (code) => calls.add('exit.$code'),
        cleanExit: () async => calls.add('marker.clean'),
      );
      expect(saved, isTrue);
      expect(calls, contains('exit.1'));
      expect(calls, isNot(contains('marker.clean')));
    } finally {
      unregisterSave();
      unregisterFailure();
    }
  });

  test('missing native acknowledgement cannot strand Dart shutdown', () async {
    pendingArm = Completer<Object?>();
    await SystemTrayService()
        .exitApplicationForTesting(
          (code) => calls.add('exit.$code'),
          timeout: const Duration(milliseconds: 100),
          closeContentDatabases: () async => calls.add('content.close'),
          closeAppDatabase: () async => calls.add('app.close'),
          unlock: () => calls.add('instance.unlock'),
        )
        .timeout(const Duration(seconds: 1));
    expect(calls, contains('exit.1'));
    expect(
      calls,
      containsAllInOrder([
        'content.close',
        'app.close',
        'instance.unlock',
        'exit.1',
      ]),
    );
    pendingArm!.complete();
  });

  test(
    'native watchdog failure still saves, closes databases and unlocks',
    () async {
      failArm = true;
      final unregister = SystemTrayService().registerExitGuard(() async {
        calls.add('saved');
        return true;
      });
      try {
        await SystemTrayService().exitApplicationForTesting(
          (code) => calls.add('exit.$code'),
          closeContentDatabases: () async => calls.add('content.close'),
          closeAppDatabase: () async => calls.add('app.close'),
          cleanExit: () async => calls.add('marker.clean'),
          unlock: () => calls.add('instance.unlock'),
        );
        expect(
          calls,
          containsAllInOrder([
            'process.arm',
            'saved',
            'content.close',
            'app.close',
            'marker.clean',
            'instance.unlock',
            'exit.1',
          ]),
        );
      } finally {
        unregister();
      }
    },
  );

  test(
    'stuck content database does not skip app database and unlock',
    () async {
      final stuck = Completer<void>();
      await SystemTrayService().exitApplicationForTesting(
        (code) => calls.add('exit.$code'),
        timeout: const Duration(milliseconds: 200),
        closeContentDatabases: () {
          calls.add('content.close');
          return stuck.future;
        },
        closeAppDatabase: () async => calls.add('app.close'),
        cleanExit: () async => calls.add('marker.clean'),
        unlock: () => calls.add('instance.unlock'),
      );
      expect(
        calls,
        containsAllInOrder([
          'content.close',
          'app.close',
          'instance.unlock',
          'exit.1',
        ]),
      );
      expect(calls, isNot(contains('marker.clean')));
      stuck.complete();
    },
  );

  test(
    'exit awaits consent and HTTP completion of the failure report',
    () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        calls.add('http.completed');
        return http.Response('', 204);
      });
      final reporter = StartupFailureReporter(
        httpClient: client,
        getDeviceId: () async => 'test-device',
        getBaseUrl: () => 'https://example.invalid',
        getEnabled: () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          calls.add('consent.ready');
          return true;
        },
      );
      try {
        await SystemTrayService().exitApplicationForTesting(
          (code) => calls.add('exit.$code'),
          unlock: () => throw StateError('unlock failed'),
          failureReporter: reporter,
        );
        expect(
          calls,
          containsAllInOrder(['consent.ready', 'http.completed', 'exit.1']),
        );
      } finally {
        client.close();
      }
    },
  );

  test(
    'stuck unlock and report each time out without preventing exit',
    () async {
      final unlock = Completer<void>();
      final report = Completer<void>();
      await SystemTrayService()
          .exitApplicationForTesting(
            (code) => calls.add('exit.$code'),
            timeout: const Duration(milliseconds: 200),
            unlock: () => unlock.future,
            failureReporter: _HangingReporter(calls, report.future),
          )
          .timeout(const Duration(seconds: 1));
      expect(calls, containsAllInOrder(['report.started', 'exit.1']));
      unlock.complete();
      report.complete();
    },
  );

  test(
    'repeated quit shares cleanup and never resets the native deadline',
    () async {
      final cleanup = Completer<bool>();
      final unregister = SystemTrayService().registerExitGuard(
        () => cleanup.future,
      );
      try {
        final service = SystemTrayService();
        final first = service.exitApplicationForTesting(
          (code) => calls.add('exit.$code'),
        );
        final second = service.exitApplicationForTesting(
          (code) => calls.add('exit.$code'),
        );
        cleanup.complete(true);
        await Future.wait([first, second]);
        expect(calls.where((call) => call == 'process.arm'), hasLength(1));
        expect(calls.where((call) => call.startsWith('exit.')), hasLength(1));
      } finally {
        unregister();
      }
    },
  );

  test('exit disposes the native tray before closing the window', () async {
    final service = SystemTrayService.forTesting(
      _TrayIcon(() => calls.add('tray.dispose')),
    );
    await service.exitApplicationForTesting((code) => calls.add('exit.$code'));
    expect(calls, [
      'process.arm',
      'window.setPreventClose',
      'tray.dispose',
      'window.close',
      'exit.0',
    ]);
  });

  test('native tray disposal failure does not prevent termination', () async {
    final service = SystemTrayService.forTesting(
      _TrayIcon(() => throw StateError('native disposal failed')),
    );
    await service.exitApplicationForTesting((code) => calls.add('exit.$code'));
    expect(calls, containsAllInOrder(['window.close', 'exit.0']));
  });

  test('window activation must verify the native visibility result', () async {
    windowVisible = false;
    await expectLater(SystemTrayService().showMainWindow(), throwsStateError);
    expect(
      calls,
      containsAllInOrder(['window.show', 'window.focus', 'window.isVisible']),
    );
  });

  test(
    'failed instance cleanup is reported without stranding tray exit',
    () async {
      await SystemTrayService().exitApplicationForTesting(
        (code) => calls.add('exit.$code'),
        unlock: () => throw StateError('cleanup failed'),
        failureReporter: _Reporter(calls),
      );
      expect(
        calls,
        containsAllInOrder([
          'report:tray_exit:release_instance_failed',
          'report.completed',
          'exit.1',
        ]),
      );
    },
  );

  test('tray exit does not wait for the native close reply', () async {
    pendingWindowClose = Completer<Object?>();

    await SystemTrayService()
        .exitApplicationForTesting((code) => calls.add('exit.$code'))
        .timeout(const Duration(milliseconds: 100));

    expect(calls, <String>[
      'process.arm',
      'window.setPreventClose',
      'window.close',
      'exit.0',
    ]);
  });

  test(
    'tray exit removes the marker before releasing the instance lock',
    () async {
      await SystemTrayService().exitApplicationForTesting(
        (code) => calls.add('exit.$code'),
        cleanExit: () async => calls.add('marker.clean'),
        unlock: () => calls.add('instance.unlock'),
      );

      expect(
        calls.indexOf('marker.clean'),
        lessThan(calls.indexOf('instance.unlock')),
      );
    },
  );
}

class _Reporter extends StartupFailureReporter {
  _Reporter(this.calls);
  final List<String> calls;

  @override
  Future<void> reportLifecycleFailure({
    required String phase,
    required String reason,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    calls.add('report:$phase:$reason');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    calls.add('report.completed');
  }
}

class _HangingReporter extends StartupFailureReporter {
  _HangingReporter(this.calls, this.completion);
  final List<String> calls;
  final Future<void> completion;

  @override
  Future<void> reportLifecycleFailure({
    required String phase,
    required String reason,
    required Object error,
    required StackTrace stackTrace,
  }) {
    calls.add('report.started');
    return completion;
  }
}

class _TrayIcon implements tray.TrayIcon {
  _TrayIcon(this.onDispose);

  final void Function() onDispose;

  @override
  void dispose() => onDispose();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
