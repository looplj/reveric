// 职责: 移动端新建/编辑作品页 — 新建时可切换小说/剧本且不改变布局，标题/作者名/简介/类型/分类/标签/封面表单，提交后进入新作品编辑器或返回。
// 关联文件:
//   lib/shared/services/novel_actions.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/models/content_kind.dart
//   lib/shared/models/novel_form_fields.dart
//   lib/shared/models/novel_form_prefill.dart
//   lib/shared/models/novel_type.dart
//   lib/shared/models/novel_categories.dart
//   lib/shared/components/reveric_input_decoration.dart
//   lib/shared/utils/storage_paths.dart
//   lib/mobile/pages/novel_editor_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/form.json
//   assets/translations/zh-CN/form.json
// 遵循的 Rules:
//   .agents/rules/form.md
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../shared/components/reveric_button.dart';
import '../../shared/components/reveric_segmented_control.dart';
import '../../shared/widgets/novel/adapt_banner.dart';
import '../../shared/widgets/novel/start_banner.dart';
import '../../shared/components/reveric_input_decoration.dart';
import '../../shared/form/form.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/widgets/quick_start_idea.dart';
import '../../shared/models/content_kind.dart';
import '../../shared/models/novel.dart';
import '../../shared/models/novel_form_fields.dart';
import '../../shared/models/novel_form_prefill.dart';
import '../../shared/models/novel_type.dart';
import '../../shared/providers/dictionary_providers.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/services/novel_actions.dart'
    show NovelTitleConflictException;
import '../../shared/theme/theme.dart';
import '../../shared/widgets/novel/category_field.dart';
import '../../shared/utils/storage_paths.dart';
import 'workspace_editor_page.dart';
import '../../shared/widgets/media_asset_image.dart';

final _log = AppLogger.forModule('MobileNovelCreate');

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

/// 从一本小说出发新建改编剧本：类型、来源与原著信息预填，其余交给用户确认。
void openNovelAdaptation(BuildContext context, Novel novel) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileNovelCreatePage(
        contentKind: contentKindScreenplay,
        prefill: NovelFormPrefill.adaptationOf(
          novel,
          title: context.t(
            LocaleKeys.libraryAdaptationTitle,
            namedArgs: {'title': novel.title},
          ),
        ),
      ),
    ),
  );
}

class MobileNovelCreatePage extends HookConsumerWidget {
  const MobileNovelCreatePage({
    super.key,
    this.existingNovel,
    this.contentKind = contentKindNovel,
    this.prefill,
  });

  /// 新建作品的初始类型，由入口决定（作品页类型筛选、改编），页面顶部可再切换。
  /// 编辑模式沿用原作品的类型，不可切换。
  final String contentKind;

  /// 传入已有作品时进入编辑模式；为 null 时为新建模式。
  final Novel? existingNovel;

  /// 新建模式下的字段预填 — 「改编」入口据此带入原著信息。编辑模式不使用。
  final NovelFormPrefill? prefill;

  bool get _isEditMode => existingNovel != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final novel = existingNovel;

    final prefill = this.prefill;
    final form = useForm<NovelFormField>(
      initialValues: {
        NovelFormField.title: novel?.title ?? prefill?.title ?? '',
        NovelFormField.authorName:
            novel?.authorName ?? prefill?.authorName ?? '',
        NovelFormField.description:
            novel?.description ?? prefill?.description ?? '',
        NovelFormField.category: novel?.category ?? prefill?.category ?? '',
        NovelFormField.type: novel?.type ?? prefill?.type ?? novelTypeOriginal,
        NovelFormField.contentKind:
            novel?.contentKind ?? prefill?.contentKind ?? contentKind,
        NovelFormField.plannedEpisodeCount: '',
        NovelFormField.sourceNovelId:
            novel?.sourceNovelId ?? prefill?.sourceNovelId,
        NovelFormField.tags: novel?.tags ?? prefill?.tags ?? <String>[],
        // 只保存本次新选的文件；已有封面按资产显示。
        NovelFormField.coverPath: '',
      },
      keys: [novel?.id],
    );
    // 取表单当前值而非入口值：新建模式下可在顶部切换小说 / 剧本。
    final currentKind = useListenableSelector(
      form,
      () =>
          form.getValue<String>(NovelFormField.contentKind) ?? contentKindNovel,
    );
    final isScreenplay = currentKind == contentKindScreenplay;
    final isBusy = useState(false);
    final removeCover = useState(false);
    final pickingCover = useState(false);
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
      // 提交期间跳过实时校验，避免把刚创建的作品误判为同名。
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

