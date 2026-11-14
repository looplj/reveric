// 职责: 验证 Agent 地图草稿参数与桌面制图师支持的选项保持一致。
// 关联文件:
//   lib/shared/services/generate_map_orchestrator.dart
//   lib/shared/models/map_agent.dart
//   lib/shared/services/map_prompt_builder.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/generate_map_orchestrator.dart';
import 'package:reveric/shared/services/map_prompt_builder.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/map_agent.dart';

void main() {
  test('shared draft options match Cartographer options', () {
    expect({
      ...mapStyleOptions.map((option) => option.id),
      mapCustomStyleId,
    }, mapDesignStyleIds);
    expect(mapDesignStyleIds, containsAll({'watercolor', 'atlas'}));
    expect(
      mapResolutions.map((option) => option.id).toSet(),
      mapDesignResolutionIds,
    );
    expect(
      mapQualities.map((option) => option.id).toSet(),
      mapDesignQualityIds,
    );
    expect(mapDefaultResolutionId, mapDesignDefaultResolutionId);
    expect(mapDefaultQualityId, mapDesignDefaultQualityId);
    expect(mapStyleOptions.first.id, mapDesignDefaultStyleId);
  });

  test('custom style stays separate from the editable prompt', () {
    const request = MapGenerationRequest(
      styleId: mapCustomStyleId,
      customStyleWord: '低多边形复古航海图',
      resolutionId: mapDefaultResolutionId,
      includeLocations: true,
    );

    expect(request.styleWord, '低多边形复古航海图');
    expect(
      buildMapSubmissionPrompt(
        prompt: '用户修改后的地图要求',
        styleWord: request.styleWord,
      ),
      '用户修改后的地图要求\n风格：低多边形复古航海图',
    );
  });

  test('editable map prompt excludes style and submission appends it', () {
    const request = MapGenerationRequest(
      styleId: null,
      resolutionId: mapDefaultResolutionId,
      includeLocations: true,
    );
    final editablePrompt = buildMapImagePrompt(
      regions: const [],
      places: const [],
      referenceCurrentImage: false,
    );
    final submittedPrompt = buildMapSubmissionPrompt(
      prompt: '用户修改后的地图要求',
      styleWord: '手绘羊皮纸',
    );

    expect(request.style, isNull);
    expect(editablePrompt, '绘制一张地图。');
    expect(editablePrompt, isNot(contains('手绘羊皮纸')));
    expect(editablePrompt, isNot(contains('奇幻')));
    expect(submittedPrompt, '用户修改后的地图要求\n风格：手绘羊皮纸');
    expect(
      buildMapSubmissionPrompt(prompt: submittedPrompt, styleWord: '手绘羊皮纸'),
      submittedPrompt,
    );
    expect(
      buildMapSubmissionPrompt(prompt: editablePrompt, styleWord: null),
      editablePrompt,
    );
  });

  test('handoff uses bundled draft tools and an available design skill', () {
    expect(mapAgentHandoffPrompt, contains('Read'));
    expect(mapAgentHandoffPrompt, contains('AgentSkill'));
    expect(mapAgentHandoffPrompt, contains('Run help map'));
    expect(mapAgentHandoffPrompt, contains('根据本次任务与可用技能的描述'));
    expect(mapAgentHandoffPrompt, contains('地图设计类技能'));
    expect(mapAgentHandoffPrompt, contains('地点建模、校验'));
    expect(mapAgentHandoffPrompt, isNot(contains('"command":"map"')));
    expect(mapAgentHandoffPrompt, isNot(contains('resolution')));
  });

  test(
    'handoff includes the current style without mixing it into map prompt',
    () {
      final handoff = buildMapAgentHandoffPrompt(
        styleId: mapCustomStyleId,
        styleWord: '低多边形复古航海图',
      );

      expect(handoff, contains('低多边形复古航海图'));
      expect(handoff, contains('独立风格参数'));
      expect(handoff, contains('不要写入地图内容提示词'));
    },
  );

  test('parent map reference is numbered after the current image', () {
    final parentOnly = buildMapImagePrompt(
      regions: const [],
      places: const [],
      referenceCurrentImage: false,
      mapType: mapTypeCity,
      parentReferenceName: '长梦',
    );
    final both = buildMapImagePrompt(
      regions: const [],
      places: const [],
      referenceCurrentImage: true,
      mapType: mapTypeCity,
      parentReferenceName: '长梦',
    );

    expect(parentOnly, contains('image 1 是上层地图「长梦」'));
    expect(both, contains('image 1 是这张地图的上一版画面'));
    expect(both, contains('image 2 是上层地图「长梦」'));
    expect(both, contains('不要沿用它的构图'));
  });

  test('recorded style word maps back to a preset or custom style', () {
    expect(mapStyleSelectionOf(null), isNull);
    expect(mapStyleSelectionOf('水墨舆图'), (
      styleId: 'inkmap',
      customStyleWord: null,
    ));
    expect(mapStyleSelectionOf('低多边形航海图'), (
      styleId: mapCustomStyleId,
      customStyleWord: '低多边形航海图',
    ));
  });

  test('sub-map handoff scopes the agent to the referenced place', () {
    final worldHandoff = buildMapAgentHandoffPrompt(
      styleId: null,
      styleWord: null,
    );
    final subMapHandoff = buildMapAgentHandoffPrompt(
      styleId: null,
      styleWord: null,
      subMapScale: '城镇平面图',
    );

    expect(worldHandoff, isNot(contains('子地点')));
    expect(subMapHandoff, contains('城镇平面图'));
    expect(subMapHandoff, contains('只规划引用地点的子孙地点'));
  });
}
