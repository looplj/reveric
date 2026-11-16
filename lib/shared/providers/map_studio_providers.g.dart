// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'map_studio_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(mapStudioImageModelSelection)
final mapStudioImageModelSelectionProvider =
    MapStudioImageModelSelectionProvider._();

final class MapStudioImageModelSelectionProvider
    extends
        $FunctionalProvider<
          MapStudioImageModelSelection?,
          MapStudioImageModelSelection?,
          MapStudioImageModelSelection?
        >
    with $Provider<MapStudioImageModelSelection?> {
  MapStudioImageModelSelectionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'mapStudioImageModelSelectionProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$mapStudioImageModelSelectionHash();

  @$internal
  @override
  $ProviderElement<MapStudioImageModelSelection?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  MapStudioImageModelSelection? create(Ref ref) {
    return mapStudioImageModelSelection(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(MapStudioImageModelSelection? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<MapStudioImageModelSelection?>(
        value,
      ),
    );
  }
}

String _$mapStudioImageModelSelectionHash() =>
    r'cb6e741e11d227f2066bcfd8e87f1eb705e28cdd';

/// 地图出图 / 改图绑定当前草稿选定的供应商和图片模型。

@ProviderFor(mapImageEditCallback)
final mapImageEditCallbackProvider = MapImageEditCallbackFamily._();

/// 地图出图 / 改图绑定当前草稿选定的供应商和图片模型。

final class MapImageEditCallbackProvider
    extends
        $FunctionalProvider<
          AiMultiImageEditCallback?,
          AiMultiImageEditCallback?,
          AiMultiImageEditCallback?
        >
    with $Provider<AiMultiImageEditCallback?> {
  /// 地图出图 / 改图绑定当前草稿选定的供应商和图片模型。
  MapImageEditCallbackProvider._({
    required MapImageEditCallbackFamily super.from,
    required String? super.argument,
  }) : super(
         retry: null,
         name: r'mapImageEditCallbackProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$mapImageEditCallbackHash();

  @override
  String toString() {
    return r'mapImageEditCallbackProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<AiMultiImageEditCallback?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiMultiImageEditCallback? create(Ref ref) {
    final argument = this.argument as String?;
    return mapImageEditCallback(ref, modelId: argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiMultiImageEditCallback? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiMultiImageEditCallback?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is MapImageEditCallbackProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$mapImageEditCallbackHash() =>
    r'66812a6586a19405d33aae10d8cfb0b1453d106c';

/// 地图出图 / 改图绑定当前草稿选定的供应商和图片模型。

final class MapImageEditCallbackFamily extends $Family
    with $FunctionalFamilyOverride<AiMultiImageEditCallback?, String?> {
  MapImageEditCallbackFamily._()
    : super(
        retry: null,
        name: r'mapImageEditCallbackProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 地图出图 / 改图绑定当前草稿选定的供应商和图片模型。

  MapImageEditCallbackProvider call({String? modelId}) =>
      MapImageEditCallbackProvider._(argument: modelId, from: this);

  @override
  String toString() => r'mapImageEditCallbackProvider';
}

/// 文生图 callback：地图首次生成（无参考图）时使用。

@ProviderFor(mapImageGenerateCallback)
final mapImageGenerateCallbackProvider = MapImageGenerateCallbackFamily._();

/// 文生图 callback：地图首次生成（无参考图）时使用。

final class MapImageGenerateCallbackProvider
    extends
        $FunctionalProvider<
          AiImageGenerationCallback?,
          AiImageGenerationCallback?,
          AiImageGenerationCallback?
        >
    with $Provider<AiImageGenerationCallback?> {
  /// 文生图 callback：地图首次生成（无参考图）时使用。
  MapImageGenerateCallbackProvider._({
    required MapImageGenerateCallbackFamily super.from,
    required String? super.argument,
  }) : super(
         retry: null,
         name: r'mapImageGenerateCallbackProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$mapImageGenerateCallbackHash();

  @override
  String toString() {
    return r'mapImageGenerateCallbackProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<AiImageGenerationCallback?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiImageGenerationCallback? create(Ref ref) {
    final argument = this.argument as String?;
    return mapImageGenerateCallback(ref, modelId: argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiImageGenerationCallback? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiImageGenerationCallback?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is MapImageGenerateCallbackProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$mapImageGenerateCallbackHash() =>
    r'4b1e4295898bd2f0a842cd4002b8fb8e5e0c8ef7';

/// 文生图 callback：地图首次生成（无参考图）时使用。

final class MapImageGenerateCallbackFamily extends $Family
    with $FunctionalFamilyOverride<AiImageGenerationCallback?, String?> {
  MapImageGenerateCallbackFamily._()
    : super(
        retry: null,
        name: r'mapImageGenerateCallbackProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 文生图 callback：地图首次生成（无参考图）时使用。

  MapImageGenerateCallbackProvider call({String? modelId}) =>
      MapImageGenerateCallbackProvider._(argument: modelId, from: this);

  @override
  String toString() => r'mapImageGenerateCallbackProvider';
}

@ProviderFor(mapPlaceNameReader)
final mapPlaceNameReaderProvider = MapPlaceNameReaderProvider._();

final class MapPlaceNameReaderProvider
    extends
        $FunctionalProvider<
          MapPlaceNameReader?,
          MapPlaceNameReader?,
          MapPlaceNameReader?
        >
    with $Provider<MapPlaceNameReader?> {
  MapPlaceNameReaderProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'mapPlaceNameReaderProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$mapPlaceNameReaderHash();

  @$internal
  @override
  $ProviderElement<MapPlaceNameReader?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  MapPlaceNameReader? create(Ref ref) {
    return mapPlaceNameReader(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(MapPlaceNameReader? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<MapPlaceNameReader?>(value),
    );
  }
}

String _$mapPlaceNameReaderHash() =>
    r'9fc2e419248a37b05f51e5a9646867078c426d0a';
