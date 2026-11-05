// 职责: 提交集合的新建和重命名，并在失败时保留名称供重试。
// 关联文件:
//   lib/shared/widgets/collections/surface.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_text_field.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/novel_collection.dart';
import '../../providers/novel_providers.dart';
import 'surface.dart';

Future<String?> showCollectionName(
  BuildContext context, {
  required bool mobile,
  LibraryCollection? collection,
  String? contentKind,
  Set<String> workIds = const {},
}) {
  assert(
    collection != null || contentKind != null,
    'New collections need the content kind of their library',
  );
  return showCollectionSurface<String>(
    context,
    mobile: mobile,
    builder: (_) => _NameForm(
      mobile: mobile,
      collection: collection,
      contentKind: contentKind,
      workIds: workIds,
    ),
  );
}

class _NameForm extends HookConsumerWidget {
  const _NameForm({
    required this.mobile,
    this.collection,
    this.contentKind,
    required this.workIds,
  });
  final bool mobile;

  /// 传入时为重命名；否则新建一个 [contentKind] 类型的集合。
  final LibraryCollection? collection;
  final String? contentKind;
  final Set<String> workIds;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController(text: collection?.name ?? '');
    final busy = useState(false);
    final error = useState<String?>(null);
    Future<void> submit() async {
      if (busy.value) {
        return;
      }
      final name = controller.text.trim();
      if (name.isEmpty) {
        error.value = context.t(LocaleKeys.libraryCollectionNameRequired);
        return;
      }
      busy.value = true;
      error.value = null;
      final dao = ref.read(appDatabaseProvider).novelCollectionDao;
      try {
        final String id;
        if (collection case final existing?) {
          await dao.rename(existing.id, name);
          id = existing.id;
        } else {
          id = await dao.create(
            name: name,
            contentKind: contentKind!,
            workIds: workIds,
          );
        }
        if (context.mounted) {
          Navigator.of(context).pop(id);
        }
      } catch (_) {
        if (context.mounted) {
          error.value = context.t(LocaleKeys.libraryCollectionFailed);
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    return PopScope(
      canPop: !busy.value,
      child: CollectionSurface(
        mobile: mobile,
        title: context.t(
          collection == null
              ? LocaleKeys.commonCreate
              : LocaleKeys.commonRename,
        ),
        actions: [
          RevericButton.secondary(
            label: context.t(LocaleKeys.commonCancel),
            onPressed: busy.value ? null : () => Navigator.of(context).pop(),
          ),
          RevericButton.primary(
            label: context.t(LocaleKeys.commonSave),
            loading: busy.value,
            onPressed: submit,
          ),
        ],
        child: SingleChildScrollView(
          child: RevericTextField(
            controller: controller,
            label: context.t(LocaleKeys.libraryCollectionName),
            errorText: error.value,
            autofocus: true,
            enabled: !busy.value,
            onSubmitted: (_) => submit(),
          ),
        ),
      ),
    );
  }
}
