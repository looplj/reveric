// 职责: 为双端场次入口加载同一编辑会话并展示场次属性表单。
// 关联文件:
//   lib/shared/widgets/screenplay/scene_properties_form.dart
//   lib/shared/widgets/screenplay/document_session.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/screenplay_document.dart';
import '../../providers/novel_providers.dart';
import '../../providers/screenplay_providers.dart';
import '../../theme/theme.dart';
import 'document_session.dart';
import 'scene_properties_form.dart';

Future<void> showSceneProperties(
  BuildContext context, {
  required String databasePath,
  required String novelId,
  required String sceneId,
  required String episodeId,
  bool mobile = false,
  ScreenplayDocumentSession? session,
}) {
  final content = ScreenplaySceneProperties(
    novelId: novelId,
    databasePath: databasePath,
    sceneId: sceneId,
    episodeId: episodeId,
    session: session,
  );
  if (mobile) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .78,
      ),
      builder: (_) => content,
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(child: SizedBox(width: 640, child: content)),
  );
}

class ScreenplaySceneProperties extends HookConsumerWidget {
  const ScreenplaySceneProperties({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.sceneId,
    required this.episodeId,
    this.session,
  });
  final String databasePath;
  final String novelId;
  final String sceneId;
  final String episodeId;
  final ScreenplayDocumentSession? session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(
      screenplayServiceProvider(databasePath, novelId: novelId),
    );
    final future = useMemoized(
      () => session == null
          ? service.readDocument(episodeId, sceneIds: {sceneId})
          : Future.value(session!.controller.screenplay!),
      [databasePath, novelId, sceneId, episodeId, session],
    );
    final snapshot = useFuture(future);
    if (!snapshot.hasData) {
      return Padding(
        padding: const EdgeInsets.all(RevericSpacing.x2l),
        child: snapshot.hasError
            ? Text(context.t(LocaleKeys.screenplaySaveFailed))
            : const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              ),
      );
    }
    return _LoadedProperties(
      novelId: novelId,
      databasePath: databasePath,
      sceneId: sceneId,
      document: snapshot.data!,
      session: session,
    );
  }
}

class _LoadedProperties extends HookConsumerWidget {
  const _LoadedProperties({
    required this.databasePath,
    required this.novelId,
    required this.sceneId,
    required this.document,
    this.session,
  });
  final String databasePath;
  final String novelId;
  final String sceneId;
  final ScreenplayDocument document;
  final ScreenplayDocumentSession? session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final database = ref.watch(novelContentDatabaseProvider(databasePath));
    final service = ref.watch(
      screenplayServiceProvider(databasePath, novelId: novelId),
    );
    final overlay = ref.watch(
      workOverlayServiceProvider((path: databasePath, novelId: novelId)),
    );
    final editing = useMemoized(
      () =>
          session ??
          ScreenplayDocumentSession(
            document,
            database: database,
            service: service,
            overlay: overlay,
          ),
      [session, sceneId],
    );
    useEffect(() => session == null ? editing.dispose : null, [
      editing,
      session,
    ]);
    return ScenePropertiesForm(
      databasePath: databasePath,
      sceneId: sceneId,
      session: editing,
    );
  }
}
