// 职责: 承载双端共享剧本文档、节点选区和自动保存，按宿主限定整集或连续场次范围。
// 关联文件:
//   lib/shared/widgets/screenplay/document_session.dart
//   lib/shared/widgets/screenplay/document_rows.dart
//   lib/shared/widgets/screenplay/typography_scope.dart
//   lib/shared/widgets/screenplay/editing_scope.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../models/screenplay_document.dart';
import '../../models/screenplay_element.dart';
import '../../providers/novel_providers.dart';
import '../../providers/maps_providers.dart';
import '../../providers/screenplay_providers.dart';
import 'document_toolbar.dart';
import 'loading.dart';
import '../confirm_dialog.dart';
import 'document_session.dart';
import 'document_rows.dart';
import 'editing_scope.dart';
import 'element_options.dart';
import 'typography_scope.dart';

final _log = AppLogger.forModule('ScreenplayDocumentEditor');

class ScreenplayEditorScope {
  const ScreenplayEditorScope(
    this.episodeId, {
    this.sceneId,
    this.selectedSceneId,
  });
  final String episodeId;
  final String? sceneId;
  final String? selectedSceneId;
}

typedef ScreenplayPickCharacter =
    Future<String?> Function(BuildContext context, ScreenplayElement element);

class ScreenplayDocumentEditor extends HookConsumerWidget {
  const ScreenplayDocumentEditor({
    super.key,
    required this.novel,
    required this.scope,
    required this.registerFlush,
    required this.pickCharacter,
    this.mobile = false,
    this.footerBuilder,
    this.toolbarTrailingBuilder,
    this.onVisibleSceneChanged,
  });
  final Novel novel;
  final ScreenplayEditorScope scope;
  final ValueChanged<Future<void> Function()?> registerFlush;
  final ScreenplayPickCharacter pickCharacter;
  final bool mobile;

  /// 正文滚动到新场次时上报，供宿主把选中态跟到阅读位置。必须传稳定回调。
  final ValueChanged<String>? onVisibleSceneChanged;
  final Widget Function(BuildContext, ScreenplayDocumentSession)?
  toolbarTrailingBuilder;
  final Widget Function(BuildContext, ScreenplayDocumentSession?)?
  footerBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(
      screenplayServiceProvider(novel.contentDatabasePath!, novelId: novel.id),
    );
    final stream = useMemoized(() => service.watchDocument(scope.episodeId), [
      service,
      scope.episodeId,
    ]);
    final incoming = useStream(stream, preserveState: false);
    useEffect(() {
      if (incoming.hasError) {
        _log.error(
          'Failed to read screenplay document',
          error: incoming.error,
          stackTrace: incoming.stackTrace,
        );
      }
      return null;
    }, [stream, incoming.error, incoming.stackTrace]);
    final lastStream = useRef(stream);
    final cached = useRef<ScreenplayDocument?>(null);
    if (lastStream.value != stream) {
      lastStream.value = stream;
      cached.value = null;
    }
    cached.value = incoming.data ?? cached.value;
    final value = cached.value;
    final mountReady = useMemoized(() => ValueNotifier(false), [
      stream,
      scope.sceneId,
    ]);
    useEffect(() => mountReady.dispose, [mountReady]);
    final ready = useValueListenable(mountReady);
    useEffect(() {
      var cancelled = false;
      if (value != null && !ready) {
        // 先提交包含工具栏和 loading 的一帧，再创建整集输入框。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!cancelled) {
            mountReady.value = true;
          }
        });
      }
      return () => cancelled = true;
    }, [value != null, ready, mountReady]);
    if (value == null || !ready) {
      return Column(
        children: [
          ScreenplayDocumentToolbar(mobile: mobile),
          Expanded(
            child: value == null && incoming.hasError
                ? Center(
                    child: Text(context.t(LocaleKeys.screenplaySaveFailed)),
                  )
                : const ScreenplayLoading(),
          ),
          if (footerBuilder != null) footerBuilder!(context, null),
        ],
      );
    }
    return _DocumentEditorBody(
      key: ValueKey('${scope.episodeId}/${scope.sceneId}'),
      host: this,
      incoming: value,
      registerFlush: registerFlush,
    );
  }
}

