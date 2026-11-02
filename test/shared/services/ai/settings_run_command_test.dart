// 职责: 验证设置命令异步返回、不创建后台任务、重复打开与参数边界。
// 关联文件:
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/providers/settings_navigation.dart
//   lib/shared/services/ai/tool_operations.dart
import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/providers/settings_navigation.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late NovelContentDatabase contentDb;
  late AppDatabase appDb;
  late AiToolManager tools;
  late ToolOperationManager operations;
  late ToolOperationRegistry registry;
  late SettingsNavigation navigation;
  late Completer<void> result;
  var opens = 0;
  var calls = 0;
  final context = ToolExecutionContext(
    sessionId: 'owner',
    sourceTurnId: 'turn',
  );
  setUp(() {
    contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    final content = NovelContentService(contentDb);
    registry = ToolOperationRegistry();
    operations = ToolOperationManager(
      ownerSessionId: 'owner',
      registry: registry,
      gate: () => throw StateError('Opening settings needs no approval'),
      onChanged: (_) {},
      onRecord: (_) {},
    );
    result = Completer<void>();
    opens = calls = 0;
    navigation = SettingsNavigation()
      ..openSection = (section) {
        opens++;
        return result.future;
      };
    tools = AiToolManager(
      content,
      workingOverlayService: WorkingOverlayService(
        contentDb,
        content,
        novelActionsService: NovelActionsService(appDb),
      ),
      operationHost: ToolOperationHost(
        operations,
        media: false,
        openSettings: navigation.open,
      ),
    )..registerAllTools();
  });
  tearDown(() async {
    if (!result.isCompleted) {
      result.complete();
    }
    await Future<void>.delayed(Duration.zero);
    tools.dispose();
    operations.dispose();
    registry.dispose();
    await contentDb.close();
    await appDb.close();
  });
  Future<Map<String, dynamic>> open([
    Map<String, dynamic> options = const {'section': 'storage'},
  ]) => tools.executeTool(
    name: 'Run',
    callId: 'call-${++calls}',
    context: context,
    input: {'command': 'settings', 'subcommand': 'open', 'options': options},
  );

  test(
    'opens immediately without waiting or creating a background operation',
    () async {
      final response = await open().timeout(const Duration(seconds: 2));
      expect(response, {'ok': true});
      expect(opens, 1);
      expect(result.isCompleted, false);
      expect(operations.state.runs, isEmpty);
      result.complete();
      await Future<void>.delayed(Duration.zero);
      expect(operations.state.pending, isEmpty);
    },
  );
  test('repeated opens reuse the page until it closes', () async {
    await open();
    await open();
    expect(opens, 1);
    result.complete();
    await Future<void>.delayed(Duration.zero);
    result = Completer<void>();
    await open();
    expect(opens, 2);
    expect(operations.state.runs, isEmpty);
    expect(
      (await open({'section': 'providers'}))['error_code'],
      'settings_already_open',
    );
    result.complete();
    await Future<void>.delayed(Duration.zero);
    result = Completer<void>();
    expect((await open({'section': 'providers'}))['ok'], true);
    expect(opens, 3);
  });
  test(
    'rejects unknown sections and credential fields without opening UI',
    () async {
      for (final options in [
        <String, dynamic>{},
        {'section': 'debug'},
        {'section': ''},
        {'section': 12},
        {'section': 'storage', 'secret': 'private'},
      ]) {
        expect((await open(options))['ok'], false);
      }
      expect(opens, 0);
      expect(operations.state.runs, isEmpty);
    },
  );
  test('missing UI reports an error without creating an operation', () async {
    navigation.openSection = null;
    expect((await open())['error_code'], 'unavailable');
    expect(opens, 0);
    expect(operations.state.runs, isEmpty);
  });
}
