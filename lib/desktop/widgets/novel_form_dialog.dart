// 职责: 桌面端作品创建/编辑表单对话框 — 新建时可切换小说/剧本且不改变布局，左栏封面与作品类型/来源小说，右栏标题、作者与折叠的「更多信息」
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/pages/novel_editor.dart
//   lib/shared/components/reveric_tags_editor.dart
//   lib/shared/models/content_kind.dart
//   lib/shared/models/novel_form_fields.dart
//   lib/shared/models/novel_form_prefill.dart
//   lib/shared/models/novel_categories.dart
//   lib/shared/models/novel_type.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   lib/third/form/flutter_hook_form.dart
//   lib/shared/utils/text_input_composing.dart
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/dialog_feedback.dart';
import '../../shared/components/reveric_button.dart';
import '../../shared/database/app_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/components/reveric_select.dart';
import '../../shared/components/reveric_surfaces.dart';
import '../../shared/components/reveric_tags_editor.dart';
import '../../shared/components/reveric_text_field.dart';
import '../../shared/models/content_kind.dart';
import '../../shared/models/novel_form_fields.dart';
import '../../shared/models/novel_form_prefill.dart';
import '../../shared/models/novel_type.dart';
import '../../shared/providers/dictionary_providers.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/novel/adapt_banner.dart';
import '../../shared/widgets/novel/category_field.dart';
import '../../shared/widgets/novel/start_banner.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/utils/storage_paths.dart';
import '../../shared/utils/text_input_composing.dart';
import '../../third/form/flutter_hook_form.dart';
import '../../shared/widgets/media_asset_image.dart';

final _log = AppLogger.forModule('NovelFormDialog');

/// 左栏宽度：封面 + 作品类型 + 来源小说共用一栏，比纯封面列宽一档才放得下两个下拉。
const double _asideWidth = 180;

/// 弹窗最大宽度：左栏 + 字段区两列刚好铺开，宽屏下不再随窗口拉满。
const double _dialogMaxWidth = 760;

typedef NovelFormSubmitter =
    Future<bool> Function({
      required String title,
      required String authorName,
      required String description,
      required String category,
      required String type,
      required String contentKind,
      required int? plannedEpisodeCount,
      required String? sourceNovelId,
      required String? coverSourcePath,
      required bool removeCover,
      required List<String> tags,
    });

class NovelFormDialog extends HookConsumerWidget {
  const NovelFormDialog.create({
    super.key,
    required this.onSubmit,
    this.initialContentKind = contentKindNovel,
    this.prefill,
    this.onQuickStart,
    this.onCreateDemoNovel,
  }) : novel = null;

  const NovelFormDialog.edit({
    super.key,
    required Novel this.novel,
    required this.onSubmit,
  }) : initialContentKind = contentKindNovel,
       prefill = null,
       onQuickStart = null,
       onCreateDemoNovel = null;

  final Novel? novel;

  /// 创建模式下的作品类型，由入口所在的库决定，表单内不可切换。编辑模式不使用。
  final String initialContentKind;

  /// 创建模式下的字段预填 — 「改编」入口据此带入原著信息。编辑模式不使用。
  final NovelFormPrefill? prefill;

  /// 表单提交回调。返回 `true` 表示成功，对话框会自动关闭；返回 `false` 表示保留对话框，
  /// 由调用方负责展示错误提示。
  final NovelFormSubmitter onSubmit;

  /// 快速开书回调。仅创建模式提供，在对话框顶部显示引导横幅：占位建书后进编辑器。
  final VoidCallback? onQuickStart;

  /// 创建演示小说回调。仅创建模式无 demo 时提供，在对话框底部显示快捷按钮。
  final VoidCallback? onCreateDemoNovel;

  bool get _isEditMode => novel != null;

  /// 编辑沿用原值；新建用入口给的类型。两种模式都不可切换。
  String get _initialContentKind =>
      novel?.contentKind ?? prefill?.contentKind ?? initialContentKind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final initialTags = useMemoized(
      () => novel?.tags ?? prefill?.tags ?? <String>[],
      [novel?.id],
    );

