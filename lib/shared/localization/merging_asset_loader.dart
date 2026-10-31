// 职责: 多文件 JSON 翻译资源加载器 — 按 namespace 拆分翻译文件后合并加载
// 关联文件:
//   assets/translations/en/*.json
//   assets/translations/zh-CN/*.json
//   lib/main.dart

import 'dart:convert';
import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';

class MergingAssetLoader extends AssetLoader {
  const MergingAssetLoader();

  static const _namespaces = [
    'a2ui',
    'account',
    'agent',
    'agent_studio',
    'agent_rule',
    'agent_shortcut',
    'agent_skill',
    'ai',
    'app',
    'assets',
    'audio',
    'canvas',
    'chapter',
    'character',
    'comment',
    'common',
    'condition',
    'connection',
    'council',
    'diff',
    'director',
    'editor',
    'entity',
    'entity_graph',
    'entity_search',
    'form',
    'heuristic',
    'history',
    'home',
    'library',
    'location',
    'map',
    'map_editor',
    'mobile',
    'monologue',
    'name_assistant',
    'onboarding',
    'relation',
    'relation_dialog',
    'reading',
    'remote',
    'roleplay',
    'settings',
    'screenplay',
    'production',
    'sidebar',
    'subagent',
    'theater',
    'todo',
    'workspace',
  ];

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final localeDir = '$path/${locale.toStringWithSeparator(separator: "-")}';
    final merged = <String, dynamic>{};

    for (final ns in _namespaces) {
      try {
        final jsonStr = await rootBundle.loadString('$localeDir/$ns.json');
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        merged.addAll(map);
      } catch (_) {
        // skip missing namespace files
      }
    }

    return merged;
  }
}
