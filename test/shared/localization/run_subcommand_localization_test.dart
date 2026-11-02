// 职责: 验证 Run 各子命令在中英文中展示明确动作，并区分附件目录与正文读取。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/widgets/ai/tools/tool_card_descriptor.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _commands = <String, List<String>>{
  'settings': ['open'],
  'files': [
    'list',
    'read-text',
    'view-image',
    'read-video-metadata',
    'read-audio-metadata',
    'remove',
  ],
  'assets': ['list', 'read', 'view-image'],
  'stagings': ['schema', 'presets', 'sample', 'frames'],
  'agent-skills': [
    'list',
    'create',
    'update',
    'delete',
    'search',
    'get',
    'install',
    'reference-list',
    'reference-get',
    'reference-create',
    'reference-update',
    'reference-move',
    'reference-delete',
  ],
  'themes': ['list', 'read', 'create', 'update', 'apply', 'delete'],
  'agent-rules': ['list', 'read', 'create', 'update', 'delete'],
  'subagents': ['list', 'create', 'update', 'delete'],
  'sessions': ['list', 'read', 'search', 'get'],
  'novel': ['add-to-library'],
  'map': ['draft'],
  'notify': ['progress', 'question', 'complete', 'error'],
  'character': ['generate-avatar', 'generate-photo'],
  'item': ['generate-photo'],
};

