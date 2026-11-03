// 职责: 承载作品创建表单的预填值 — 供「改编」等带来源的入口在桌面与移动端共用同一份预填口径。
// 关联文件:
//   lib/shared/models/novel_form_fields.dart
//   lib/shared/models/content_kind.dart
//   lib/shared/models/novel_type.dart
//   lib/desktop/widgets/novel_form_dialog.dart
//   lib/mobile/pages/novel_create_page.dart
import 'package:flutter/foundation.dart';

import '../../third/form/flutter_hook_form.dart';
import '../database/app_database.dart';
import 'content_kind.dart';
import 'novel_form_fields.dart';
import 'novel_type.dart';

/// 创建作品表单的预填值。只覆盖用户可改的字段，封面不预填 —— 改编剧本通常要换新封面。
class NovelFormPrefill {
  const NovelFormPrefill({
    required this.contentKind,
    required this.type,
    this.title = '',
    this.authorName = '',
    this.description = '',
    this.category = '',
    this.sourceNovelId,
    this.tags = const <String>[],
  });

  /// 由一本来源小说推导「改编剧本」的预填值：类型落在改编、来源指向该小说，
  /// 其余信息沿用原著。标题由调用方按 `library.adaptation_title` 本地化后传入，
  /// 带后缀是为了绕开与原著的重名校验。
  factory NovelFormPrefill.adaptationOf(Novel source, {required String title}) {
    return NovelFormPrefill(
      contentKind: contentKindScreenplay,
      type: novelTypeAdaptation,
      title: title,
      authorName: source.authorName,
      description: source.description,
      category: source.category,
      sourceNovelId: source.id,
      tags: source.tags,
    );
  }

  /// 在已打开的表单里换原著：类型和来源直接写入；标题、作者、简介、分类、标签
  /// 只填空着的，或仍是 [replacing]（上一本原著带入的值）原样的字段，
  /// 用户改过的内容不覆盖。
  void applyTo(
    FormFieldsController<NovelFormField> form, {
    NovelFormPrefill? replacing,
  }) {
    form.updateValue(NovelFormField.type, type, notify: false);
    void fillText(NovelFormField field, String next, String? previous) {
      final current = form.getValue<String>(field) ?? '';
      if (current.trim().isEmpty || current == previous) {
        form.updateValue(field, next, notify: false);
      }
    }

    fillText(NovelFormField.title, title, replacing?.title);
    fillText(NovelFormField.authorName, authorName, replacing?.authorName);
    fillText(NovelFormField.description, description, replacing?.description);
    fillText(NovelFormField.category, category, replacing?.category);
    final currentTags = form.getValue<List<String>>(NovelFormField.tags) ?? [];
    if (currentTags.isEmpty ||
        (replacing != null && listEquals(currentTags, replacing.tags))) {
      form.updateValue(NovelFormField.tags, tags, notify: false);
    }
    // 最后一笔才通知，整组改动只触发一次重建。
    form.updateValue(NovelFormField.sourceNovelId, sourceNovelId);
  }

  final String contentKind;
  final String type;
  final String title;
  final String authorName;
  final String description;
  final String category;
  final String? sourceNovelId;
  final List<String> tags;
}