    final form = useForm<NovelFormField>(
      initialValues: {
        NovelFormField.title: novel?.title ?? prefill?.title ?? '',
        NovelFormField.authorName:
            novel?.authorName ?? prefill?.authorName ?? '',
        NovelFormField.description:
            novel?.description ?? prefill?.description ?? '',
        NovelFormField.category: novel?.category ?? prefill?.category ?? '',
        NovelFormField.type: novel?.type ?? prefill?.type ?? novelTypeOriginal,
        NovelFormField.contentKind: _initialContentKind,
        NovelFormField.plannedEpisodeCount: '',
        NovelFormField.sourceNovelId:
            novel?.sourceNovelId ?? prefill?.sourceNovelId,
        NovelFormField.tags: initialTags,
        // 只保存本次新选的文件；已有封面按资产显示。
        NovelFormField.coverPath: '',
      },
      keys: [novel?.id],
    );

    final contentKind = useListenableSelector(
      form,
      () =>
          form.getValue<String>(NovelFormField.contentKind) ??
          _initialContentKind,
    );
    final isScreenplay = contentKind == contentKindScreenplay;
    final removeCover = useState(false);
    final isBusy = useState(false);
    // 新建时只露标题、作者、集数；简介/分类/标签等折进「更多信息」，一屏放得下。
    // 编辑已有作品、或改编入口带来了简介/分类/标签时默认展开，避免已填内容被藏起来。
    final moreOpen = useState(_isEditMode || prefill != null);

    // 标签建议：loading 中传 null（纯自由文本），加载完成后自动补全。
    final tagSuggestions = ref.watch(novelTagsProvider).value;
    // 草稿可重名；仅书架作品用于标题重名的实时校验。
    final existingNovels = ref.watch(novelsProvider).value ?? const <Novel>[];
    final sourceNovels = existingNovels
        .where(
          (item) =>
              item.contentKind == contentKindNovel &&
              !item.draft &&
              item.id != novel?.id,
        )
        .toList();
    final novelActions = ref.read(novelActionsProvider);

    bool isTitleTaken(String title) {
      final trimmed = title.trim();
      if (trimmed.isEmpty) {
        return false;
      }
      return existingNovels.any(
        (item) => !item.draft && item.title == trimmed && item.id != novel?.id,
      );
    }

    String? titleValidator(String? value) {
      if (value == null || value.trim().isEmpty) {
        return context.t(LocaleKeys.formRequired);
      }
      // 创建成功后 novelsProvider 会先推送新作品，随后对话框才关闭。
      // 提交期间跳过实时校验，避免把刚创建的作品误判为同名作品。
      if (isBusy.value) {
        return null;
      }
      if (isTitleTaken(value)) {
        return context.t(
          LocaleKeys.libraryDuplicateName,
          namedArgs: {'name': value.trim()},
        );
      }
      return null;
    }

    // 剧本横幅选原著：按原著预填后展开「更多信息」，带入的简介和标签不被藏起来。
    void pickAdaptationSource(String? sourceId) {
      selectAdaptationSource(
        context,
        form: form,
        sourceNovels: sourceNovels,
        sourceId: sourceId,
      );
      if (sourceId != null) {
        moreOpen.value = true;
      }
    }

