// 职责: 提供插件市场 HTTP 客户端、目录服务与单飞缓存+刷新状态 Provider。
// 关联文件:
//   lib/shared/models/plugin/marketplace_plugin.dart
//   lib/shared/services/plugins/marketplace_service.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/services/proxy_client.dart
// 遵循的 Rules:
//   .agents/rules/code-style.md
//   .agents/rules/state-management.md

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/plugin/marketplace_plugin.dart';
import '../services/plugins/marketplace_service.dart';
import '../services/proxy_client.dart';
import 'settings_providers.dart';

/// 插件市场网络客户端工厂（测试可 override）。
final pluginMarketplaceHttpClientFactoryProvider =
    Provider<FutureOr<Dio> Function()>((ref) {
      return () async {
        final settings = await ref.read(appSettingsProvider.future);
        return createProxyDioClient(
          settings.networkProxy,
          options: BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );
      };
    });

/// 插件市场索引与包下载服务（测试可 override）。
final pluginMarketplaceServiceProvider = Provider<PluginMarketplaceService>((
  ref,
) {
  final createClient = ref.watch(pluginMarketplaceHttpClientFactoryProvider);
  return PluginMarketplaceService(createClient: createClient);
});

/// 插件市场索引状态：保留已有缓存条目，同时标示首轮加载、刷新与失败状态。
class PluginMarketplaceState {
  const PluginMarketplaceState({
    this.plugins = const [],
    this.loading = false,
    this.refreshing = false,
    this.errorKind,
  });

  final List<MarketplacePluginEntry> plugins;
  final bool loading;
  final bool refreshing;
  final PluginMarketplaceErrorKind? errorKind;

  bool get hasData => plugins.isNotEmpty;

  PluginMarketplaceState copyWith({
    List<MarketplacePluginEntry>? plugins,
    bool? loading,
    bool? refreshing,
    PluginMarketplaceErrorKind? errorKind,
    bool clearError = false,
  }) => PluginMarketplaceState(
    plugins: plugins ?? this.plugins,
    loading: loading ?? this.loading,
    refreshing: refreshing ?? this.refreshing,
    errorKind: clearError ? null : (errorKind ?? this.errorKind),
  );
}

/// 插件市场索引状态管理器：先读缓存，再单飞拉取远端更新。
class PluginMarketplaceNotifier extends Notifier<PluginMarketplaceState> {
  Future<void>? _inFlight;
  bool _initialized = false;

  @override
  PluginMarketplaceState build() {
    if (!_initialized) {
      _initialized = true;
      Future.microtask(_loadInitial);
    }
    return const PluginMarketplaceState(loading: true);
  }

  Future<void> _loadInitial() async {
    final service = ref.read(pluginMarketplaceServiceProvider);
    final cached = await service.readCatalogCache();
    if (!ref.mounted) {
      return;
    }
    if (cached != null) {
      state = PluginMarketplaceState(
        plugins: cached.plugins,
        loading: false,
        refreshing: true,
      );
    }
    await refresh();
  }

  /// 单飞刷新市场索引；远端失败时保留已有列表并记录错误类型。
  Future<void> refresh() {
    final existing = _inFlight;
    if (existing != null) {
      return existing;
    }
    final future = _runRefresh().whenComplete(() {
      if (identical(_inFlight, _activeFuture)) {
        _inFlight = null;
      }
    });
    _activeFuture = future;
    _inFlight = future;
    return future;
  }

  Future<void>? _activeFuture;

  Future<void> _runRefresh() async {
    final service = ref.read(pluginMarketplaceServiceProvider);
    state = state.copyWith(
      loading: !state.hasData,
      refreshing: state.hasData,
      clearError: true,
    );
    try {
      final index = await service.fetchCatalog();
      if (!ref.mounted) {
        return;
      }
      state = PluginMarketplaceState(
        plugins: index.plugins,
        loading: false,
        refreshing: false,
      );
    } on PluginMarketplaceException catch (error) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        loading: false,
        refreshing: false,
        errorKind: error.kind,
      );
    } on Object {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        loading: false,
        refreshing: false,
        errorKind: PluginMarketplaceErrorKind.network,
      );
    }
  }
}

final pluginMarketplaceProvider =
    NotifierProvider<PluginMarketplaceNotifier, PluginMarketplaceState>(
      PluginMarketplaceNotifier.new,
    );
