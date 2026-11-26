// 职责: 验证 AgentSkill 引用文件的路径约束、按需读取提示和导入导出行为
// 关联文件:
//   lib/shared/models/agent_skill.dart
//   lib/shared/models/agent_skill_reference.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/services/agent_skill_transfer.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/agent_skill.dart';
import 'package:reveric/shared/models/agent_skill_reference.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/services/agent_skill_transfer.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AgentSkillReferences', () {
    test('accepts nested references paths and rejects traversal', () {
      expect(
        AgentSkillReferences.isValidRelativePath('references/forms.md'),
        isTrue,
      );
      expect(
        AgentSkillReferences.isValidRelativePath('references/a/b.md'),
        isTrue,
      );
      expect(
        AgentSkillReferences.isValidRelativePath('references/../x.md'),
        isFalse,
      );
      expect(
        AgentSkillReferences.isValidRelativePath('scripts/run.py'),
        isFalse,
      );
    });

    test('normalizes nested paths and rejects duplicate paths', () {
      final normalized = AgentSkillReferences.normalizeOrThrow(const [
        AgentSkillReferenceFile(
          path: 'references/review/rubric.md',
          content: 'rubric',
        ),
        AgentSkillReferenceFile(path: 'references/forms.md', content: 'forms'),
      ]);
      expect(normalized.map((reference) => reference.path), [
        'references/forms.md',
        'references/review/rubric.md',
      ]);
      expect(
        () => AgentSkillReferences.normalizeOrThrow(const [
          AgentSkillReferenceFile(path: 'references/forms.md', content: 'one'),
          AgentSkillReferenceFile(path: 'references/forms.md', content: 'two'),
        ]),
        throwsFormatException,
      );
    });
  });

  group('buildAgentSkillBlock', () {
    test(
      'omits skill_resources when empty and exposes one Run directory command',
      () {
        final plain = buildAgentSkillBlock(
          'demo',
          instructions: 'Do the thing.',
        );
        expect(plain.contains('<skill_resources>'), isFalse);

        final withRefs = buildAgentSkillBlock(
          'demo',
          instructions: 'Do the thing.',
          references: const [
            AgentSkillReferenceDescriptor(path: 'references/forms.md'),
          ],
        );
        expect(
          withRefs.contains(
            '<reference_files count="1" discovery="on_demand">',
          ),
          isTrue,
        );
        expect(
          withRefs.contains(
            '<command tool="Run" action="reference-list">\n'
            '        {"command":"agent-skills","subcommand":"reference-list",'
            '"options":{"name":"demo"}}\n'
            '      </command>',
          ),
          isTrue,
        );
        expect(withRefs.contains('<file path='), isFalse);
        expect(withRefs, contains('正文已给出准确附件路径时直接读取'));
        expect(withRefs, contains('未知路径时再列目录'));
        expect(withRefs, isNot(contains('需要附件时先列目录')));
        expect(
          withRefs.contains(
            '{"command":"agent-skills","subcommand":"reference-get",'
            '"options":{"name":"demo","path":"&lt;exact path&gt;"}}',
          ),
          isTrue,
        );
        expect(withRefs.contains('form docs'), isFalse);
      },
    );
  });

  group('AgentSkillTransferService references', () {
    test(
      'import discovers sibling references and export restores them',
      () async {
        final temp = await Directory.systemTemp.createTemp('skill_refs_');
        addTearDown(() => temp.deleteSync(recursive: true));

        final skillDir = Directory(p.join(temp.path, 'demo-skill'))
          ..createSync();
        File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('''
---
name: demo-skill
description: Demo skill for references
---
Body instructions.
''');
        final refsDir = Directory(p.join(skillDir.path, 'references'))
          ..createSync();
        File(p.join(refsDir.path, 'forms.md')).writeAsStringSync('# Forms');
        final proseDir = Directory(p.join(refsDir.path, 'prose'))..createSync();
        File(p.join(proseDir.path, 'beats.md')).writeAsStringSync('# Beats');

        final service = const AgentSkillTransferService();
        final candidates = await service.discoverInDirectory(
          dirPath: temp.path,
          existing: const [],
        );
        expect(candidates, hasLength(1));
        final staged = await temp.createTemp('selected_');
        await candidates.single.materialize!(staged);
        final imported = [
          for (final path in [
            'references/forms.md',
            'references/prose/beats.md',
          ])
            AgentSkillReferenceFile(
              path: path,
              content: await File(
                p.joinAll([staged.path, ...path.split('/')]),
              ).readAsString(),
            ),
        ];
        expect(imported.first.content, '# Forms');

        final exportRoot = Directory(p.join(temp.path, 'out'))..createSync();
        await service.exportToDirectory(
          dirPath: exportRoot.path,
          entries: [
            NovelAgentSkillModel(
              id: 'nas_1',
              sourceKind: AgentSkillSourceKind.novelLocal,
              name: 'demo-skill',
              description: 'Demo skill for references',
              prompt: 'Body instructions.',
              references: imported,
            ),
          ],
        );

        final exportedRef = File(
          p.join(exportRoot.path, 'demo-skill', 'references', 'forms.md'),
        );
        expect(exportedRef.existsSync(), isTrue);
        expect(exportedRef.readAsStringSync(), '# Forms');
        expect(
          File(
            p.join(
              exportRoot.path,
              'demo-skill',
              'references',
              'prose',
              'beats.md',
            ),
          ).readAsStringSync(),
          '# Beats',
        );
      },
    );
  });
}