AiToolCallBlock _run(
  String command,
  String? subcommand, {
  Map<String, dynamic> options = const {},
  Map<String, dynamic>? result,
}) => AiToolCallBlock(
  id: 'block',
  callId: 'call',
  toolName: 'Run',
  arguments: {
    'command': command,
    'subcommand': ?subcommand,
    'options': options,
  },
  status: AiToolCallStatus.success,
  result: result,
);

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets(
    'all supported Run operations have distinct localized titles in both languages',
    (tester) async {
      late BuildContext localizedContext;
      await tester.pumpWidget(
        EasyLocalization(
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('zh', 'CN'),
          startLocale: const Locale('zh', 'CN'),
          saveLocale: false,
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Builder(
                builder: (context) {
                  localizedContext = context;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final locale in [const Locale('zh', 'CN'), const Locale('en')]) {
        await localizedContext.setLocale(locale);
        await tester.pumpAndSettle();
        final context = localizedContext;
        for (final entry in _commands.entries) {
          final namespaceTitle = localizedToolCallTitle(
            context,
            _run(entry.key, null),
          );
          final titles = <String>{};
          for (final subcommand in entry.value) {
            final block = _run(entry.key, subcommand);
            final title = localizedToolCallTitle(context, block);
            expect(title, isNotEmpty);
            expect(title, isNot(contains('ai.tool_')));
            expect(
              title,
              isNot(namespaceTitle),
              reason: '${entry.key} $subcommand must name the operation',
            );
            expect(toolActionVerb(context, block), title);
            expect(
              titles.add(title),
              isTrue,
              reason: '${entry.key} $subcommand must remain distinguishable',
            );
          }
        }
        for (final action in [
          ('settings', 'open', '打开', 'Open'),
          ('files', 'read-text', '读取文本', 'Read text'),
          ('files', 'view-image', '查看图片', 'View image'),
          ('files', 'read-video-metadata', '读取视频元数据', 'Read video metadata'),
          ('files', 'read-audio-metadata', '读取音频元数据', 'Read audio metadata'),
          ('assets', 'view-image', '查看图片', 'View image'),
        ]) {
          final expected = locale.languageCode == 'zh' ? action.$3 : action.$4;
          expect(
            localizedRunCommandAction(context, action.$1, action.$2),
            expected,
          );
          for (final status in [
            AiToolCallStatus.running,
            AiToolCallStatus.success,
          ]) {
            final block = _run(action.$1, action.$2).copyWith(status: status);
            expect(localizedToolCallTitle(context, block), expected);
            expect(toolActionVerb(context, block), expected);
          }
          final restored = AiToolCallBlock(
            id: 'restored',
            callId: 'restored',
            toolName: 'Run',
            arguments: const {},
            status: AiToolCallStatus.success,
            result: {'command': '${action.$1} ${action.$2}'},
          );
          expect(localizedToolCallTitle(context, restored), expected);
        }

        for (final (section, zh, en) in [
          ('general', '通用', 'General'),
          ('appearance', '外观', 'Appearance'),
          ('editor', '编辑器', 'Editor'),
          ('reading', '阅读', 'Reading'),
          ('ai_agents', 'AI 助手', 'AI Assistant'),
          ('providers', 'AI 供应商', 'AI Providers'),
          ('usage', 'AI 用量', 'AI Usage'),
          ('mcp', 'MCP', 'MCP'),
          ('plugins', '插件', 'Plugins'),
          ('backup', '备份', 'Backup'),
          ('about', '关于', 'About'),
          ('remote', '远程控制', 'Remote Control'),
          ('storage', '存储', 'Storage'),
        ]) {
          final block = _run('settings', 'open', options: {'section': section});
          final verb = locale.languageCode == 'zh' ? '打开' : 'Open';
          final target = locale.languageCode == 'zh' ? zh : en;
          expect(localizedToolCallTitle(context, block), verb);
          expect(toolRowTarget(context, block, null), target);
          expect(toolHeaderSubtitle(context, block, null), '$verb $target');
        }
        expect(
          toolRowTarget(context, _run('help', 'settings'), null),
          locale.languageCode == 'zh' ? '设置' : 'Settings',
        );

        for (final operation in _commands['themes']!) {
          final block = _run('themes', operation);
          expect(toolRowTarget(context, block, null), isNull);
          expect(
            toolHeaderSubtitle(context, block, null),
            localizedToolCallTitle(context, block),
          );
        }
        final themeRead = _run(
          'themes',
          'read',
          options: {'id': 'builtin:classic'},
          result: {'name': 'classic'},
        );
        expect(
          localizedToolCallTitle(context, themeRead),
          locale.languageCode == 'zh' ? '读取主题' : 'Reading theme',
        );
        expect(toolRowTarget(context, themeRead, null), 'classic');
        expect(
          toolRowTarget(
            context,
            _run('themes', 'apply', options: {'id': 'custom-id'}),
            null,
          ),
          'custom-id',
        );
        expect(
          toolRowTarget(
            context,
            _run('themes', 'create', options: {'name': '暮色'}),
            null,
          ),
          '暮色',
        );
        expect(
          toolRowTarget(context, _run('help', 'themes'), null),
          locale.languageCode == 'zh' ? '界面主题' : 'App themes',
        );
        final listed = _run(
          'agent-skills',
          'reference-list',
          options: {'name': '系统管理'},
        );
        final read = _run(
          'agent-skills',
          'reference-get',
          options: {'name': '系统管理', 'path': 'references/subagents.md'},
        );
        final moved = _run(
          'agent-skills',
          'reference-move',
          options: {
            'name': '技能',
            'path': 'references/old.md',
            'new_path': 'references/new.md',
          },
        );
        expect(
          localizedToolCallTitle(context, listed),
          locale.languageCode == 'zh' ? '列出附件' : 'Listing references',
        );
        expect(
          localizedToolCallTitle(context, read),
          locale.languageCode == 'zh' ? '读取附件' : 'Reading reference',
        );
        expect(toolRowTarget(context, listed, null), '系统管理');
        expect(toolRowTarget(context, read, null), 'references/subagents.md');
        expect(
          toolRowTarget(context, moved, null),
          'references/old.md → references/new.md',
        );
        expect(
          toolHeaderSubtitle(context, read, null),
          contains('references/subagents.md'),
        );
        expect(
          localizedToolCallTitle(context, _run('--help', null)),
          localizedToolCallTitle(context, _run('help', null)),
        );
        expect(
          localizedToolCallTitle(context, _run('sessions', '--help')),
          localizedToolCallTitle(context, _run('help', null)),
        );
        // 旧记录只有结果中的命令名，也应还原到子命令标题。
        final persisted = AiToolCallBlock(
          id: 'persisted',
          callId: 'persisted',
          toolName: 'Run',
          arguments: const {},
          status: AiToolCallStatus.success,
          result: const {'command': 'agent-skills reference-get'},
        );
        expect(
          localizedToolCallTitle(context, persisted),
          localizedToolCallTitle(context, read),
        );
        expect(
          localizedToolCallTitle(context, _run('unknown', 'action')),
          locale.languageCode == 'zh' ? '运行命令' : 'Run',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
