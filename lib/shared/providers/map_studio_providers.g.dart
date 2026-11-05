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

/// 地图出图 / 改图使用默认图片模型。

@ProviderFor(mapImageEditCallback)
final mapImageEditCallbackProvider = MapImageEditCallbackProvider._();

/// 地图出图 / 改图使用默认图片模型。

final class MapImageEditCallbackProvider
    extends
        $FunctionalProvider<
          AiMultiImageEditCallback?,
          AiMultiImageEditCallback?,
          AiMultiImageEditCallback?
        >
    with $Provider<AiMultiImageEditCallback?> {
  /// 地图出图 / 改图使用默认图片模型。
  MapImageEditCallbackProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'mapImageEditCallbackProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$mapImageEditCallbackHash();

  @$internal
  @override
  $ProviderElement<AiMultiImageEditCallback?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiMultiImageEditCallback? create(Ref ref) {
    return mapImageEditCallback(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiMultiImageEditCallback? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiMultiImageEditCallback?>(value),
    );
  }
}

String _$mapImageEditCallbackHash() =>
    r'6d786d8978ebf5481bd7ba2fd63f7a39617bfae2';

/// 文生图 callback：地图首次生成（无参考图）时使用。

@ProviderFor(mapImageGenerateCallback)
final mapImageGenerateCallbackProvider = MapImageGenerateCallbackProvider._();

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
  MapImageGenerateCallbackProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'mapImageGenerateCallbackProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$mapImageGenerateCallbackHash();

  @$internal
  @override
  $ProviderElement<AiImageGenerationCallback?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiImageGenerationCallback? create(Ref ref) {
    return mapImageGenerateCallback(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiImageGenerationCallback? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiImageGenerationCallback?>(value),
    );
  }
}

String _$mapImageGenerateCallbackHash() =>
    r'1016aa08435c7aeb13ec083d8beae5c478f3cde2';

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
