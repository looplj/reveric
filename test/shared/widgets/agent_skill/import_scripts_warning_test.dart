// 职责: 验证导入确认页的脚本标签和同名覆盖选择。
// 关联文件:
//   lib/shared/widgets/agent_skill_import_dialog.dart
//   lib/shared/services/agent_skill_transfer.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/services/agent_skill_import_parser.dart';
import 'package:reveric/shared/services/agent_skill_transfer.dart';
import 'package:reveric/shared/widgets/agent_skill_import_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'marketplace_test_support.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('$platform shows the script label and confirms import', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      List<AgentSkillImportCandidate>? selected;
      const candidate = AgentSkillImportCandidate(
        filePath: 'skills/writer/SKILL.md',
        parsed: AgentSkillImportParseResult(
          name: 'Writer',
          description: 'Write',
          body: 'Instructions',
        ),
        nameConflict: false,
        hasScripts: true,
      );
      await tester.pumpWidget(
        marketplaceTestHost(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  selected = await showAgentSkillImportDialog(
                    context,
                    candidates: [candidate],
                  ),
              child: const Text('Open import'),
            ),
          ),
          platform,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open import'));
      await tester.pumpAndSettle();
      expect(
        find.text(tr(LocaleKeys.agentSkillImportHasScripts)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(selected, [candidate]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('selecting an existing skill returns it for replacement', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<AgentSkillImportCandidate>? selected;
    const candidate = AgentSkillImportCandidate(
      filePath: 'skills/h3-fight/SKILL.md',
      parsed: AgentSkillImportParseResult(
        name: 'h3-fight',
        description: 'Fight',
        body: 'Instructions',
      ),
      nameConflict: true,
    );
    await tester.pumpWidget(
      marketplaceTestHost(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => selected = await showAgentSkillImportDialog(
              context,
              candidates: [candidate],
            ),
            child: const Text('Open import'),
          ),
        ),
        TargetPlatform.macOS,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open import'));
    await tester.pumpAndSettle();
    expect(find.text(tr(LocaleKeys.agentSkillImportExists)), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('h3-fight'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(selected, [candidate]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
