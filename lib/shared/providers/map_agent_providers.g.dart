// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'map_agent_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 草稿需要在制图师关闭时仍可由 Agent 投递，因此保留轻量值；数量有硬上限，
/// 应用或忽略后立即移除，不持有 controller、stream 或数据库连接。

@ProviderFor(MapDesignDrafts)
final mapDesignDraftsProvider = MapDesignDraftsProvider._();

/// 草稿需要在制图师关闭时仍可由 Agent 投递，因此保留轻量值；数量有硬上限，
/// 应用或忽略后立即移除，不持有 controller、stream 或数据库连接。
final class MapDesignDraftsProvider
    extends
        $NotifierProvider<
          MapDesignDrafts,
          Map<MapDesignDraftKey, MapDesignDraft>
        > {
  /// 草稿需要在制图师关闭时仍可由 Agent 投递，因此保留轻量值；数量有硬上限，
  /// 应用或忽略后立即移除，不持有 controller、stream 或数据库连接。
  MapDesignDraftsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'mapDesignDraftsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$mapDesignDraftsHash();

  @$internal
  @override
  MapDesignDrafts create() => MapDesignDrafts();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(Map<MapDesignDraftKey, MapDesignDraft> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride:
          $SyncValueProvider<Map<MapDesignDraftKey, MapDesignDraft>>(value),
    );
  }
}

String _$mapDesignDraftsHash() => r'3bbae894e824003a21a61971e7afeb78fb1d53c8';

/// 草稿需要在制图师关闭时仍可由 Agent 投递，因此保留轻量值；数量有硬上限，
/// 应用或忽略后立即移除，不持有 controller、stream 或数据库连接。

abstract class _$MapDesignDrafts
    extends $Notifier<Map<MapDesignDraftKey, MapDesignDraft>> {
  Map<MapDesignDraftKey, MapDesignDraft> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref
            as $Ref<
              Map<MapDesignDraftKey, MapDesignDraft>,
              Map<MapDesignDraftKey, MapDesignDraft>
            >;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                Map<MapDesignDraftKey, MapDesignDraft>,
                Map<MapDesignDraftKey, MapDesignDraft>
              >,
              Map<MapDesignDraftKey, MapDesignDraft>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(mapDesignDraft)
final mapDesignDraftProvider = MapDesignDraftFamily._();

final class MapDesignDraftProvider
    extends
        $FunctionalProvider<MapDesignDraft?, MapDesignDraft?, MapDesignDraft?>
    with $Provider<MapDesignDraft?> {
  MapDesignDraftProvider._({
    required MapDesignDraftFamily super.from,
    required ({String databasePath, String worldId}) super.argument,
  }) : super(
         retry: null,
         name: r'mapDesignDraftProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$mapDesignDraftHash();

  @override
  String toString() {
    return r'mapDesignDraftProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $ProviderElement<MapDesignDraft?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  MapDesignDraft? create(Ref ref) {
    final argument = this.argument as ({String databasePath, String worldId});
    return mapDesignDraft(
      ref,
      databasePath: argument.databasePath,
      worldId: argument.worldId,
    );
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(MapDesignDraft? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<MapDesignDraft?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is MapDesignDraftProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$mapDesignDraftHash() => r'f99dd404dbdf645296e1807d687e6d3838dfc06f';

final class MapDesignDraftFamily extends $Family
    with
        $FunctionalFamilyOverride<
          MapDesignDraft?,
          ({String databasePath, String worldId})
        > {
  MapDesignDraftFamily._()
    : super(
        retry: null,
        name: r'mapDesignDraftProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  MapDesignDraftProvider call({
    required String databasePath,
    required String worldId,
  }) => MapDesignDraftProvider._(
    argument: (databasePath: databasePath, worldId: worldId),
    from: this,
  );

  @override
  String toString() => r'mapDesignDraftProvider';
}

/// 一次只保留最新请求；NovelEditor 的常驻 listener 负责把它转成交接草稿。
/// 请求很小且必须跨制图师关闭动作保留，因此使用单实例 keepAlive。

@ProviderFor(MapAgentHandoff)
final mapAgentHandoffProvider = MapAgentHandoffProvider._();

/// 一次只保留最新请求；NovelEditor 的常驻 listener 负责把它转成交接草稿。
/// 请求很小且必须跨制图师关闭动作保留，因此使用单实例 keepAlive。
final class MapAgentHandoffProvider
    extends $NotifierProvider<MapAgentHandoff, MapAgentHandoffRequest?> {
  /// 一次只保留最新请求；NovelEditor 的常驻 listener 负责把它转成交接草稿。
  /// 请求很小且必须跨制图师关闭动作保留，因此使用单实例 keepAlive。
  MapAgentHandoffProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'mapAgentHandoffProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$mapAgentHandoffHash();

  @$internal
  @override
  MapAgentHandoff create() => MapAgentHandoff();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(MapAgentHandoffRequest? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<MapAgentHandoffRequest?>(value),
    );
  }
}

String _$mapAgentHandoffHash() => r'3c1c47bf95110728e0b50d61f3a3551e46c3923c';

/// 一次只保留最新请求；NovelEditor 的常驻 listener 负责把它转成交接草稿。
/// 请求很小且必须跨制图师关闭动作保留，因此使用单实例 keepAlive。

abstract class _$MapAgentHandoff extends $Notifier<MapAgentHandoffRequest?> {
  MapAgentHandoffRequest? build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref as $Ref<MapAgentHandoffRequest?, MapAgentHandoffRequest?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<MapAgentHandoffRequest?, MapAgentHandoffRequest?>,
              MapAgentHandoffRequest?,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
