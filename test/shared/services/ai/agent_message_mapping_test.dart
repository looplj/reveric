// 职责: 测试 AI 聊天消息恢复 — 跨模型降级的推理文本与旧 tool_call 终态均能进入模型历史。
// 关联文件:
//   lib/shared/services/ai/agent_message_mapping.dart
//   lib/shared/services/ai/tool_result_payloads.dart
//   lib/shared/models/ai_chat_models.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/client.dart'
    show toolCallIncompleteErrorCode;
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/services/ai/agent_message_mapping.dart';
import 'package:reveric/shared/services/ai/context_message_matcher.dart';
import 'package:reveric/shared/services/ai/tool_result_payloads.dart';

void main() {
  test('operation control receipts retain their own call lifecycle', () {
    for (final subcommand in ['wait', 'read', 'cancel']) {
      for (final taskStatus in ['queued', 'running', 'cancelling']) {
        final block = AiToolCallBlock(
          id: 'control',
          callId: 'call-control',
          toolName: 'Run',
          arguments: {
            'command': 'operations',
            'subcommand': subcommand,
            'options': {'run_id': 'run-image'},
          },
          status: AiToolCallStatus.success,
          result: {
            'ok': true,
            'run_id': 'run-image',
            'status': taskStatus,
            if (subcommand == 'wait') 'timed_out': true,
          },
        );
        final display = aiToolOperationDisplayBlock(block);
        expect(display.status, AiToolCallStatus.success);
        expect(display.result, block.result);
        expect(
          aiToolOperationDisplayBlock(
            block.copyWith(status: AiToolCallStatus.cancelled),
          ).status,
          AiToolCallStatus.cancelled,
        );
        expect(
          aiToolOperationDisplayBlock(
            block.copyWith(status: AiToolCallStatus.running),
          ).status,
          AiToolCallStatus.running,
        );
      }
    }
  });

  test('background submission receipts still follow the task lifecycle', () {
    final block = AiToolCallBlock(
      id: 'submit',
      callId: 'call-submit',
      toolName: 'Run',
      arguments: const {'command': 'canvas', 'subcommand': 'generate'},
      status: AiToolCallStatus.success,
      result: const {'ok': true, 'run_id': 'run-image', 'status': 'running'},
    );
    expect(aiToolOperationDisplayBlock(block).status, AiToolCallStatus.running);
  });

  test(
    'operation state supersedes a successful submission in UI and history',
    () {
      for (final entry in {
        'queued': AiToolCallStatus.pending,
        'running': AiToolCallStatus.running,
        'completed': AiToolCallStatus.success,
        'failed': AiToolCallStatus.error,
        'cancelled': AiToolCallStatus.cancelled,
        'interrupted': AiToolCallStatus.error,
      }.entries) {
        final failed = {
          'failed',
          'cancelled',
          'interrupted',
        }.contains(entry.key);
        final block = AiToolCallBlock(
          id: 'export',
          callId: 'call-export',
          toolName: 'Run',
          arguments: const {'command': 'editing', 'subcommand': 'export'},
          status: AiToolCallStatus.success,
          result: const {
            'ok': true,
            'run_id': 'run-export',
            'status': 'queued',
          },
          metadata: {
            'operations': [
              {
                'run_id': 'run-export',
                'call_id': 'call-export',
                'status': entry.key,
                if (failed)
                  'result': {
                    'ok': false,
                    'error_code': 'encoding_failed',
                    'error': 'Encoding failed.',
                  },
                if (entry.key == 'completed')
                  'result': {
                    'ok': true,
                    'files': ['video.mp4'],
                  },
              },
            ],
          },
        );
        final display = aiToolOperationDisplayBlock(block);
        expect(display.status, entry.value, reason: entry.key);
        expect(block.status, AiToolCallStatus.success);
        final restored = convertAiMessageToAgentMessagesForModel(
          AiMessage.assistant(id: 'message', content: '', blocks: [block]),
        ).expand((m) => m.blocks).whereType<ToolResultBlock>().single;
        expect(restored.isError, failed, reason: entry.key);
        final payload =
            jsonDecode((restored.content.single as TextBlock).text) as Map;
        expect(
          payload['status'],
          entry.key == 'running' ? 'queued' : entry.key,
        );
        if (failed) {
          expect(payload['error_code'], 'encoding_failed');
        }
        if (!aiToolCallStatusIsActive(entry.value)) {
          final interruptedReceipt = convertAiMessageToAgentMessagesForModel(
            AiMessage.assistant(
              id: 'message',
              content: '',
              blocks: [block.copyWith(status: AiToolCallStatus.running)],
            ),
          ).expand((m) => m.blocks).whereType<ToolResultBlock>().single;
          expect(interruptedReceipt.isError, failed);
        }
      }
    },
  );

  test('nested operation snapshots do not replace the parent tool result', () {
    final block = AiToolCallBlock(
      id: 'parent',
      callId: 'parent',
      toolName: 'Code',
      arguments: const {},
      status: AiToolCallStatus.success,
      result: const {'ok': true},
      metadata: {
        'operations': [
          {'call_id': 'nested', 'status': 'failed'},
        ],
      },
    );
    expect(aiToolOperationDisplayBlock(block), same(block));
    final subagent = block.copyWith(
      toolName: 'SpawnAgent',
      result: {'run_id': 'subagent-run', 'status': 'running'},
    );
    expect(aiToolOperationDisplayBlock(subagent), same(subagent));
  });
  test(
    'restored history classifies top-level protocol and preserves business data',
    () {
      for (final scenario in <(Map<String, dynamic>, bool)>[
        ({'updated': false}, false),
        (
          {
            'value': {'ok': false, 'error': 'body'},
          },
          false,
        ),
        ({'ok': true, 'error': 'failed'}, true),
        ({'cancelled': true}, true),
        ({'skipped': true}, true),
      ]) {
        final restored = convertAiMessageToAgentMessagesForModel(
          AiMessage.assistant(
            id: 'a',
            content: '',
            blocks: [
              AiToolCallBlock(
                id: 'b',
                callId: 'c',
                toolName: 'Write',
                arguments: const {'path': 'chapters/id/title'},
                status: AiToolCallStatus.success,
                result: scenario.$1,
              ),
            ],
          ),
        );
        final block = restored
            .expand((message) => message.blocks)
            .whereType<ToolResultBlock>()
            .single;
        expect(block.isError, scenario.$2);
        final payload =
            jsonDecode((block.content.single as TextBlock).text) as Map;
        expect(payload['ok'], !scenario.$2);
        if (scenario.$1.containsKey('value')) {
          expect(payload['value'], scenario.$1['value']);
        }
      }
    },
  );

  group('messagesSinceLatestCompact', () {
    test('starts the replay window at the latest compaction summary', () {
      final messages = [
        AiMessage.user(id: 'old_user', content: 'old context'),
        AiMessage.user(
          id: 'compact_1',
          content: 'first summary',
          type: AiMessageType.compact_summary,
        ),
        AiMessage.assistant(id: 'old_answer', content: 'old answer'),
        AiMessage.user(
          id: 'compact_2',
          content: 'latest summary',
          type: AiMessageType.compact_summary,
        ),
        AiMessage.user(id: 'current_user', content: 'current request'),
      ];

      expect(
        messagesSinceLatestCompact(messages).map((message) => message.id),
        ['compact_2', 'current_user'],
      );
    });

    test(
      'starts the replay window when the latest summary is the first message',
      () {
        final messages = [
          AiMessage.user(
            id: 'compact_at_head',
            content: 'latest summary',
            type: AiMessageType.compact_summary,
          ),
          AiMessage.user(id: 'current_user', content: 'current request'),
        ];

        expect(
          messagesSinceLatestCompact(messages).map((message) => message.id),
          ['compact_at_head', 'current_user'],
        );
      },
    );

    test(
      'uses replay_from_message_id even if the summary was inserted too early',
      () {
        final messages = [
          AiMessage.user(
            id: 'ctx_summary_sess_1',
            content: '已完成：初始化引导',
            type: AiMessageType.compact_summary,
            metadata: buildCompactSummaryMetadata(
              compactionCount: 1,
              replayFromMessageId: 'continue_late',
            ),
          ),
          AiMessage.assistant(id: 'load_setup', content: '加载创作向导'),
          AiMessage.user(id: 'continue_early', content: '继续'),
          AiMessage.assistant(id: 'mid', content: '写到第 4 章'),
          AiMessage.user(id: 'continue_late', content: '继续'),
          AiMessage.assistant(id: 'recent', content: '写第 15 章'),
        ];

        expect(
          messagesSinceLatestCompact(messages).map((message) => message.id),
          ['ctx_summary_sess_1', 'continue_late', 'recent'],
        );
      },
    );

    test(
      'replays from the pointer when the summary sits where compaction happened',
      () {
        final messages = [
          AiMessage.user(id: 'overflow_user', content: 'old context'),
          AiMessage.assistant(id: 'overflow_answer', content: 'old answer'),
          AiMessage.user(id: 'current_user', content: 'current request'),
          AiMessage.assistant(id: 'step_before', content: 'step 1'),
          AiMessage.user(
            id: 'ctx_summary_sess_1',
            content: 'latest summary',
            type: AiMessageType.compact_summary,
            metadata: buildCompactSummaryMetadata(
              compactionCount: 1,
              replayFromMessageId: 'current_user',
            ),
          ),
          AiMessage.assistant(id: 'step_after', content: 'step 2'),
        ];

        expect(
          messagesSinceLatestCompact(messages).map((message) => message.id),
          ['ctx_summary_sess_1', 'current_user', 'step_before', 'step_after'],
        );
      },
    );

    test('falls back to the summary when the replay pointer is gone', () {
      final messages = [
        AiMessage.user(id: 'overflow_user', content: 'old context'),
        AiMessage.user(
          id: 'ctx_summary_sess_1',
          content: 'latest summary',
          type: AiMessageType.compact_summary,
          metadata: buildCompactSummaryMetadata(
            compactionCount: 1,
            replayFromMessageId: 'missing_user',
          ),
        ),
        AiMessage.user(id: 'current_user', content: 'current request'),
      ];

      expect(
        messagesSinceLatestCompact(messages).map((message) => message.id),
        ['ctx_summary_sess_1', 'current_user'],
      );
    });
  });

  group('restorePersistedChatContext', () {
    test(
      'restores the latest compaction snapshot without replaying its summary',
      () {
        final restored = restorePersistedChatContext([
          AiMessage.user(id: 'old_user', content: 'old context'),
          AiMessage.user(
            id: 'ctx_summary_session_1',
            content: 'first summary',
            type: AiMessageType.compact_summary,
            metadata: buildCompactSummaryMetadata(
              compactionCount: 1,
              replayFromMessageId: 'first_retained',
              tokensBefore: 100000,
              tokensAfter: 12000,
            ),
          ),
          AiMessage.user(id: 'first_retained', content: 'first retained'),
          AiMessage.assistant(id: 'old_answer', content: 'old answer'),
          AiMessage.user(
            id: 'ctx_summary_session_2',
            content: 'latest summary',
            type: AiMessageType.compact_summary,
            metadata: buildCompactSummaryMetadata(
              compactionCount: 2,
              replayFromMessageId: 'current_request',
              tokensBefore: 180000,
              tokensAfter: 48000,
            ),
          ),
          AiMessage.user(id: 'current_request', content: 'continue'),
          AiMessage.assistant(id: 'recent_answer', content: 'recent answer'),
        ]);

        expect(restored.summary, 'latest summary');
        expect(restored.compactionCount, 2);
        expect(restored.lastCompactionTokensBefore, 180000);
        expect(restored.lastCompactionTokensAfter, 48000);
        expect(restored.retainedMessages.map((message) => message.id), [
          'current_request',
          'recent_answer',
        ], reason: 'SmartAgentContextManager injects the summary itself.');
      },
    );
  });

  group('convertAiMessageToAgentMessagesForModel', () {
    group('SpawnAgent history', () {
      for (final scenario in <(String, Map<String, dynamic>, bool)>[
        (
          'background acknowledgement retains its running identity',
          {
            'ok': true,
            'status': 'running',
            'session_id': 'child_review',
            'run_id': 'run_review',
          },
          false,
        ),
        (
          'completed result retains its resumable session and output',
          {
            'ok': true,
            'output': 'Review complete.',
            'session_id': 'child_review',
          },
          false,
        ),
        (
          'failure retains its error and session',
          {
            'ok': false,
            'error': 'Review failed.',
            'error_code': 'sub_agent_error',
            'session_id': 'child_review',
          },
          true,
        ),
      ]) {
        test(scenario.$1, () {
          final originalResult = {
            ...scenario.$2,
            '_metadata': {'sub_agent_model': 'ui-model'},
          };
          final message = AiMessage.assistant(
            id: 'assistant_spawn',
            content: '',
            blocks: [
              AiToolCallBlock(
                id: 'block_spawn',
                callId: 'call_spawn',
                toolName: 'SpawnAgent',
                arguments: const {'agent': 'reviewer', 'task': 'Review'},
                status: scenario.$3
                    ? AiToolCallStatus.error
                    : AiToolCallStatus.success,
                result: originalResult,
                metadata: const {'sub_agent_model': 'ui-model'},
              ),
            ],
          );
          final restored = convertAiMessageToAgentMessagesForModel(
            AiMessage.fromJson(
              jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
            ),
          );
          final block = restored
              .expand((message) => message.blocks)
              .whereType<ToolResultBlock>()
              .single;
          expect(block.toolCallId, 'call_spawn');
          expect(block.isError, scenario.$3);
          expect(
            jsonDecode((block.content.single as TextBlock).text),
            scenario.$2,
          );
          expect(originalResult['_metadata'], {'sub_agent_model': 'ui-model'});
        });
      }
    });

    test(
      'downgrades provider-private thinking to text and drops tool thought signature',
      () {
        final messages = stripProviderPrivateConversationState([
          AiMessage.assistant(
            id: 'assistant_1',
            content: 'I updated the outline.',
            blocks: const [
              AiThinkingBlock(
                id: 'thinking_1',
                text: 'private reasoning',
                signature: 'provider-signature',
                encryptedContents: ['encrypted-reasoning'],
              ),
              AiToolCallBlock(
                id: 'tool_1',
                callId: 'call_1',
                toolName: 'Write',
                arguments: {'path': '/outline'},
                status: AiToolCallStatus.success,
                result: {'ok': true},
                thoughtSignature: 'gemini-signature',
              ),
              AiTextBlock(id: 'text_1', text: 'I updated the outline.'),
            ],
          ),
        ]);

        final blocks = messages.single.blocks;
        expect(
          blocks.whereType<AiThinkingBlock>(),
          isEmpty,
          reason:
              'thinking 的 signature/encrypted 只有原模型能解释，跨模型不保留 thinking block',
        );
        final tool = blocks.whereType<AiToolCallBlock>().single;
        expect(tool.callId, 'call_1');
        expect(tool.result, {'ok': true});
        expect(
          tool.thoughtSignature,
          isNull,
          reason: 'tool call 保留，但清掉 provider 私有 thought signature（发 unsigned）',
        );
        expect(
          blocks.whereType<AiTextBlock>().map((block) => block.text),
          containsAll(['private reasoning', 'I updated the outline.']),
          reason: 'thinking 文本降级为纯文本保留上下文，可见回复文本原样保留',
        );

        // ChatTurnRunner 在重建 Agent history 时使用 effectiveText；验证降级后的
        // thinking 不会只停留在 UI 持久化 block，目标模型实际会收到它。
        final targetHistory = convertAiMessageToAgentMessagesForModel(
          messages.single.copyWith(content: messages.single.effectiveText),
        );
        expect(
          targetHistory.first.content,
          contains('private reasoning'),
          reason: '跨模型续聊必须把可读的旧推理上下文发送给目标模型',
        );
        expect(
          targetHistory.first.blocks.whereType<ThinkingBlock>(),
          isEmpty,
          reason: '目标模型只能收到降级后的文本，不能收到旧 provider 私有 thinking block',
        );
      },
    );

    test(
      'preserves encrypted reasoning contents through persistence mapping',
      () {
        const original = AgentMessage(
          id: 'assistant_1',
          role: AgentMessageRole.assistant,
          blocks: [
            ThinkingBlock(
              'planned tool use',
              encryptedContents: ['enc_a', 'enc_b'],
            ),
          ],
        );

        final persisted = convertAgentMessageToAiMessage(original);
        final restored = convertAiMessageToAgentMessagesForModel(persisted);

        final persistedThinking = persisted.blocks.single as AiThinkingBlock;
        expect(persistedThinking.encryptedContents, ['enc_a', 'enc_b']);

        final restoredThinking = restored.single.blocks.single as ThinkingBlock;
        expect(restoredThinking.text, 'planned tool use');
        expect(restoredThinking.encryptedContents, ['enc_a', 'enc_b']);
      },
    );

    test('preserves signature-only thinking through persistence mapping', () {
      const original = AgentMessage(
        id: 'assistant_signature_only',
        role: AgentMessageRole.assistant,
        blocks: [ThinkingBlock('', signature: 'sig123')],
      );

      final persisted = convertAgentMessageToAiMessage(original);
      final restored = convertAiMessageToAgentMessagesForModel(persisted);

      final persistedThinking = persisted.blocks.single as AiThinkingBlock;
      expect(persistedThinking.text, isEmpty);
      expect(persistedThinking.signature, 'sig123');

      final restoredThinking = restored.single.blocks.single as ThinkingBlock;
      expect(restoredThinking.text, isEmpty);
      expect(restoredThinking.signature, 'sig123');
    });

    test(
      'synthesizes cancelled tool_result for legacy cancelled tool call',
      () {
        final messages = convertAiMessageToAgentMessagesForModel(
          AiMessage.assistant(
            id: 'assistant_1',
            content: '',
            blocks: const [
              AiToolCallBlock(
                id: 'block_call_1',
                callId: 'call_1',
                toolName: 'Read',
                arguments: {'path': '/novel'},
                status: AiToolCallStatus.cancelled,
              ),
            ],
          ),
        );

        expect(messages.length, 2);
        expect(messages.first.blocks.whereType<ToolCallBlock>(), hasLength(1));

        final toolResult = messages.last;
        expect(toolResult.type, AgentMessageType.tool_result);
        final block = toolResult.blocks.single as ToolResultBlock;
        expect(block.toolCallId, 'call_1');
        final content = block.content.single as TextBlock;
        final payload = jsonDecode(content.text) as Map<String, dynamic>;
        expect(payload['ok'], isFalse);
        expect(payload['cancelled'], isTrue);
        expect(payload['error_code'], 'user_cancelled');
      },
    );

    test('does not replay incomplete tool calls after restoring a session', () {
      final restored = convertAiMessageToAgentMessagesForModel(
        AiMessage.assistant(
          id: 'assistant_incomplete',
          content: '',
          blocks: [
            AiToolCallBlock(
              id: 'block_incomplete',
              callId: 'call_incomplete',
              toolName: 'Edit',
              arguments: {'path': '/chapters/1'},
              status: AiToolCallStatus.error,
              result: {'error_code': toolCallIncompleteErrorCode},
            ),
          ],
        ),
      );

      expect(restored, isEmpty);
    });

    test(
      'filters incomplete tool calls while preserving completed siblings',
      () {
        final restored = convertAiMessageToAgentMessagesForModel(
          AiMessage.assistant(
            id: 'assistant_mixed_tools',
            content: '',
            blocks: [
              AiToolCallBlock(
                id: 'block_incomplete',
                callId: 'call_incomplete',
                toolName: 'Edit',
                arguments: {'path': '/chapters/1'},
                status: AiToolCallStatus.error,
                result: {'error_code': toolCallIncompleteErrorCode},
              ),
              AiToolCallBlock(
                id: 'block_complete',
                callId: 'call_complete',
                toolName: 'Read',
                arguments: {'path': '/chapters/1'},
                status: AiToolCallStatus.success,
                result: {'ok': true},
              ),
            ],
          ),
        );

        expect(restored, hasLength(2));
        expect(
          (restored.first.blocks.single as ToolCallBlock).callId,
          'call_complete',
        );
        expect(
          (restored.last.blocks.single as ToolResultBlock).toolCallId,
          'call_complete',
        );
      },
    );

    test('rejects an empty tool call id', () {
      final message = AiMessage.assistant(
        id: 'assistant_legacy_empty_call',
        content: '',
        blocks: const [
          AiToolCallBlock(
            id: 'block_legacy_empty_call',
            callId: '',
            toolName: 'Read',
            arguments: {'path': '/novel'},
            status: AiToolCallStatus.success,
            result: {'ok': true},
          ),
        ],
      );

      expect(
        () => convertAiMessageToAgentMessagesForModel(message),
        throwsFormatException,
      );
    });
  });
}
