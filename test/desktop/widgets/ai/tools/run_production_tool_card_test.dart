// 职责: 验证媒体工具、后台任务与待办摘要的中英文展示。
// 关联文件:
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/widgets/ai/tools/run_tool_card_body.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/todo.json
//   assets/translations/zh-CN/todo.json
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/tools/run_tool_card_body.dart';
import 'package:reveric/shared/widgets/ai/tools/tool_card_descriptor.dart';
import 'package:reveric/shared/widgets/ai/tools/tool_detail_body.dart';
import 'package:reveric/shared/widgets/ai/tools/todo_tool_card.dart';
import 'package:reveric/shared/widgets/ai/tool_approval_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  for (final locale in [const Locale('zh', 'CN'), const Locale('en')]) {
    testWidgets('localizes production Run cards in $locale', (tester) async {
      final zh = locale.languageCode == 'zh';
      final actions = [
        ('production', 'canvas-preview', '预览制作画布', 'Preview production canvas'),
        ('production', 'capture-panorama', '全景取景', 'Capture panorama views'),
        ('production', 'derive-view', '派生图片视角', 'Derive image view'),
        ('production', 'image-preset', '创建图片预设草稿', 'Create image preset draft'),
        ('production', 'split-grid', '宫格切分', 'Split grid'),
        ('production', 'capture-frame', '关键帧截取', 'Capture frame'),
        ('production', 'separate-audio', '音视频分离', 'Extract audio'),
        ('production', 'mute-video', '静音', 'Mute'),
        ('production', 'trim-video', '裁剪时长', 'Trim'),
        ('assets', 'list', '查询素材', 'List assets'),
        ('assets', 'read', '读取素材', 'Read asset'),
        ('stagings', 'list', '查询导演文档', 'List director documents'),
        ('stagings', 'read', '读取导演文档', 'Read director document'),
        ('stagings', 'create', '创建导演文档', 'Create director document'),
        ('stagings', 'apply', '编辑导演文档', 'Edit director document'),
        ('stagings', 'write', '编辑导演文档', 'Edit director document'),
        ('stagings', 'restore', '恢复导演文档', 'Restore director document'),
        ('stagings', 'remove', '删除导演文档', 'Delete director document'),
        ('stagings', 'preview', '刷新导演预览', 'Refresh director preview'),
        ('stagings', 'output', '导出导演画面', 'Export director output'),
      ];
      await tester.pumpWidget(
        EasyLocalization(
          supportedLocales: [locale],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          startLocale: locale,
          fallbackLocale: locale,
          child: Builder(
            builder: (context) => MaterialApp(
              locale: context.locale,
              supportedLocales: context.supportedLocales,
              localizationsDelegates: context.localizationDelegates,
              theme: RevericThemeData.reveric.toThemeData(),
              home: RevericTheme(
                data: RevericThemeData.reveric,
                child: Scaffold(
                  body: Builder(
                    builder: (context) {
                      for (final action in actions) {
                        final block = AiToolCallBlock(
                          id: '${action.$1}-${action.$2}',
                          callId: 'call',
                          toolName: 'Run',
                          arguments: {
                            'command': action.$1,
                            'subcommand': action.$2,
                            'options': {'staging_id': 'id'},
                          },
                          status: AiToolCallStatus.success,
                          result: {
                            'ok': true,
                            if (action.$1 == 'production') 'target_label': '雨夜',
                            if (action.$2 == 'list')
                              'entries': []
                            else
                              'title': '雨夜',
                          },
                        );
                        expect(
                          localizedToolCallTitle(context, block),
                          zh ? action.$3 : action.$4,
                        );
                        expect(
                          describeToolOperation(context, (
                            capability: 'files.read',
                            kind: '${action.$1}.${action.$2}',
                            target: '雨夜',
                            status: 'running',
                            result: null,
                          )).title,
                          zh ? action.$3 : action.$4,
                        );
                        expect(
                          toolActionVerb(context, block),
                          zh ? action.$3 : action.$4,
                        );
                        expect(
                          toolRowTarget(context, block, null),
                          action.$2 == 'list'
                              ? (zh ? '0 个结果' : '0 results')
                              : '雨夜',
                        );
                      }
                      for (final action in [
                        ('files', 'list', '列出文件', 'List files'),
                        ('files', 'read-text', '读取文本', 'Read text'),
                        ('files', 'remove', '删除', 'Delete'),
                        ('providers', 'list', '查询供应商', 'List providers'),
                        ('providers', 'read', '查看供应商', 'View provider'),
                        ('providers', 'models', '查询模型', 'List models'),
                        ('editing', 'export', '导出视频', 'Export video'),
                        ('editing', 'cleanup', '删除', 'Delete'),
                        ('editing', 'read', '查看剪辑', 'View timeline'),
                        ('editing', 'apply', '调整剪辑', 'Edit timeline'),
                        ('operations', 'wait', '等待任务完成', 'Wait for task'),
                        ('ffmpeg', 'probe', '检查媒体信息', 'Inspect media'),
                        ('ffmpeg', 'frames', '提取视频帧', 'Extract video frames'),
                      ]) {
                        final block = AiToolCallBlock(
                          id: 'media',
                          callId: 'media',
                          toolName: 'Run',
                          arguments: {
                            'command': action.$1,
                            'subcommand': action.$2,
                            if (action.$1 == 'files')
                              'options': {
                                'path': 'sessions/session/example.mp4',
                              },
                          },
                        );
                        expect(
                          localizedToolCallTitle(context, block),
                          zh ? action.$3 : action.$4,
                        );
                        expect(
                          toolRowTarget(context, block, null),
                          action.$1 == 'files'
                              ? 'sessions/session/example.mp4'
                              : isNull,
                        );
                        if (action.$1 == 'files') {
                          final operation = describeToolOperation(context, (
                            capability: null,
                            kind: '${action.$1}.${action.$2}',
                            target: 'sessions/session/example.mp4',
                            status: 'completed',
                            result: null,
                          ));
                          expect(operation.title, zh ? action.$3 : action.$4);
                          expect(
                            operation.target,
                            'sessions/session/example.mp4',
                          );
                          expect(operation.state, zh ? '已完成' : 'Completed');
                        }
                        if (action.$1 == 'providers') {
                          final failed = block.copyWith(
                            status: AiToolCallStatus.error,
                            result: const {
                              'ok': false,
                              'error_code': 'invalid_argument',
                            },
                          );
                          expect(
                            toolHeaderSubtitle(context, failed, null),
                            zh ? action.$3 : action.$4,
                          );
                          expect(toolRowTarget(context, failed, null), isNull);
                          final success = block.copyWith(
                            status: AiToolCallStatus.success,
                            result: {
                              'ok': true,
                              if (action.$2 == 'read')
                                'name': 'AtlasCloud'
                              else
                                'entries': [
                                  {'id': 'model'},
                                ],
                            },
                          );
                          expect(
                            toolRowTarget(context, success, null),
                            action.$2 == 'read'
                                ? 'AtlasCloud'
                                : (zh ? '1 个结果' : '1 results'),
                          );
                        }
                      }
                      expect(
                        localizedRunHelpTopic(context, 'providers'),
                        zh ? '供应商' : 'Providers',
                      );
                      final helpTopics = [
                        ('production', '制作', 'Production'),
                        ('files', '文件', 'Files'),
                        ('assets', '素材', 'Assets'),
                        ('stagings', '导演台', 'Director'),
                        ('styles', '风格', 'Styles'),
                        ('editing', '剪辑', 'Editing'),
                        ('ffmpeg', '媒体处理', 'Media processing'),
                        ('operations', '后台任务', 'Background tasks'),
                      ];
                      for (final topic in helpTopics) {
                        final help = AiToolCallBlock(
                          id: 'help_${topic.$1}',
                          callId: 'help_${topic.$1}',
                          toolName: 'Run',
                          arguments: {
                            'command': 'help',
                            'subcommand': topic.$1,
                          },
                        );
                        expect(
                          localizedToolCallTitle(context, help),
                          zh ? '查看命令帮助' : 'Reading command help',
                        );
                        expect(
                          toolRowTarget(context, help, null),
                          zh ? topic.$2 : topic.$3,
                        );
                        expect(
                          toolHeaderSubtitle(context, help, null),
                          zh
                              ? '查看命令帮助 ${topic.$2}'
                              : 'Reading command help ${topic.$3}',
                        );
                      }
                      final export = describeToolOperation(context, (
                        capability: null,
                        kind: 'editing.export',
                        target: '/editings/internal-id',
                        status: 'running',
                        result: null,
                      ));
                      expect(export.title, zh ? '导出视频' : 'Export video');
                      expect(export.target, isEmpty);
                      expect(export.state, zh ? '执行中' : 'Running');
                      final namedExport = describeToolOperation(context, (
                        capability: null,
                        kind: 'editing.export',
                        target: 'scene01.mp4',
                        status: 'running',
                        result: null,
                      ));
                      expect(namedExport.target, 'scene01.mp4');
                      final directorExport = describeToolOperation(context, (
                        capability: null,
                        kind: 'director.output',
                        target: 'director/staging_internal-id/output',
                        status: 'running',
                        result: null,
                      ));
                      expect(
                        directorExport.title,
                        zh ? '导出导演画面' : 'Export director output',
                      );
                      expect(directorExport.target, isEmpty);
                      expect(directorExport.state, zh ? '执行中' : 'Running');
                      final namedDirectorExport =
                          describeToolOperation(context, (
                            capability: null,
                            kind: 'director.output',
                            target: 'scene01.mp4',
                            status: 'completed',
                            result: null,
                          ));
                      expect(namedDirectorExport.target, 'scene01.mp4');
                      for (final target in ['ffmpeg/frames', 'scene01.mp4']) {
                        final frames = describeToolOperation(context, (
                          capability: null,
                          kind: 'ffmpeg.frames',
                          target: target,
                          status: 'completed',
                          result: null,
                        ));
                        expect(
                          frames.title,
                          zh ? '提取视频帧' : 'Extract video frames',
                        );
                        expect(
                          frames.target,
                          target == 'ffmpeg/frames' ? '' : target,
                        );
                      }
                      return Column(
                        children: [
                          for (final code in ['internal', 'file_unavailable'])
                            ProviderScope(
                              overrides: [
                                appDebugModeProvider.overrideWithValue(false),
                              ],
                              child: AiToolDetailBody(
                                block: AiToolCallBlock(
                                  id: code,
                                  callId: code,
                                  toolName: 'Run',
                                  arguments: const {
                                    'command': 'ffmpeg',
                                    'subcommand': 'execute',
                                  },
                                  status: AiToolCallStatus.error,
                                  result: {
                                    'run_id': code,
                                    'status': 'failed',
                                    'result': {
                                      'ok': false,
                                      'error_code': code,
                                      'error': code == 'internal'
                                          ? 'The operation failed.'
                                          : 'FileSystemException: File is unavailable, path = /private/input.mp4',
                                    },
                                  },
                                ),
                              ),
                            ),
                          for (final count in [0, 1, 2])
                            TodoToolCard(
                              block: AiToolCallBlock(
                                id: 'todo$count',
                                callId: 'todo$count',
                                toolName: 'TodoWrite',
                                arguments: const {},
                                status: AiToolCallStatus.success,
                                result: {
                                  'summary': '$count pending todos',
                                  'todos': List.generate(
                                    count,
                                    (i) => {
                                      'content': 'Task $i',
                                      'status': 'pending',
                                    },
                                  ),
                                },
                              ),
                            ),
                          const RunToolCardBody(
                            block: AiToolCallBlock(
                              id: 'assets',
                              callId: 'list',
                              toolName: 'Run',
                              arguments: {
                                'command': 'assets',
                                'subcommand': 'list',
                              },
                              status: AiToolCallStatus.success,
                              result: {
                                'ok': true,
                                'entries': [
                                  {'id': 'a', 'name': 'image'},
                                ],
                              },
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(zh ? '1 个结果' : '1 results'), findsOneWidget);
      expect(find.text(zh ? '暂无待办任务' : 'No pending tasks'), findsOneWidget);
      expect(find.text(zh ? '剩余 1 项任务' : '1 task remaining'), findsOneWidget);
      expect(find.text(zh ? '剩余 2 项任务' : '2 tasks remaining'), findsOneWidget);
      expect(find.textContaining('pending todos'), findsNothing);
      expect(find.text('The operation failed.'), findsNothing);
      expect(find.textContaining('FileSystemException'), findsNothing);
      expect(
        find.text(
          zh
              ? '无法读取输入文件，请检查文件路径后重试。'
              : 'The input file could not be read. Check its path and try again.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(zh ? '任务执行失败，请重试。' : 'The task failed. Please try again.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
