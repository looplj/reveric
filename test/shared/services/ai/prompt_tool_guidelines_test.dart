// 职责: 测试聊天与 Agent 提示词的组装逻辑：变量渲染完整、内容类型分支隔离、条件段落与能力开关。
// 关联文件:
//   lib/shared/services/ai/prompts/prompt_fragments.dart
//   lib/shared/services/ai/prompts/use_cases/chat_prompt_use_case.dart
//   lib/shared/services/ai/prompts/use_cases/agent_prompt_use_case.dart
//   lib/shared/services/ai/prompts/use_cases/mode_prompt_use_case.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/agent_skill.dart';
import 'package:reveric/shared/models/ai_chat_models.dart'
    show AiSessionContext;
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/novel.dart' show Novel;
import 'package:reveric/shared/services/ai/prompts/prompt_fragments.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/services/ai/prompts/use_cases/chat_prompt_use_case.dart';
import 'package:reveric/shared/services/ai/prompts/use_cases/mode_prompt_use_case.dart';
import 'package:reveric/shared/services/ai/prompts/use_cases/agent_prompt_use_case.dart';

// 本文件只断言组装逻辑，不断言具体文案；提示词措辞调整不应让这里失败。

const _contentKinds = [contentKindNovel, contentKindScreenplay];

// 经 AgentPromptUseCase.renderPromptTemplate 渲染的 Agent 模板。
const _agentTemplates = [
  'writer',
  'review',
  'explorer',
  'style_polish',
  'plot_architect',
  'character_analyst',
  'world_builder',
  'pacing_expert',
  'conflict_designer',
  'theme_guardian',
];

String _chatSystem({
  AiSessionContext context = const AiSessionContext(),
  String systemInstruction = '系统说明',
  AiSessionMode mode = AiSessionMode.chat,
  bool codemodeAvailable = false,
  Novel? novel,
}) {
  return const ChatPromptUseCase().system(
    ChatPanelPromptInput(
      context: context,
      systemInstruction: systemInstruction,
      mode: mode,
      codemodeAvailable: codemodeAvailable,
      novel: novel,
    ),
  );
}

String _renderAgent(String slug, String kind) {
  return const AgentPromptUseCase().renderPromptTemplate(
    PromptTemplateService.instance.rawAsset('assets/prompts/agent/$slug'),
    context: AiSessionContext(contentKind: kind),
  );
}