    Future<void> pickCover() async {
      final result = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'images',
            extensions: ['png', 'jpg', 'jpeg', 'webp'],
          ),
        ],
      );
      final path = result?.path;
      if (!context.mounted || path == null) return;
      form.updateValue(NovelFormField.coverPath, path, notify: true);
      removeCover.value = false;
    }

    Future<void> handleSubmit() async {
      if (isBusy.value) return;
      if (!form.validate()) return;

      final title = (form.getValue<String>(NovelFormField.title) ?? '').trim();
      final authorName =
          (form.getValue<String>(NovelFormField.authorName) ?? '').trim();
      final description =
          (form.getValue<String>(NovelFormField.description) ?? '').trim();
      final category = (form.getValue<String>(NovelFormField.category) ?? '')
          .trim();
      final type =
          form.getValue<String>(NovelFormField.type) ?? novelTypeOriginal;
      final contentKind =
          form.getValue<String>(NovelFormField.contentKind) ?? contentKindNovel;
      final plannedEpisodeText =
          (form.getValue<String>(NovelFormField.plannedEpisodeCount) ?? '')
              .trim();
      final plannedEpisodeCount = plannedEpisodeText.isEmpty
          ? null
          : int.tryParse(plannedEpisodeText);
      if (contentKind == contentKindScreenplay &&
          plannedEpisodeText.isNotEmpty &&
          (plannedEpisodeCount == null || plannedEpisodeCount < 1)) {
        form.setError(
          NovelFormField.plannedEpisodeCount,
          context.t(LocaleKeys.libraryPlannedEpisodeCountInvalid),
        );
        return;
      }
      final sourceNovelId = novelTypeSupportsSourceNovel(type)
          ? form.getValue<String?>(NovelFormField.sourceNovelId)
          : null;
      final allowedTypes = _isEditMode
          ? creatableNovelTypesFor(contentKind)
          : creatableNovelTypesFor(contentKind);
      final tags = form.getValue<List<String>>(NovelFormField.tags) ?? [];
      final coverPath = (form.getValue<String>(NovelFormField.coverPath) ?? '')
          .trim();

      // 提前提交中标记：创建成功后 novelsProvider 会先推送新作品，对话框
      // 关闭动画期间若清掉 isBusy，实时重名校验会把刚创建的作品误判为同名。
      isBusy.value = true;
      // 与 TXT 导入一致：写入前用 findNovelByTitle 提前拦截重名。
      final existing = await novelActions.findNovelByTitle(title);
      if (existing != null && existing.id != novel?.id) {
        if (context.mounted) {
          form.setError(
            NovelFormField.title,
            context.t(
              LocaleKeys.libraryDuplicateName,
              namedArgs: {'name': title},
            ),
          );
          isBusy.value = false;
        }
        return;
      }

      _log.info(
        'handleSubmit calling onSubmit coverPath="$coverPath" removeCover=${removeCover.value} tags=$tags',
      );
      var succeeded = false;
      try {
        final ok = await onSubmit(
          title: title,
          authorName: authorName,
          description: description,
          category: category,
          type: allowedTypes.contains(type) ? type : novelTypeOriginal,
          contentKind: contentKind,
          plannedEpisodeCount: plannedEpisodeCount,
          sourceNovelId: sourceNovelId,
          coverSourcePath: coverPath.isEmpty ? null : coverPath,
          removeCover: removeCover.value,
          tags: tags,
        );
        _log.info('onSubmit returned ok=$ok');
        if (!context.mounted) {
          _log.info('context not mounted after onSubmit');
          return;
        }
        if (ok) {
          succeeded = true;
          if (_isEditMode) {
            _log.info('closing dialog via pop (edit mode)');
            Navigator.of(context, rootNavigator: true).pop();
          }
          return;
        }
        _log.info('onSubmit returned false, keeping dialog open');
      } finally {
        // 成功路径保持 isBusy，避免关闭过程中 titleValidator 误报同名。
        if (context.mounted && !succeeded) {
          isBusy.value = false;
        }
      }
    }

    final coverPath = removeCover.value
        ? null
        : (form.getValue<String>(NovelFormField.coverPath) ?? '').trim();
    final currentCover = watchMediaAssetFile(ref, novel?.coverAssetId);
    final effectiveCoverPath = coverPath == null
        ? null
        : coverPath.isNotEmpty
        ? coverPath
        : currentCover;

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
      ),
      insetPadding: const EdgeInsets.all(RevericSpacing.x2l),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
        child: DialogFeedback.surface(
          builder: (context) => HookedForm<NovelFormField>(
            form: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DialogHeader(
                  title: context.t(
                    _isEditMode
                        ? LocaleKeys.libraryEditWorkInfo
                        : isScreenplay
                        ? LocaleKeys.libraryCreateScreenplay
                        : LocaleKeys.libraryCreateNovel,
                  ),
                  onClose: isBusy.value
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(RevericSpacing.x3l),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 同一个横幅槽位：小说是快速开书（占位建书只走小说内容库），
                        // 剧本是从小说改编。切换类型只换内容，高度不变。
                        // 改编横幅不依赖快速开书，从小说概览发起的改编也要显示已选原著。
                        if (!_isEditMode &&
                            (isScreenplay || onQuickStart != null)) ...[
                          isScreenplay
                              ? NovelAdaptBanner(
                                  picker: _AdaptSourcePicker(
                                    form: form,
                                    sourceNovels: sourceNovels,
                                    enabled: !isBusy.value,
                                    onChanged: pickAdaptationSource,
                                  ),
                                )
                              : NovelStartBanner(
                                  icon: RevericIcons.auto_awesome,
                                  title: context.t(
                                    LocaleKeys.libraryQuickStart,
                                  ),
                                  hint: context.t(
                                    LocaleKeys.libraryQuickStartHint,
                                  ),
                                  onTap: isBusy.value ? null : onQuickStart,
                                ),
                          const SizedBox(height: RevericSpacing.x3l),
                        ],
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final fields = _buildDetailsFields(
                              context: context,
                              isScreenplay: isScreenplay,
                              form: form,
                              colors: colors,
                              typo: typo,
                              tagSuggestions: tagSuggestions,
                              titleValidator: titleValidator,
                              moreOpen: moreOpen,
                            );
                            final aside = _buildAsideColumn(
                              context: context,
                              contentKind: contentKind,
                              form: form,
                              sourceNovels: sourceNovels,
                              moreOpen: moreOpen,
                              cover: _buildCoverSection(
                                context: context,
                                effectiveCoverPath: effectiveCoverPath,
                                isBusy: isBusy.value,
                                onPickCover: pickCover,
                                onRemoveCover: () {
                                  removeCover.value = true;
                                  form.updateValue(
                                    NovelFormField.coverPath,
                                    '',
                                    notify: true,
                                  );
                                },
                              ),
                            );

                            if (constraints.maxWidth < 560) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: aside,
                                  ),
                                  const SizedBox(height: RevericSpacing.x3l),
                                  fields,
                                ],
                              );
                            }

                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                aside,
                                const SizedBox(width: RevericSpacing.x4l),
                                Expanded(child: fields),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                _DialogFooter(
                  children: [
                    RevericButton.text(
                      onPressed: isBusy.value
                          ? null
                          : () => Navigator.of(context).pop(),
                      label: context.t(LocaleKeys.commonCancel),
                    ),
                    if (onCreateDemoNovel != null) ...[
                      const Spacer(),
                      RevericButton.secondary(
                        onPressed: isBusy.value ? null : onCreateDemoNovel,
                        icon: RevericIcons.auto_awesome,
                        label: context.t(LocaleKeys.libraryCreateDemoNovel),
                      ),
                    ],
                    const SizedBox(width: RevericSpacing.sm),
                    RevericButton.primary(
                      onPressed: handleSubmit,
                      loading: isBusy.value,
                      label: context.t(
                        _isEditMode
                            ? LocaleKeys.commonSave
                            : LocaleKeys.commonCreate,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 左栏：封面 + 作品类型 + 来源小说。类型和来源同属「更多信息」，跟着一起折叠 —
  /// 否则收起态左栏会比右栏高出一大截，把封面下方的留白换个方向重现一遍。
  Widget _buildAsideColumn({
    required BuildContext context,
    required String contentKind,
    required FormFieldsController<NovelFormField> form,
    required List<Novel> sourceNovels,
    required ValueNotifier<bool> moreOpen,
    required Widget cover,
  }) {
    return SizedBox(
      width: _asideWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cover,
          if (moreOpen.value) ...[
            const SizedBox(height: RevericSpacing.x2l),
            _buildTypeField(
              context: context,
              form: form,
              types: _isEditMode
                  ? creatableNovelTypesFor(contentKind)
                  : creatableNovelTypesFor(contentKind),
            ),
            _buildSourceNovelField(
              context: context,
              form: form,
              sourceNovels: sourceNovels,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailsFields({
    required BuildContext context,
    required bool isScreenplay,
    required FormFieldsController<NovelFormField> form,
    required RevericColors colors,
    required RevericTypography typo,
    required List<String>? tagSuggestions,
    required String? Function(String?) titleValidator,
    required ValueNotifier<bool> moreOpen,
  }) {
    final authorField = _buildInputField(
      label: context.t(LocaleKeys.libraryAuthorName),
      fieldHook: NovelFormField.authorName,
      textInputAction: TextInputAction.next,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _LabeledField(
          label: context.t(LocaleKeys.libraryWorkName),
          isRequired: true,
          child: _buildInputField(
            fieldHook: NovelFormField.title,
            autofocus: true,
            textInputAction: TextInputAction.next,
            validator: titleValidator,
          ),
        ),
        const SizedBox(height: RevericSpacing.x2l),
        // 计划集数只在新建剧本时出现，与作者名并排，避免主区被拉长。
        // 始终是同一个 Row，作者名留在第一个槽位，切换类型时输入框不重建。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: authorField),
            if (isScreenplay && !_isEditMode) ...[
              const SizedBox(width: RevericSpacing.lg),
              Expanded(
                child: _buildInputField(
                  label: context.t(LocaleKeys.libraryPlannedEpisodeCount),
                  fieldHook: NovelFormField.plannedEpisodeCount,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: RevericSpacing.md),
        _MoreInfoToggle(
          isOpen: moreOpen.value,
          onToggle: () => moreOpen.value = !moreOpen.value,
        ),
        if (moreOpen.value) ...[
          const SizedBox(height: RevericSpacing.x2l),
          _buildInputField(
            label: context.t(LocaleKeys.libraryDescription),
            fieldHook: NovelFormField.description,
            minLines: 3,
            maxLines: 5,
            keyboardType: TextInputType.multiline,
          ),
          const SizedBox(height: RevericSpacing.x2l),
          NovelCategoryField(fieldHook: NovelFormField.category),
          const SizedBox(height: RevericSpacing.x2l),
          _buildTagsEditor(
            context: context,
            form: form,
            tagSuggestions: tagSuggestions,
          ),
        ],
      ],
    );
  }

  Widget _buildSourceNovelField({
    required BuildContext context,
    required FormFieldsController<NovelFormField> form,
    required List<Novel> sourceNovels,
  }) {
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        final type =
            form.getValue<String>(NovelFormField.type) ?? novelTypeOriginal;
        final labelKey = sourceNovelLabelKey(type);
        // 新建改编剧本的原著由顶部横幅选择，这里不再重复一份。
        if (labelKey == null || (!_isEditMode && type == novelTypeAdaptation)) {
          return const SizedBox.shrink();
        }
        // 标题和空值文案都跟着类型走：「改编自小说 / 未选择原著」比通用说法讲得清关系。
        final noneLabel = context.t(sourceNovelNoneKey(type));
        return Padding(
          padding: const EdgeInsets.only(top: RevericSpacing.x2l),
          child: HookedFormField<NovelFormField, String?>(
            fieldHook: NovelFormField.sourceNovelId,
            notifyOnChange: true,
            builder: (sourceId, onSourceChanged, sourceError) {
              return RevericSelect<String?>(
                label: context.t(labelKey),
                value: sourceId,
                placeholder: noneLabel,
                items: [
                  RevericSelectItem<String?>(value: null, label: noneLabel),
                  for (final source in sourceNovels)
                    RevericSelectItem<String?>(
                      value: source.id,
                      label: source.title,
                    ),
                ],
                onChanged: (id) => onSourceChanged?.call(id),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTypeField({
    required BuildContext context,
    required FormFieldsController<NovelFormField> form,
    required List<String> types,
  }) {
    return HookedFormField<NovelFormField, String>(
      fieldHook: NovelFormField.type,
      notifyOnChange: true,
      builder: (value, onChanged, error) {
        final selected = value ?? novelTypeOriginal;
        return RevericSelect<String>(
          label: context.t(LocaleKeys.libraryNovelType),
          leadingIcon: RevericIcons.book,
          value: types.contains(selected) ? selected : novelTypeOriginal,
          items: [
            for (final type in types)
              RevericSelectItem<String>(
                value: type,
                label: _novelTypeLabel(context, type),
              ),
          ],
          onChanged: (type) {
            onChanged?.call(type);
            if (!novelTypeSupportsSourceNovel(type)) {
              form.updateValue<String?>(NovelFormField.sourceNovelId, null);
            }
          },
        );
      },
    );
  }

  /// [label] 为空时不渲染内置标签，由外层 [_LabeledField] 负责（例如带「必填」标记的标题）。
  Widget _buildInputField({
    String? label,
    required NovelFormField fieldHook,
    String? Function(String?)? validator,
    bool autofocus = false,
    int? minLines,
    int? maxLines,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
  }) {
    return _HookedRevericTextField(
      fieldHook: fieldHook,
      label: label,
      autofocus: autofocus,
      validator: validator,
      multiline: minLines != null || maxLines != null,
      minLines: minLines ?? 4,
      maxLines: maxLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
    );
  }

  Widget _buildTagsEditor({
    required BuildContext context,
    required FormFieldsController<NovelFormField> form,
    required List<String>? tagSuggestions,
  }) {
    return _LabeledField(
      label: context.t(LocaleKeys.libraryTagsLabel),
      child: HookedFormField<NovelFormField, List<String>>(
        fieldHook: NovelFormField.tags,
        notifyOnChange: true,
        builder: (tags, onChanged, error) {
          final currentTags = tags ?? <String>[];
          return RevericTagsEditor(
            tags: currentTags,
            onChanged: (updated) {
              form.updateValue(NovelFormField.tags, updated, notify: true);
            },
            addLabel: context.t(LocaleKeys.libraryAddTag),
            hintText: context.t(LocaleKeys.libraryTagHint),
            suggestions: tagSuggestions,
          );
        },
      ),
    );
  }

  Widget _buildCoverSection({
    required BuildContext context,
    required String? effectiveCoverPath,
    required bool isBusy,
    required VoidCallback onPickCover,
    required VoidCallback onRemoveCover,
  }) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final resolvedCoverPath = RevericPaths.resolveStored(effectiveCoverPath);
    final coverFile = resolvedCoverPath == null
        ? null
        : File(resolvedCoverPath);
    final hasCover = coverFile != null;

    // 宽度由左栏 [_asideWidth] 决定，封面在其中撑满；高度按 5:7 的书封比例。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.commonCover),
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: RevericSpacing.xs),
        RevericElevatedCard(
          width: double.infinity,
          height: _asideWidth * 7 / 5,
          fallback: colors.surfaceDim,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          clipBehavior: Clip.antiAlias,
          image: hasCover
              ? DecorationImage(image: FileImage(coverFile), fit: BoxFit.cover)
              : null,
          child: hasCover
              ? const SizedBox.expand()
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RevericIcon(
                        RevericIcons.image_outlined,
                        size: 24,
                        color: colors.textSubtle,
                      ),
                      const SizedBox(height: RevericSpacing.sm),
                      Text(
                        context.t(LocaleKeys.commonNoCoverSelected),
                        style: typo.uiSmall.copyWith(color: colors.textSubtle),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: RevericSpacing.md),
        SizedBox(
          width: double.infinity,
          child: RevericButton.secondary(
            onPressed: isBusy ? null : onPickCover,
            icon: RevericIcons.image,
            label: hasCover
                ? context.t(LocaleKeys.editorReplaceCover)
                : context.t(LocaleKeys.librarySelectCover),
          ),
        ),
        if (_isEditMode) ...[
          const SizedBox(height: RevericSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: RevericButton.secondary(
              onPressed: isBusy || !hasCover ? null : onRemoveCover,
              icon: RevericIcons.close,
              label: context.t(LocaleKeys.editorRemoveCover),
            ),
          ),
        ],
      ],
    );
  }
}

class _HookedRevericTextField extends StatelessWidget {
  const _HookedRevericTextField({
    required this.fieldHook,
    this.label,
    this.validator,
    this.autofocus = false,
    this.multiline = false,
    this.minLines = 4,
    this.maxLines,
    this.keyboardType,
    this.textInputAction,
  });

  final NovelFormField fieldHook;
  final String? label;
  final String? Function(String?)? validator;
  final bool autofocus;
  final bool multiline;
  final int minLines;
  final int? maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    return HookedFormField<NovelFormField, String>(
      fieldHook: fieldHook,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: validator,
      builder: (value, onChanged, error) {
        return _RevericFormTextField(
          value: value ?? '',
          label: label,
          errorText: error,
          autofocus: autofocus,
          multiline: multiline,
          minLines: minLines,
          maxLines: maxLines,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onChanged: (next) => onChanged?.call(next),
        );
      },
    );
  }
}

class _RevericFormTextField extends HookWidget {
  const _RevericFormTextField({
    required this.value,
    required this.onChanged,
    this.label,
    this.errorText,
    this.autofocus = false,
    this.multiline = false,
    this.minLines = 4,
    this.maxLines,
    this.keyboardType,
    this.textInputAction,
  });

  final String value;
  final String? label;
  final ValueChanged<String> onChanged;
  final String? errorText;
  final bool autofocus;
  final bool multiline;
  final int minLines;
  final int? maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: value);

    useEffect(() {
      if (controller.text != value) {
        // 裸赋值会把 composing 清空，等于告诉平台组词结束，正在输入的拼音会被丢掉。
        writeControllerTextAfterComposing(controller, (_) => value);
      }
      return null;
    }, [value]);

    return RevericTextField(
      controller: controller,
      label: label,
      errorText: errorText,
      autofocus: autofocus,
      multiline: multiline,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: onChanged,
    );
  }
}

/// 对话框标题栏：标题 + 关闭按钮，底部分割线与内容区分离。
class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x3l,
        RevericSpacing.x2l,
        RevericSpacing.lg,
        RevericSpacing.x2l,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: colors.borderSubtle,
            width: RevericSizes.dividerThickness,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: typo.heading2.copyWith(color: colors.textPrimary),
            ),
          ),
          IconButton(
            onPressed: onClose,
            tooltip: context.t(LocaleKeys.commonClose),
            visualDensity: VisualDensity.compact,
            icon: RevericIcon(
              RevericIcons.close,
              size: 16,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// 对话框底部操作栏：顶部分割线 + 右对齐动作按钮。
class _DialogFooter extends StatelessWidget {
  const _DialogFooter({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x3l,
        vertical: RevericSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: colors.borderSubtle,
            width: RevericSizes.dividerThickness,
          ),
        ),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: children),
    );
  }
}

/// 带可选「必填」标记的字段标签容器，样式对齐 [RevericTextField] 的内置标签。
class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.child,
    this.isRequired = false,
  });

  final String label;
  final Widget child;
  final bool isRequired;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final labelRow = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          label,
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
        if (isRequired) ...[
          const SizedBox(width: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.commonRequired),
            // 用 accent 会被读成可点的链接，这里只是个静态标记。
            style: typo.uiTiny.copyWith(color: colors.textSubtle),
          ),
        ],
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        labelRow,
        const SizedBox(height: RevericSpacing.xs),
        child,
      ],
    );
  }
}

