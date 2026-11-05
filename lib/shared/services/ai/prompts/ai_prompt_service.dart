// 职责: AI Prompt 服务门面 — 聚合 renderer、composer、use cases，作为业务层唯一 prompt 入口。
// 关联文件:
//   lib/shared/services/ai/prompts/prompt_renderer.dart
//   lib/shared/services/ai/prompts/prompt_composer.dart
//   lib/shared/services/ai/prompts/use_cases/chat_prompt_use_case.dart
//   lib/shared/services/ai/prompts/use_cases/agent_prompt_use_case.dart
//   lib/shared/services/ai/prompts/use_cases/mode_prompt_use_case.dart
//   lib/shared/services/ai/prompts/use_cases/task_prompt_use_case.dart
//   lib/shared/services/ai/prompts/use_cases/title_prompt_use_case.dart

import '../prompt_template.dart';
import 'prompt_composer.dart';
import 'prompt_renderer.dart';
import 'use_cases/agent_prompt_use_case.dart';
import 'use_cases/assistant_prompt_use_case.dart';
import 'use_cases/chat_prompt_use_case.dart';
import 'use_cases/mode_prompt_use_case.dart';
import 'use_cases/task_prompt_use_case.dart';
import 'use_cases/title_prompt_use_case.dart';

class AiPromptService {
  AiPromptService({this.composer = const PromptComposer(), this._renderer}) {
    _chatPanel = ChatPromptUseCase(composer: composer, renderer: _renderer);
    _assistant = AssistantPromptUseCase(renderer: _renderer);
    _agent = AgentPromptUseCase(renderer: _renderer);
    _mode = ModePromptUseCase(renderer: _renderer);
    _task = TaskPromptUseCase(renderer: _renderer);
    _title = const TitlePromptUseCase();
  }

  final PromptComposer composer;
  final PromptRenderer? _renderer;
  late final ChatPromptUseCase _chatPanel;
  late final AssistantPromptUseCase _assistant;
  late final AgentPromptUseCase _agent;
  late final ModePromptUseCase _mode;
  late final TaskPromptUseCase _task;
  late final TitlePromptUseCase _title;

  ChatPromptUseCase get chatPanel => _chatPanel;
  AssistantPromptUseCase get assistant => _assistant;
  AgentPromptUseCase get agent => _agent;
  ModePromptUseCase get mode => _mode;
  TaskPromptUseCase get task => _task;
  TitlePromptUseCase get title => _title;

  static AiPromptService fromInitializedTemplates() {
    return AiPromptService(
      renderer: PromptRenderer(templates: PromptTemplateService.instance),
    );
  }
}