    Future<void> pickCover() async {
      if (!context.mounted || pickingCover.value) {
        return;
      }
      pickingCover.value = true;
      try {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
        );
        if (!context.mounted || picked == null) {
          return;
        }
        form.updateValue(NovelFormField.coverPath, picked.path, notify: true);
        removeCover.value = false;
      } catch (error, stackTrace) {
        _log.error(
          'Cover selection failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      } finally {
        if (context.mounted) {
          pickingCover.value = false;
        }
      }
    }

    Future<void> submit() async {
      if (isBusy.value || !form.validate()) {
        return;
      }
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
      final tags = form.getValue<List<String>>(NovelFormField.tags) ?? const [];
      final coverPath = (form.getValue<String>(NovelFormField.coverPath) ?? '')
          .trim();

      // 提前提交中标记：创建成功后 novelsProvider 会先推送新作品，页面
      // 跳转前若清掉 isBusy，实时重名校验会把刚创建的作品误判为同名。
      isBusy.value = true;
      var succeeded = false;
      try {
        // 与 TXT 导入一致：写入前用 findNovelByTitle 提前拦截重名。
        final novelActions = ref.read(novelActionsProvider);
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
          }
          return;
        }

        if (_isEditMode && novel != null) {
          await novelActions.updateNovel(
            novel: novel,
            title: title,
            authorName: authorName,
            description: description,
            coverSourcePath: coverPath.isEmpty ? null : coverPath,
            removeCover: removeCover.value,
            tags: tags,
            category: category,
            type: allowedTypes.contains(type) ? type : novelTypeOriginal,
            updateSourceNovel: true,
            sourceNovelId: sourceNovelId,
          );
          if (!context.mounted) {
            return;
          }
          succeeded = true;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaved))),
          );
          Navigator.of(context).pop();
        } else {
          final id = await novelActions.createNovel(
            title: title,
            authorName: authorName,
            description: description,
            coverSourcePath: coverPath.isEmpty ? null : coverPath,
            tags: tags,
            category: category,
            type: novelTypes.contains(type) ? type : novelTypeOriginal,
            contentKind: contentKind,
            sourceNovelId: sourceNovelId,
            plannedEpisodeCount: plannedEpisodeCount,
          );
          final created = await novelActions.getNovel(id);
          if (!context.mounted) {
            return;
          }
          if (created == null) {
            _showError(context);
            return;
          }
          succeeded = true;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => MobileWorkspaceEditorPage(
                novel: created,
                openChatOnEntry: created.contentKind == contentKindNovel,
              ),
            ),
          );
        }
      } on NovelTitleConflictException catch (error) {
        if (context.mounted) {
          form.setError(
            NovelFormField.title,
            context.t(
              LocaleKeys.libraryDuplicateName,
              namedArgs: {'name': error.title},
            ),
          );
        }
      } catch (_) {
        // service 已记录 [DB] 详情；UI 仅提示通用失败，不透出底层异常。
        if (context.mounted) {
          _showError(context);
        }
      } finally {
        // 成功路径保持 isBusy，避免跳转过程中 titleValidator 误报同名。
        if (context.mounted && !succeeded) {
          isBusy.value = false;
        }
      }
    }

    Future<void> quickStart() async {
      if (isBusy.value) {
        return;
      }

      final idea = await showQuickStartIdea(context, mobile: true);
      if (!context.mounted || idea == null) {
        return;
      }
      final kickoffPrompt = buildQuickStartKickoffPrompt(idea);
      isBusy.value = true;
      try {
        final novelActions = ref.read(novelActionsProvider);
        final id = await novelActions.createQuickStartNovel(
          untitledTitle: context.t(LocaleKeys.libraryUntitledNovel),
        );
        final created = await novelActions.getNovel(id);
        if (!context.mounted) {
          return;
        }
        if (created == null) {
          _showError(context);
          isBusy.value = false;
          return;
        }
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => MobileWorkspaceEditorPage(
              novel: created,
              initialChatKickoffPrompt: kickoffPrompt,
            ),
          ),
        );
      } catch (_) {
        if (context.mounted) {
          _showError(context);
          isBusy.value = false;
        }
      }
    }

    // 换类型只换内容不增删槽位；改编等类型不属于小说时回到原创。
    void changeContentKind(String next) {
      form.updateValue(NovelFormField.contentKind, next, notify: true);
      final type =
          form.getValue<String>(NovelFormField.type) ?? novelTypeOriginal;
      if (!creatableNovelTypesFor(next).contains(type)) {
        form.updateValue(NovelFormField.type, novelTypeOriginal, notify: true);
      }
    }

    void pickAdaptationSource(String? sourceId) {
      selectAdaptationSource(
        context,
        form: form,
        sourceNovels: sourceNovels,
        sourceId: sourceId,
      );
    }

    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: RevericIcon(
            RevericIcons.arrow_back,
            size: 22,
            color: colors.textSecondary,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          _isEditMode
              ? context.t(LocaleKeys.libraryEditWorkInfo)
              : context.t(LocaleKeys.libraryCreateWork),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        actions: [
          RevericButton.text(
            onPressed: submit,
            loading: isBusy.value,
            label: context.t(
              _isEditMode ? LocaleKeys.commonSave : LocaleKeys.commonCreate,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: HookedForm<NovelFormField>(
          form: form,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x3l,
              RevericSpacing.lg,
              RevericSpacing.x3l,
              RevericSpacing.x6l,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 类型切换和横幅的槽位在新建模式下固定存在，切换只换内容：
                // 下方表单项都带 form.fieldKey 的 GlobalKey，增删子节点会让它们整体
                // 位移并触发 element move，EditableText 内的 OverlayPortal 会因此撞
                // traversalParentIdentifier。
                if (!_isEditMode) ...[
                  RevericSegmentedControl<String>(
                    selected: currentKind,
                    onChanged: isBusy.value ? (_) {} : changeContentKind,
                    segments: [
                      RevericSegment(
                        value: contentKindNovel,
                        label: context.t(LocaleKeys.libraryContentKindNovel),
                      ),
                      RevericSegment(
                        value: contentKindScreenplay,
                        label: context.t(
                          LocaleKeys.libraryContentKindScreenplay,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: RevericSpacing.x2l),
                  // 快速开书只建小说（占位建书走小说内容库）；剧本换成从小说改编。
                  isScreenplay
                      ? NovelAdaptBanner(
                          picker: ListenableBuilder(
                            listenable: form,
                            builder: (context, _) {
                              // 续作、同人等也会带来源小说；横幅只表达「改编自哪本」。
                              final isAdaptation =
                                  form.getValue<String>(NovelFormField.type) ==
                                  novelTypeAdaptation;
                              return _MobileSourceNovelPicker(
                                sourceNovels: sourceNovels,
                                selectedId: isAdaptation
                                    ? form.getValue<String?>(
                                        NovelFormField.sourceNovelId,
                                      )
                                    : null,
                                noneLabel: context.t(
                                  LocaleKeys.librarySourceNovelNoneAdaptation,
                                ),
                                emptyLabel: context.t(
                                  LocaleKeys.libraryAdaptNoSourceNovels,
                                ),
                                onChanged: isBusy.value
                                    ? null
                                    : pickAdaptationSource,
                              );
                            },
                          ),
                        )
                      : NovelStartBanner(
                          icon: RevericIcons.auto_awesome,
                          title: context.t(LocaleKeys.libraryQuickStart),
                          hint: context.t(LocaleKeys.libraryQuickStartHint),
                          onTap: isBusy.value ? null : quickStart,
                        ),
                  const SizedBox(height: RevericSpacing.x2l),
                ],
                _CoverField(
                  form: form,
                  currentCoverAssetId: novel?.coverAssetId,
                  onPick: pickingCover.value ? null : pickCover,
                  removeCover: removeCover,
                ),
                const SizedBox(height: RevericSpacing.x2l),
                HookedTextFormField<NovelFormField>(
                  fieldHook: NovelFormField.title,
                  label: context.t(LocaleKeys.libraryWorkName),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  textInputAction: TextInputAction.next,
                  validator: titleValidator,
                ),
                const SizedBox(height: RevericSpacing.xl),
                // 计划集数和作者名并排，作者名始终在第一个槽位：
                // 切换类型只在行尾增删集数，下方字段不位移。
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: HookedTextFormField<NovelFormField>(
                        fieldHook: NovelFormField.authorName,
                        label: context.t(LocaleKeys.libraryAuthorName),
                        textInputAction: TextInputAction.next,
                      ),
                    ),
                    if (isScreenplay && !_isEditMode) ...[
                      const SizedBox(width: RevericSpacing.lg),
                      Expanded(
                        child: HookedTextFormField<NovelFormField>(
                          fieldHook: NovelFormField.plannedEpisodeCount,
                          label: context.t(
                            LocaleKeys.libraryPlannedEpisodeCount,
                          ),
                          hintText: context.t(
                            LocaleKeys.libraryPlannedEpisodeCountHint,
                          ),
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: RevericSpacing.xl),
                HookedTextFormField<NovelFormField>(
                  fieldHook: NovelFormField.description,
                  label: context.t(LocaleKeys.libraryDescription),
                  multiline: true,
                  minLines: 4,
                  maxLines: 6,
                  keyboardType: TextInputType.multiline,
                ),
                const SizedBox(height: RevericSpacing.xl),
                _FieldLabel(text: context.t(LocaleKeys.libraryNovelType)),
                _TypeField(
                  form: form,
                  existingType: existingNovel?.type,
                  sourceNovels: sourceNovels,
                ),
                const SizedBox(height: RevericSpacing.xl),
                NovelCategoryField(fieldHook: NovelFormField.category),
                const SizedBox(height: RevericSpacing.xl),
                _FieldLabel(text: context.t(LocaleKeys.libraryTagsLabel)),
                _TagsField(form: form, suggestions: tagSuggestions),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _showError(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(context.t(LocaleKeys.libraryCreateWorkFailed))),
  );
}

InputDecoration _decoration(BuildContext context) {
  final colors = RevericTheme.colorsOf(context);
  return revericInputDecoration(
    context,
    fillColor: colors.surfaceContainerHigh,
    contentPadding: const EdgeInsets.symmetric(
      horizontal: RevericSpacing.lg,
      vertical: RevericSpacing.md,
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
      child: Text(
        text,
        style: typo.uiSemibold.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

class _CoverField extends ConsumerWidget {
  const _CoverField({
    required this.form,
    required this.currentCoverAssetId,
    required this.onPick,
    required this.removeCover,
  });

  final FormFieldsController<NovelFormField> form;

  /// 编辑模式下作品已有的封面资产。
  final String? currentCoverAssetId;
  final VoidCallback? onPick;

  /// 编辑模式下标记「移除已有封面」的 stateful 值容器。
  final ValueNotifier<bool> removeCover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final currentCover = watchMediaAssetFile(ref, currentCoverAssetId);
    return HookedFormField<NovelFormField, String>(
      fieldHook: NovelFormField.coverPath,
      notifyOnChange: true,
      builder: (value, onChanged, error) {
        final picked = value != null && value.isNotEmpty;
        final resolvedCoverPath = picked
            ? RevericPaths.resolveStored(value)
            : removeCover.value
            ? null
            : currentCover;
        final hasCover = resolvedCoverPath != null;
        return Center(
          child: SizedBox(
            width: 120,
            height: 168,
            child: Stack(
              children: [
                Positioned.fill(
                  child: InkWell(
                    key: const ValueKey('mobile-novel-cover-picker'),
                    onTap: onPick,
                    borderRadius: BorderRadius.circular(RevericRadius.large),
                    child: hasCover
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(
                              RevericRadius.large,
                            ),
                            child: Image.file(
                              File(resolvedCoverPath),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  _placeholder(context, colors, typo),
                            ),
                          )
                        : _placeholder(context, colors, typo),
                  ),
                ),
                if (hasCover)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: InkWell(
                      onTap: () {
                        onChanged?.call('');
                        removeCover.value = true;
                      },
                      customBorder: const CircleBorder(),
                      child: Container(
                        padding: const EdgeInsets.all(RevericSpacing.xxs),
                        decoration: BoxDecoration(
                          color: colors.canvas.withValues(alpha: 0.85),
                          shape: BoxShape.circle,
                        ),
                        child: RevericIcon(
                          RevericIcons.close,
                          size: 16,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          RevericIcon(
            RevericIcons.image_outlined,
            size: 26,
            color: colors.textSubtle,
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.librarySelectCover),
            style: typo.uiTinySemibold.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _TypeField extends StatelessWidget {
  const _TypeField({
    required this.form,
    required this.existingType,
    required this.sourceNovels,
  });

  final FormFieldsController<NovelFormField> form;

  /// 编辑模式下作品当前保存的类型；新建时为 null。
  final String? existingType;
  final List<Novel> sourceNovels;

  @override
  Widget build(BuildContext context) {
    // 可选类型随内容类型变化（改编只在剧本里出现），所以要跟着整个 form 重建，
    // 而不只是跟着 type 字段。
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        final contentKind =
            form.getValue<String>(NovelFormField.contentKind) ??
            contentKindNovel;
        final existingType = this.existingType;
        final types = existingType != null
            ? creatableNovelTypesFor(contentKind)
            : creatableNovelTypesFor(contentKind);
        return HookedFormField<NovelFormField, String>(
          fieldHook: NovelFormField.type,
          notifyOnChange: true,
          builder: (value, onChanged, error) {
            final selected = value ?? novelTypeOriginal;
            final sourceLabelKey = sourceNovelLabelKey(selected);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: RevericSpacing.sm,
                  runSpacing: RevericSpacing.sm,
                  children: [
                    for (final type in types)
                      ChoiceChip(
                        label: Text(_novelTypeLabel(context, type)),
                        selected: selected == type,
                        onSelected: (_) {
                          onChanged?.call(type);
                          if (!novelTypeSupportsSourceNovel(type)) {
                            form.updateValue<String?>(
                              NovelFormField.sourceNovelId,
                              null,
                            );
                          }
                        },
                      ),
                  ],
                ),
                // 新建改编剧本的原著由顶部横幅选择，这里不再重复一份。
                if (sourceLabelKey != null &&
                    !(existingType == null &&
                        selected == novelTypeAdaptation)) ...[
                  const SizedBox(height: RevericSpacing.xl),
                  _FieldLabel(text: context.t(sourceLabelKey)),
                  _MobileSourceNovelField(
                    sourceNovels: sourceNovels,
                    noneLabel: context.t(sourceNovelNoneKey(selected)),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _MobileSourceNovelField extends StatelessWidget {
  const _MobileSourceNovelField({
    required this.sourceNovels,
    required this.noneLabel,
  });

  final List<Novel> sourceNovels;

  /// 未选择来源时的文案，跟随作品类型（「未选择原著」/「未选择前作」…）。
  final String noneLabel;

  @override
  Widget build(BuildContext context) {
    return HookedFormField<NovelFormField, String?>(
      fieldHook: NovelFormField.sourceNovelId,
      notifyOnChange: true,
      builder: (sourceId, onSourceChanged, sourceError) {
        return _MobileSourceNovelPicker(
          sourceNovels: sourceNovels,
          selectedId: sourceId,
          noneLabel: noneLabel,
          onChanged: (id) => onSourceChanged?.call(id),
        );
      },
    );
  }
}

/// 来源小说选择器：输入框样式的触发器 + 底部弹层列表，只管展示和回调，
/// 由调用方决定写回哪里（类型下方的来源字段或改编横幅）。
class _MobileSourceNovelPicker extends StatelessWidget {
  const _MobileSourceNovelPicker({
    required this.sourceNovels,
    required this.selectedId,
    required this.noneLabel,
    required this.onChanged,
    this.emptyLabel,
  });

  final List<Novel> sourceNovels;
  final String? selectedId;
  final String noneLabel;

  /// 书架上没有可选小说时的占位文案；为空时沿用 [noneLabel]，且不禁用。
  final String? emptyLabel;

  /// 为 null 时禁用。
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final selectedSource = sourceNovels
        .where((source) => source.id == selectedId)
        .firstOrNull;
    final emptyLabel = sourceNovels.isEmpty ? this.emptyLabel : null;
    final onChanged = emptyLabel == null ? this.onChanged : null;
    return InkWell(
      borderRadius: BorderRadius.circular(RevericRadius.large),
      onTap: onChanged == null
          ? null
          : () => _showSourceNovelSheet(context, onChanged),
      child: InputDecorator(
        decoration: _decoration(context),
        child: Row(
          children: [
            Expanded(
              child: Text(
                selectedSource?.title ?? emptyLabel ?? noneLabel,
                style: typo.ui.copyWith(
                  color: selectedSource == null
                      ? colors.textMuted
                      : colors.textPrimary,
                ),
              ),
            ),
            RevericIcon(
              RevericIcons.expand_more,
              size: 18,
              color: colors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSourceNovelSheet(
    BuildContext context,
    ValueChanged<String?> onChanged,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(noneLabel),
              trailing: selectedId == null
                  ? const RevericIcon(RevericIcons.check, size: 18)
                  : null,
              onTap: () {
                Navigator.of(sheetContext).pop();
                onChanged(null);
              },
            ),
            for (final source in sourceNovels)
              ListTile(
                title: Text(source.title),
                trailing: source.id == selectedId
                    ? const RevericIcon(RevericIcons.check, size: 18)
                    : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onChanged(source.id);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _TagsField extends StatelessWidget {
  const _TagsField({required this.form, this.suggestions});

  final FormFieldsController<NovelFormField> form;
  final List<String>? suggestions;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);

    return HookedFormField<NovelFormField, List<String>>(
      fieldHook: NovelFormField.tags,
      notifyOnChange: true,
      builder: (tags, onChanged, error) {
        final currentTags = tags ?? const <String>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(RevericRadius.large),
                border: Border.all(color: colors.borderInput),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.md,
                vertical: RevericSpacing.sm,
              ),
              child: Wrap(
                spacing: RevericSpacing.sm,
                runSpacing: RevericSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final tag in currentTags)
                    _TagChip(
                      label: tag,
                      onDeleted: () {
                        final updated = List<String>.from(currentTags)
                          ..remove(tag);
                        onChanged?.call(updated);
                      },
                    ),
                  _AddTagInput(
                    onAdd: (tag) {
                      if (currentTags.contains(tag)) {
                        return;
                      }
                      onChanged?.call(List<String>.from(currentTags)..add(tag));
                    },
                    suggestions: suggestions,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.onDeleted});

  final String label;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.only(
        left: RevericSpacing.md,
        right: RevericSpacing.xs,
        top: RevericSpacing.xxs,
        bottom: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.selected,
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(width: RevericSpacing.xxs),
          InkWell(
            onTap: onDeleted,
            customBorder: const CircleBorder(),
            child: RevericIcon(
              RevericIcons.close,
              size: 14,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddTagInput extends HookWidget {
  const _AddTagInput({required this.onAdd, this.suggestions});

  final ValueChanged<String> onAdd;

  /// 非空时启用 Autocomplete 下拉建议。
  final List<String>? suggestions;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final controller = useTextEditingController();
    final focusNode = useFocusNode();
    final hasSuggestions = suggestions != null && suggestions!.isNotEmpty;

    void submit() {
      final text = controller.text.trim();
      if (text.isEmpty) {
        return;
      }
      onAdd(text);
      controller.clear();
    }

    void submitValue(String value) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        onAdd(trimmed);
      }
      controller.clear();
    }

    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      style: typo.uiSmall.copyWith(color: colors.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: context.t(LocaleKeys.libraryTagHint),
        hintStyle: typo.uiSmall.copyWith(color: colors.textSubtle),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.xs,
          vertical: RevericSpacing.xs,
        ),
      ),
      onSubmitted: (_) => submit(),
      onEditingComplete: submit,
    );

    if (!hasSuggestions) {
      return IntrinsicWidth(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 72),
          child: field,
        ),
      );
    }

    return IntrinsicWidth(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 72),
        child: RawAutocomplete<String>(
          textEditingController: controller,
          focusNode: focusNode,
          optionsBuilder: (textEditingValue) {
            final query = textEditingValue.text.toLowerCase();
            if (query.isEmpty) {
              return suggestions!;
            }
            return suggestions!.where((s) => s.toLowerCase().contains(query));
          },
          optionsViewBuilder: (context, onSelected, options) {
            return _TagOptionsView(
              options: options.toList(),
              colors: colors,
              typo: typo,
              onTap: (value) {
                onSelected(value);
                submitValue(value);
              },
            );
          },
          fieldViewBuilder:
              (context, controller, focusNode, onFieldSubmitted) => field,
        ),
      ),
    );
  }
}

/// 标签自动补全下拉浮层（移动端内联 TextField 专用）。
class _TagOptionsView extends StatelessWidget {
  const _TagOptionsView({
    required this.options,
    required this.colors,
    required this.typo,
    required this.onTap,
  });

  final List<String> options;
  final RevericColors colors;
  final RevericTypography typo;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        color: colors.surface,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: options.length > 5 ? 200 : options.length * 36.0 + 8,
            maxWidth: 200,
          ),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            shrinkWrap: true,
            children: [
              for (final option in options)
                InkWell(
                  onTap: () => onTap(option),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.md,
                      vertical: 6,
                    ),
                    child: Text(
                      option,
                      style: typo.uiSmall.copyWith(color: colors.textPrimary),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
