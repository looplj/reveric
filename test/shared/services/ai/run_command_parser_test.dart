// 职责: 验证 Run 命令 UI 解析 — 子命令未就绪时应 loading，角色与物品图片命令应映射专用工具卡。
// 关联文件:
//   lib/shared/services/ai/run_command_parser.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/ai/run_command_parser.dart';
import 'package:reveric/shared/models/ai_message_block.dart';

void main() {
  group('resolveRunCommandUi', () {
    test('empty command stays pending', () {
      expect(resolveRunCommandUi({}).phase, RunCommandUiPhase.pending);
    });

    test('character without subcommand awaits subcommand', () {
      final resolution = resolveRunCommandUi({'command': 'character'});
      expect(resolution.phase, RunCommandUiPhase.awaitingSubcommand);
      expect(resolution.imageToolName, isNull);
    });

    test('debug waits for the log subcommand', () {
      expect(
        resolveRunCommandUi({'command': 'debug'}).phase,
        RunCommandUiPhase.awaitingSubcommand,
      );
      expect(
        resolveRunCommandUi({'command': 'debug', 'subcommand': 'log'}).phase,
        RunCommandUiPhase.ready,
      );
    });

    test('character generate-avatar resolves to GenerateAvatar', () {
      final resolution = resolveRunCommandUi({
        'command': 'character',
        'subcommand': 'generate-avatar',
        'options': {'character': 'c_1', 'prompt': 'stern mage'},
      });
      expect(resolution.phase, RunCommandUiPhase.ready);
      expect(resolution.imageToolName, 'GenerateAvatar');
      expect(resolution.parsed?.option('character'), 'c_1');
    });

    test('character generate-photo resolves to GeneratePhoto', () {
      final resolution = resolveRunCommandUi({
        'command': 'character',
        'subcommand': 'generate-photo',
        'options': {'character': 'c_1', 'prompt': 'full body'},
      });
      expect(resolution.phase, RunCommandUiPhase.ready);
      expect(resolution.imageToolName, 'GeneratePhoto');
      expect(resolution.parsed?.option('character'), 'c_1');
    });

    test('item generate-photo resolves to GeneratePhoto with item id', () {
      final resolution = resolveRunCommandUi({
        'command': 'item',
        'subcommand': 'generate-photo',
        'options': {'item': 'item_1', 'prompt': 'ancient sword'},
      });
      expect(resolution.phase, RunCommandUiPhase.ready);
      expect(resolution.imageToolName, 'GeneratePhoto');
      expect(resolution.parsed?.option('item'), 'item_1');
    });

    test('sessions streams from namespace to a ready action', () {
      expect(
        resolveRunCommandUi({'command': 'sessions'}).phase,
        RunCommandUiPhase.awaitingSubcommand,
      );
      for (final action in ['list', 'read', 'search', 'get']) {
        expect(
          resolveRunCommandUi({
            'command': 'sessions',
            'subcommand': action,
          }).phase,
          RunCommandUiPhase.ready,
        );
      }
      expect(
        resolveRunCommandUi({'command': 'history'}).phase,
        RunCommandUiPhase.ready,
      );
    });

    test('agent-rules without subcommand awaits subcommand', () {
      expect(
        resolveRunCommandUi({'command': 'agent-rules'}).phase,
        RunCommandUiPhase.awaitingSubcommand,
      );
    });

    test('agent-rules list is ready', () {
      expect(
        resolveRunCommandUi({
          'command': 'agent-rules',
          'subcommand': 'list',
        }).phase,
        RunCommandUiPhase.ready,
      );
    });

    test('agent-rules read is ready', () {
      expect(
        resolveRunCommandUi({
          'command': 'agent-rules',
          'subcommand': 'read',
          'options': {'name': '章节字数'},
        }).phase,
        RunCommandUiPhase.ready,
      );
    });
  });

  group('isRunToolCallReadyForDisplay', () {
    test('Run block with partial image command is not ready', () {
      const block = AiToolCallBlock(
        id: 'b1',
        callId: 'c1',
        toolName: 'Run',
        arguments: {'command': 'character'},
      );
      expect(isRunToolCallReadyForDisplay(block), isFalse);
    });

    test('settled Run without command text is ready for display', () {
      const block = AiToolCallBlock(
        id: 'b2',
        callId: 'c2',
        toolName: 'Run',
        arguments: {},
        status: AiToolCallStatus.success,
        result: {'ok': true, 'entries': []},
      );
      expect(isRunToolCallReadyForDisplay(block), isTrue);
    });
  });
}
