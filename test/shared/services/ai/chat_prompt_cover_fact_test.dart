// 职责: 测试「封面：（未设置）」事实注入 — 仅在无封面且元数据齐备时出现，有封面则不注入。
// 关联文件:
//   lib/shared/services/ai/prompts/use_cases/chat_prompt_use_case.dart
//   lib/shared/models/novel.dart
//   assets/prompts/agent/orchestrator.md

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/ai_chat_models.dart'
    show AiSessionContext;
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/novel.dart' show Novel;
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/services/ai/prompts/use_cases/chat_prompt_use_case.dart';

const _coverFact = '封面：（未设置）';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(PromptTemplateService.loadAll);

  group('封面事实注入', () {
    test('无封面且书名简介齐备 → metadata 段含「封面：（未设置）」', () {
      expect(_promptFor(_novel()), contains(_coverFact));
    });

    test('已有封面 → 不注入该行', () {
      expect(
        _promptFor(_novel(coverAssetId: '/covers/a.png')),
        isNot(contains(_coverFact)),
      );
    });

    test('简介为空 → 不注入（创作向导还没跑完）', () {
      expect(_promptFor(_novel(description: '')), isNot(contains(_coverFact)));
    });

    test('快速开书草稿 → 不注入', () {
      expect(_promptFor(_novel(draft: true)), isNot(contains(_coverFact)));
    });

    test('封面路径只有空白字符 → 视为没有封面', () {
      expect(_promptFor(_novel(coverAssetId: '   ')), contains(_coverFact));
    });
  });

  group('orchestrator 下一步建议场景指引', () {
    test('调用时机写在 orchestrator.md，不写进工具描述', () {
      final raw = File(
        'assets/prompts/agent/orchestrator.md',
      ).readAsStringSync();

      expect(raw, contains('## 下一步建议'));
      expect(raw, contains('SuggestNextAction'));
      expect(raw, contains('没有值得推荐的下一步时不要调用'));
      expect(raw, contains('每回合最多调用一次本工具'));
      expect(raw, contains('多步任务执行途中不要挂建议'));
      expect(raw, contains('seed 传议题'));
      expect(raw, contains('seed 传场景'));
      expect(raw, contains('seed 传角色名'));
      expect(raw, contains('一次为限'));
    });
  });
}

String _promptFor(Novel novel) {
  const useCase = ChatPromptUseCase();
  return useCase.system(
    ChatPanelPromptInput(
      context: const AiSessionContext(),
      systemInstruction: '系统说明',
      mode: AiSessionMode.chat,
      novel: novel,
    ),
  );
}

Novel _novel({
  String? coverAssetId,
  String description = '一条被折断的调查线。',
  bool draft = false,
}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  return Novel(
    id: 'novel_cover',
    title: '夜航船',
    authorName: '周清远',
    description: description,
    coverAssetId: coverAssetId,
    status: 'in_progress',
    type: 'original',
    contentKind: contentKindNovel,
    wordCount: 12000,
    draft: draft,
    category: '悬疑',
    tags: const ['航船'],
    createdAt: now,
    updatedAt: now,
    deletedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}