Novel _novel({
  required String type,
  required String contentKind,
  String category = '',
  List<String> tags = const [],
  String description = '',
  String status = 'in_progress',
  int wordCount = 0,
}) {
  final now = DateTime(2026, 9, 19);
  return Novel(
    id: 'novel_test',
    title: '平行故事',
    authorName: '',
    description: description,
    status: status,
    type: type,
    contentKind: contentKind,
    wordCount: wordCount,
    draft: false,
    category: category,
    tags: tags,
    createdAt: now,
    updatedAt: now,
    deletedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(PromptTemplateService.loadAll);

  group('template rendering', () {
    test('orchestrator system prompt leaves no unrendered variables', () {
      final template = PromptTemplateService.instance.rawAsset(
        'assets/prompts/agent/orchestrator',
      );
      for (final kind in _contentKinds) {
        for (final codemode in [false, true]) {
          final prompt = _chatSystem(
            context: AiSessionContext(contentKind: kind),
            systemInstruction: template,
            codemodeAvailable: codemode,
          );
          expect(prompt, isNot(contains('{{')), reason: '$kind/$codemode');
        }
      }
    });

    for (final slug in _agentTemplates) {
      test('$slug leaves no unrendered variables for each content kind', () {
        for (final kind in _contentKinds) {
          expect(_renderAgent(slug, kind), isNot(contains('{{')), reason: kind);
        }
      });
    }

    test('prose quality baseline is injected into writing agents', () {
      final baseline = File(
        'assets/prompts/fragments/prose_quality_baseline.md',
      ).readAsStringSync().trim();
      final orchestrator = PromptTemplateService.instance.renderAsset(
        'assets/prompts/agent/orchestrator',
        PromptFragments.orchestratorTemplateVariables(),
      );
      expect(orchestrator, contains(baseline));
      for (final slug in ['writer', 'review']) {
        for (final kind in _contentKinds) {
          expect(_renderAgent(slug, kind), contains(baseline), reason: slug);
        }
      }
    });
  });

  group('content kind branches', () {
    test('writer only receives fragments for its own content kind', () {
      final variables = PromptFragments.agentTemplateVariables();
      final novel = _renderAgent('writer', contentKindNovel);
      final screenplay = _renderAgent('writer', contentKindScreenplay);

      expect(novel, contains(variables['fragment_writing_craft']));
      expect(novel, contains(variables['fragment_chapter_reading_boundary']));
      expect(novel, isNot(contains(variables['fragment_screenplay_craft'])));
      expect(
        novel,
        isNot(contains(variables['fragment_scene_reading_boundary'])),
      );

      expect(screenplay, contains(variables['fragment_screenplay_craft']));
      expect(
        screenplay,
        contains(variables['fragment_scene_reading_boundary']),
      );
      expect(screenplay, isNot(contains(variables['fragment_writing_craft'])));
      expect(
        screenplay,
        isNot(contains(variables['fragment_chapter_reading_boundary'])),
      );
    });

    for (final slug in _agentTemplates) {
      test('$slug renders differently for novel and screenplay', () {
        // 模板若有内容类型分支，两种渲染结果必须不同；无分支的模板不在此列表。
        expect(
          _renderAgent(slug, contentKindNovel),
          isNot(_renderAgent(slug, contentKindScreenplay)),
        );
      });
    }
  });

  group('chat system prompt', () {
    test('includes the current operating system in the tool guidelines', () {
      final prompt = _chatSystem();
      final platform = RegExp(r'当前操作系统是 ([^。]+)。').allMatches(prompt).single;
      expect(platform.group(1)?.toLowerCase(), Platform.operatingSystem);
    });

    test('Codemode guidance follows execution capability and mode', () {
      for (final kind in _contentKinds) {
        for (final mode in AiSessionMode.values) {
          for (final available in [false, true]) {
            final prompt = _chatSystem(
              context: AiSessionContext(contentKind: kind),
              mode: mode,
              codemodeAvailable: available,
            );
            expect(
              prompt.contains('Codemode'),
              available && mode.isChat,
              reason: '$kind/${mode.name}/$available',
            );
          }
        }
      }
    });

    test('mode prompts reuse the non-Codemode tool guidelines', () {
      final prompt = const ModePromptUseCase().monologueSystem(
        characterName: '陆泽',
        characterRole: '主角',
        systemPrompt: '你是角色独白 Agent。',
      );
      expect(prompt, contains(PromptFragments.toolUseGuidelines()));
      expect(prompt, isNot(contains('Codemode')));
    });

    test('setup phase only renders for eligible novels without rules', () {
      const template = '{{#setup_phase}}SETUP_MARKER{{/setup_phase}}';
      final withRules = _chatSystem(
        context: const AiSessionContext(
          databasePath: '/novels/demo',
          workId: 'demo',
          contentKind: contentKindNovel,
          userRules: '章节字数：4000',
        ),
        systemInstruction: template,
      );
      final withoutRules = const ChatPromptUseCase().system(
        const ChatPanelPromptInput(
          context: AiSessionContext(
            databasePath: '/novels/demo',
            workId: 'demo',
            contentKind: contentKindNovel,
            novelChatSessionCount: 1,
          ),
          systemInstruction: template,
          novelOnboardingEligible: true,
        ),
      );

      expect(withRules, isNot(contains('SETUP_MARKER')));
      expect(withoutRules, contains('SETUP_MARKER'));
    });

    test('identity and soul settings are injected into template slots', () {
      final prompt = const ChatPromptUseCase().system(
        const ChatPanelPromptInput(
          context: AiSessionContext(),
          systemInstruction:
              '{{#fragment_identity}}IDENTITY={{fragment_identity}}{{/fragment_identity}}\n'
              '{{#fragment_soul}}SOUL={{fragment_soul}}{{/fragment_soul}}',
          identityPrompt: 'identity-value',
          soulPrompt: 'soul-value',
        ),
      );

      expect(prompt, matches(RegExp(r'IDENTITY=[\s\S]*identity-value')));
      expect(prompt, matches(RegExp(r'SOUL=[\s\S]*soul-value')));
    });

    test('workspace path and title appear exactly once', () {
      final prompt = _chatSystem(
        context: const AiSessionContext(
          novelName: '测试小说',
          workId: 'work_current',
          contentKind: contentKindNovel,
          workspacePath: '/works/work_current',
        ),
      );

      expect('/works/work_current'.allMatches(prompt), hasLength(1));
      expect('测试小说'.allMatches(prompt), hasLength(1));
    });

    test('novel metadata injects classification but not volatile fields', () {
      final prompt = _chatSystem(
        context: const AiSessionContext(novelName: '平行故事'),
        novel: _novel(
          type: 'fanfic',
          contentKind: contentKindNovel,
          category: '悬疑',
          tags: const ['同人', '平行线'],
          description: '原作主线之外的另一条调查线。',
          status: 'status_marker',
          wordCount: 12345,
        ),
      );

      expect('平行故事'.allMatches(prompt), hasLength(1));
      for (final value in ['fanfic', '悬疑', '同人', '平行线']) {
        expect(prompt, contains(value));
      }
      for (final value in ['原作主线之外的另一条调查线。', 'status_marker', '12345']) {
        expect(prompt, isNot(contains(value)));
      }
    });

    test('empty category and tags render as the same unset placeholder', () {
      String render({String category = '', List<String> tags = const []}) =>
          _chatSystem(
            novel: _novel(
              type: 'original',
              contentKind: contentKindScreenplay,
              category: category,
              tags: tags,
            ),
          );

      final empty = render();
      final filled = render(category: 'CATEGORY_X', tags: const ['TAG_X']);
      expect(filled, contains('CATEGORY_X'));
      expect(filled, contains('TAG_X'));

      // 空值占位符：filled 中分类、标签位置的文字在 empty 中被同一个占位符替换。
      final placeholders = empty
          .split('\n')
          .toSet()
          .difference(filled.split('\n').toSet());
      expect(placeholders, hasLength(2));
      String valueOf(String line) => line.split('：').last;
      expect(placeholders.map(valueOf).toSet(), hasLength(1));
    });
  });

  group('fragments', () {
    test('availableSkills falls back to description as when_to_use', () {
      final block = PromptFragments.availableSkills(const [
        AgentSkillSummary(name: 'skill_a', description: 'desc_a'),
        AgentSkillSummary(
          name: 'skill_b',
          whenToUse: 'when_b',
          description: 'desc_b',
        ),
      ]);

      expect(block, contains('<when_to_use>desc_a</when_to_use>'));
      expect(block, contains('<when_to_use>when_b</when_to_use>'));
      expect(block, isNot(contains('desc_b')));
      expect(block, isNot(contains('<description>')));
    });

    test('workspace context tag matches the delivered system-remind tag', () {
      // 投递侧（agent.dart、spawn_agent_run_providers.dart）使用 <system-remind>，
      // 提示词里引用的标签名必须一致，否则模型认不出该标签。
      final prompt = _chatSystem();
      expect(prompt, contains('system-remind'));
      expect(prompt, isNot(contains('system-mind')));
    });
  });
}
