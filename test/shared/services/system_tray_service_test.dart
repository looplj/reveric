// 职责: 系统托盘退出回归测试 — 确保关闭流程不被原生窗口回包阻塞。
// 关联文件:
//   lib/shared/services/system_tray_service.dart

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:reveric/shared/services/system_tray_service.dart';
import 'package:reveric/shared/logger/startup_failure_reporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowManagerChannel = MethodChannel('window_manager');
  final calls = <String>[];
  Completer<Object?>? pendingWindowClose;
  var windowVisible = true;

  setUp(() {
    calls.clear();
    pendingWindowClose = null;
    windowVisible = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, (call) async {
          calls.add('window.${call.method}');
          if (call.method == 'isVisible') {
            return windowVisible;
          }
          if (call.method == 'isMinimized') {
            return false;
          }
          if (call.method == 'close' && pendingWindowClose != null) {
            return pendingWindowClose!.future;
          }
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, null);
  });

  test('exit guard cancels shutdown until its owner unregisters', () async {
    final unregister = SystemTrayService().registerExitGuard(() async => false);
    await SystemTrayService().exitApplicationForTesting(
      (code) => calls.add('exit.$code'),
    );
    expect(calls, isEmpty);
    unregister();
    await SystemTrayService().exitApplicationForTesting(
      (code) => calls.add('exit.$code'),
    );
    expect(calls, contains('exit.0'));
  });

  test('tray exit closes the window without invoking destroy', () async {
    await SystemTrayService().exitApplicationForTesting(
      (code) => calls.add('exit.$code'),
    );

    expect(calls, <String>['window.setPreventClose', 'window.close', 'exit.0']);
    expect(calls, isNot(contains('window.destroy')));
  });

  test('exit disposes the native tray before closing the window', () async {
    final service = SystemTrayService.forTesting(
      _TrayIcon(() => calls.add('tray.dispose')),
    );
    await service.exitApplicationForTesting((code) => calls.add('exit.$code'));
    expect(calls, [
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
          'exit.0',
        ]),
      );
    },
  );

  test('tray exit does not wait for the native close reply', () async {
    pendingWindowClose = Completer<Object?>();

    await SystemTrayService()
        .exitApplicationForTesting((code) => calls.add('exit.$code'))
        .timeout(const Duration(milliseconds: 100));

    expect(calls, <String>['window.setPreventClose', 'window.close', 'exit.0']);
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