class _DocumentEditorBody extends HookConsumerWidget {
  const _DocumentEditorBody({
    super.key,
    required this.host,
    required this.registerFlush,
    required this.incoming,
  });
  final ScreenplayDocumentEditor host;
  final ValueChanged<Future<void> Function()?> registerFlush;
  final ScreenplayDocument incoming;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = host.novel.contentDatabasePath!;
    final service = ref.watch(
      screenplayServiceProvider(path, novelId: host.novel.id),
    );
    final database = ref.watch(novelContentDatabaseProvider(path));
    final overlay = ref.watch(workingOverlayServiceProvider(path));
    final session = useMemoized(() {
      final id = host.scope.sceneId;
      final initial = id == null
          ? incoming
          : ScreenplayDocument(
              episodeId: incoming.episodeId,
              screenplayId: incoming.screenplayId,
              fullEpisode: false,
              previousSceneId: incoming.sceneOrder.indexOf(id) > 0
                  ? incoming.sceneOrder[incoming.sceneOrder.indexOf(id) - 1]
                  : null,
              nextSceneId:
                  incoming.sceneOrder.indexOf(id) + 1 <
                      incoming.sceneOrder.length
                  ? incoming.sceneOrder[incoming.sceneOrder.indexOf(id) + 1]
                  : null,
              elements: incoming.sceneElements(id),
              scenes: {id: ?incoming.scenes[id]},
              evidenceVersions: {
                for (final entry in incoming.evidenceVersions.entries)
                  if (incoming.evidence[entry.key] == id)
                    entry.key: entry.value,
              },
              evidence: Map.fromEntries(
                incoming.evidence.entries.where((e) => e.value == id),
              ),
            );
      return ScreenplayDocumentSession(
        initial,
        database: database,
        service: service,
        overlay: overlay,
      );
    }, [incoming.episodeId, host.scope.sceneId]);
    session.episodeSceneOrder = incoming.sceneOrder;
    useEffect(() => session.dispose, [session]);
    final register = useRef(registerFlush)..value = registerFlush;
    useEffect(() {
      register.value(session.flush);
      return () => register.value(null);
    }, [session]);
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          session.acceptExternal(incoming);
        }
      });
      return null;
    }, [incoming, session]);
    final characters = ref.watch(characterProfilesProvider(path)).value;
    final locations = ref.watch(locationsProvider(path)).value;
    session.controller.characterNames = {
      for (final person in characters ?? []) person.id: person.name,
    };
    session.controller.locationNames = {
      for (final location in locations ?? []) location.id: location.name,
    };
    session.controller.splitNativeNewlines = host.mobile;
    session.controller.onFindHeading = (id) =>
        session.headingEditors[id]?.call();
    session.controller.refreshFindProjection();
    session.controller.onFindSkipped = (count) =>
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.t(
                LocaleKeys.screenplayHeadingMatchesSkipped,
                namedArgs: {'count': '$count'},
              ),
            ),
          ),
        );
    final actions = useMemoized(
      () => ScreenplayDocumentActions(
        session,
        host.pickCharacter,
        host.mobile,
        path,
      ),
      [session, host.pickCharacter, host.mobile, path],
    );
    // 选中场次只用于滚动定位，走 notifier 而不是构造参数：进 memo deps 会让
    // 高亮每跟随一次就重建整棵正文。
    final selectedScene = useMemoized(
      () => ValueNotifier<String?>(host.scope.selectedSceneId),
      [session],
    );
    useEffect(() => selectedScene.dispose, [selectedScene]);
    useEffect(() {
      selectedScene.value = host.scope.selectedSceneId;
      return null;
    }, [selectedScene, host.scope.selectedSceneId]);
    final editor = useMemoized(
      () => ScreenplayEditingScope(
        controller: session.controller,
        onFocusElement: (_, _) {},
        onCycleType: (backward) => actions.cycleType(context, backward),
        child: ScreenplayDocumentRows(
          actions: actions,
          selectedSceneId: selectedScene,
          onVisibleSceneChanged: host.onVisibleSceneChanged,
        ),
      ),
      [
        actions,
        characters,
        locations,
        selectedScene,
        host.onVisibleSceneChanged,
      ],
    );
    session.controller.onHistoryInvalid = () =>
        actions.showError(context, LocaleKeys.screenplayHistoryInvalid);
    session.controller.onCommandError = (code) => actions.showError(
      context,
      code == 'first_scene_heading_required'
          ? LocaleKeys.screenplayFirstHeadingRequired
          : LocaleKeys.screenplaySaveFailed,
    );
    Future<bool> validate(ScreenplayDocument after) async {
      try {
        // 确认期间的外部变更使计划作废，不能用旧影响清单继续提交。
        await database.transaction(
          () => service.validateDocumentBaseline(session.baseline, after),
        );
        return true;
      } catch (_) {
        if (context.mounted) {
          actions.showError(context, LocaleKeys.screenplayStaleEdit);
        }
        return false;
      }
    }

    session.controller.confirmStructure = (before, after, expanded) async {
      final removed = before.scenes.keys
          .where((id) => !after.scenes.containsKey(id))
          .toList();
      final retained = after.sceneOrder
          .where(
            (id) =>
                before.scenes.containsKey(id) &&
                !sameScreenplayElements(
                  before.sceneElements(id),
                  after.sceneElements(id),
                ),
          )
          .toList();
      final archived = removed
          .where(
            (id) =>
                before.scenes[id]!.synopsis.isNotEmpty ||
                before.scenes[id]!.beatId != null,
          )
          .length;
      final cleared = before.evidence.entries
          .where(
            (entry) => entry.value != null && after.evidence[entry.key] == null,
          )
          .length;
      String label(String id) => context.t(
        LocaleKeys.screenplayScene,
        namedArgs: {'number': '${session.sceneNumber(id)}'},
      );
      final confirmed = await showConfirmDialog(
        context,
        title: context.t(LocaleKeys.screenplayStructureChange),
        message:
            context.t(
              LocaleKeys.screenplayStructureImpact,
              namedArgs: {
                'removed': removed.map(label).join(', '),
                'retained': retained.map(label).join(', '),
                'archived': '$archived',
                'evidence': '$cleared',
              },
            ) +
            (expanded
                ? '\n${context.t(LocaleKeys.screenplayDeleteDialogueBlock)}'
                : ''),
        variant: ConfirmDialogVariant.warning,
      );
      if (!confirmed) {
        return false;
      }
      return validate(after);
    };
    session.controller.confirmDeleteScene = (_, after, sceneId) async {
      final confirmed = await showConfirmDialog(
        context,
        title: context.t(LocaleKeys.commonDelete),
        message: context.t(
          LocaleKeys.screenplayDeleteScenePrompt,
          namedArgs: {
            'scene': context.t(
              LocaleKeys.screenplayScene,
              namedArgs: {'number': '${session.sceneNumber(sceneId)}'},
            ),
          },
        ),
        variant: ConfirmDialogVariant.warning,
      );
      return confirmed && await validate(after);
    };
    return CallbackShortcuts(
      bindings: {
        for (var index = 0; index < screenplayElementOptions.length; index++)
          SingleActivator(
            screenplayElementDigitKeys[index],
            meta: screenplayUsesMetaShortcuts,
            control: !screenplayUsesMetaShortcuts,
          ): () =>
              actions.pick(context, screenplayElementOptions[index].type),
      },
      child: Column(
        children: [
          ScreenplayDocumentToolbar(
            actions: actions,
            trailing: host.toolbarTrailingBuilder?.call(context, session),
          ),
          Expanded(child: ScreenplayTypographyScope(child: editor)),
          if (host.footerBuilder != null) host.footerBuilder!(context, session),
        ],
      ),
    );
  }
}
