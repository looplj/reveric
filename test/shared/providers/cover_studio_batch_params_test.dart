// 职责: 验证封面批次记录按当时的复杂度恢复设计器，没记录复杂度的批次恢复成未选。
// 关联文件:
//   lib/shared/providers/cover_studio_providers.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/database/app_database.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/testing.md

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/cover_studio_providers.dart';

void main() {
  late ProviderContainer container;
  late CoverStudioController controller;
  CoverStudioState state() =>
      container.read(coverStudioControllerProvider('novel_test'));

  setUp(() {
    container = ProviderContainer(
      overrides: [
        coverStudioImageModelSelectionProvider.overrideWithValue(null),
      ],
    );
    controller = container.read(
      coverStudioControllerProvider('novel_test').notifier,
    );
  });
  tearDown(() => container.dispose());

  test('selecting a batch restores its complexity or clears it', () {
    controller.setComplexity('medium');

    controller.selectBatch(_batch('batch_low', '{"complexity":"low"}'));
    expect(state().complexityId, 'low');

    // 没记录复杂度的批次用的是目录默认值，不能沿用面板上刚选的档位。
    controller.setComplexity('medium');
    controller.selectBatch(_batch('batch_default', '{"ratio":"1_1"}'));
    expect(state().complexityId, isNull);
  });

  test('reusing a batch generates with the complexity it recorded', () async {
    controller.setComplexity('medium');

    await controller.reuseBatch(_batch('batch_low', '{"complexity":"low"}'));
    expect(state().complexityId, 'low');

    controller.setComplexity('medium');
    await controller.reuseBatch(_batch('batch_default', '{}'));
    expect(state().complexityId, isNull);
  });
}

ImageBatchRow _batch(String id, String paramsJson) => ImageBatchRow(
  id: id,
  purpose: 'cover',
  status: imageBatchStatusCompleted,
  prompt: '一张封面',
  requestedCount: 1,
  completedCount: 1,
  paramsJson: paramsJson,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  deletedAt: notDeletedSentinel,
);
