// 职责: 通过 Run providers 查询全局供应商、已配置聊天和媒体模型及有效能力。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/services/ai/provider_resources.dart
import 'package:collection/collection.dart';

import '../../logger/app_logger.dart';
import '../../models/ai_provider.dart';
import '../../models/tool_permission.dart';
import 'provider_resources.dart';

final _log = AppLogger.forModule('ProvidersRunCommandHandler');

class ProvidersRunCommandHandler {
  const ProvidersRunCommandHandler({required this.reader});

  final Future<List<AiProvider>> Function()? reader;

  Future<Map<String, dynamic>> run(
    String subcommand,
    Map<String, dynamic> options,
  ) async {
    final allowed = switch (subcommand) {
      'list' => {'enabled', 'sort'},
      'read' => {'provider_id'},
      'models' => {'provider_id', 'kind', 'model_id', 'view', 'sort'},
      _ => throw const FormatException(
        'providers requires list, read or models. Use Run help providers.',
      ),
    };
    if (options.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException(
        'Unsupported providers option. Use Run help providers; offset and limit are not supported.',
      );
    }
    String requiredText(String key) {
      final value = options[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key must be a non-empty string.');
      }
      return value;
    }

    final providerId = subcommand == 'list'
        ? null
        : requiredText('provider_id');
    final hasModels = subcommand == 'models';
    const kinds = ['chat', 'image', 'video', 'audio'];
    final kind = hasModels && options.containsKey('kind')
        ? requiredText('kind')
        : null;
    if (kind != null && !kinds.contains(kind)) {
      throw const FormatException('kind must be chat, image, video or audio.');
    }
    final modelId = options.containsKey('model_id')
        ? requiredText('model_id')
        : null;
    if (modelId != null && kind == null) {
      throw const FormatException('model_id requires kind.');
    }
    final view = options.containsKey('view') ? requiredText('view') : 'full';
    if (!const ['summary', 'full'].contains(view)) {
      throw const FormatException('view must be summary or full.');
    }
    if (options.containsKey('enabled') && options['enabled'] is! bool) {
      throw const FormatException('enabled must be a boolean.');
    }
    final enabled = options['enabled'] as bool? ?? true;
    String? sort;
    if (options.containsKey('sort')) {
      sort = requiredText('sort');
      final field = sort.startsWith('-') ? sort.substring(1) : sort;
      final fields = hasModels
          ? {
              'id',
              'provider_id',
              'kind',
              'available',
              'capabilities_known',
              'unavailable_reason',
            }
          : {'id', 'name', 'type', 'enabled', 'configured'};
      if (!fields.contains(field)) {
        throw const FormatException('Unsupported providers sort field.');
      }
    }

    final readProviders = reader;
    if (readProviders == null) {
      throw const ToolOperationException(
        'unavailable',
        'Provider configuration is unavailable in this session.',
      );
    }
    final List<AiProvider> providers;
    try {
      providers = await readProviders();
    } catch (error) {
      _log.warning('Provider configuration read failed: ${error.runtimeType}');
      throw const ToolOperationException(
        'unavailable',
        'Provider configuration could not be read.',
      );
    }
    Map<String, dynamic> listing(List<Map<String, dynamic>> entries) {
      final order = sort;
      if (order != null) {
        final descending = order.startsWith('-');
        final field = descending ? order.substring(1) : order;
        entries.sort((a, b) {
          final left = a[field];
          final right = b[field];
          final comparison = left == null
              ? (right == null ? 0 : 1)
              : right == null
              ? -1
              : left.toString().toLowerCase().compareTo(
                  right.toString().toLowerCase(),
                );
          return descending ? -comparison : comparison;
        });
      }
      return {'ok': true, 'type': 'listing', 'entries': entries};
    }

    if (subcommand == 'list') {
      return listing([
        for (final provider in providers)
          if (provider.enabled == enabled) providerResource(provider),
      ]);
    }
    final provider = providers
        .where((provider) => provider.id == providerId)
        .firstOrNull;
    if (provider == null) {
      throw const ToolOperationException('not_found', 'Provider not found.');
    }
    if (subcommand == 'read') {
      return {'ok': true, ...providerResource(provider)};
    }
    if (modelId != null &&
        !configuredProviderModels(provider, kind!).contains(modelId)) {
      throw const ToolOperationException(
        'not_found',
        'Configured model not found.',
      );
    }
    return listing([
      for (final modelKind in kind == null ? kinds : [kind])
        for (final id in configuredProviderModels(provider, modelKind))
          if (modelId == null || id == modelId)
            providerModelResource(
              provider,
              modelKind,
              id,
              includeDetails: view == 'full',
            ),
    ]);
  }

  static const helpText =
      '''Read configured providers and their chat, image, video and audio models. Results exclude credentials.
providers list: optional enabled (boolean), sort (id/name/type/enabled/configured).
providers read: provider_id required.
providers models: provider_id required; optional kind=chat|image|video|audio filters model type. Omit kind to return all four types. Optional model_id with kind selects one configured model (not_found if absent). view=summary omits capabilities and defaults; view=full (default) returns capabilities and defaults; optional sort (id/provider_id/kind/available/capabilities_known/unavailable_reason).
Lists return all entries without pagination; offset and limit are not supported. Prefix sort with - for descending order.
Pass provider_id exactly as returned, without URI encoding. Unknown capabilities remain unknown. Availability reflects local configuration only, not remote access or quota.
asset_certification: whether the provider can certify assets into its private asset library.
Example: {"command":"providers","subcommand":"models","options":{"provider_id":"<id from providers list>","kind":"image"}}''';
}