/// 「更多信息」折叠开关：收起时只保留标题、作者等必要字段，避免一屏塞满。
class _MoreInfoToggle extends StatelessWidget {
  const _MoreInfoToggle({required this.isOpen, required this.onToggle});

  final bool isOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.sm,
            vertical: RevericSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedRotation(
                turns: isOpen ? 0.25 : 0,
                duration: const Duration(milliseconds: 160),
                child: RevericIcon(
                  RevericIcons.caret_right,
                  size: 14,
                  color: colors.textMuted,
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.libraryMoreInfo),
                style: typo.uiSmallSemibold.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.libraryMoreInfoHint),
                style: typo.uiTiny.copyWith(color: colors.textSubtle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 创建对话框顶部的「快速开书」引导横幅：面向只有模糊想法、还没想好书名的用户。
String _novelTypeLabel(BuildContext context, String type) {
  return switch (type) {
    novelTypeOriginal => context.t(LocaleKeys.libraryNovelTypeOriginal),
    novelTypeAdaptation => context.t(LocaleKeys.libraryNovelTypeAdaptation),
    novelTypeSequel => context.t(LocaleKeys.libraryNovelTypeSequel),
    novelTypeFanfic => context.t(LocaleKeys.libraryNovelTypeFanfic),
    novelTypeDerivative => context.t(LocaleKeys.libraryNovelTypeDerivative),
    novelTypeMaterial => context.t(LocaleKeys.libraryNovelTypeMaterial),
    _ => type,
  };
}

/// 改编横幅里的原著下拉。只读写表单值、不注册字段：左栏的来源小说字段占用同一个
/// 字段 key，两边同时挂载时注册会冲突。
class _AdaptSourcePicker extends StatelessWidget {
  const _AdaptSourcePicker({
    required this.form,
    required this.sourceNovels,
    required this.enabled,
    required this.onChanged,
  });

  final FormFieldsController<NovelFormField> form;
  final List<Novel> sourceNovels;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final noneLabel = context.t(LocaleKeys.librarySourceNovelNoneAdaptation);
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        // 续作、同人等也会带来源小说；横幅只表达「改编自哪本」。
        final isAdaptation =
            form.getValue<String>(NovelFormField.type) == novelTypeAdaptation;
        final sourceId = isAdaptation
            ? form.getValue<String?>(NovelFormField.sourceNovelId)
            : null;
        return RevericSelect<String?>(
          value: sourceId,
          enabled: enabled && sourceNovels.isNotEmpty,
          placeholder: sourceNovels.isEmpty
              ? context.t(LocaleKeys.libraryAdaptNoSourceNovels)
              : noneLabel,
          // 空书架不放「未选择」项：它的值也是 null，会顶掉空书架占位。
          items: [
            if (sourceNovels.isNotEmpty)
              RevericSelectItem<String?>(value: null, label: noneLabel),
            for (final source in sourceNovels)
              RevericSelectItem<String?>(value: source.id, label: source.title),
          ],
          onChanged: onChanged,
        );
      },
    );
  }
}
