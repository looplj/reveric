// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'map_studio_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(MapStudioController)
final mapStudioControllerProvider = MapStudioControllerFamily._();

final class MapStudioControllerProvider
    extends $NotifierProvider<MapStudioController, MapStudioState> {
  MapStudioControllerProvider._({
    required MapStudioControllerFamily super.from,
    required (String, String) super.argument,
  }) : super(
         retry: null,
         name: r'mapStudioControllerProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$mapStudioControllerHash();

  @override
  String toString() {
    return r'mapStudioControllerProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  MapStudioController create() => MapStudioController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(MapStudioState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<MapStudioState>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is MapStudioControllerProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$mapStudioControllerHash() =>
    r'ba9d5bca449c7edf0e4162767d29eb6b4aa3b4b6';

final class MapStudioControllerFamily extends $Family
    with
        $ClassFamilyOverride<
          MapStudioController,
          MapStudioState,
          MapStudioState,
          MapStudioState,
          (String, String)
        > {
  MapStudioControllerFamily._()
    : super(
        retry: null,
        name: r'mapStudioControllerProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  MapStudioControllerProvider call(String databasePath, String mapId) =>
      MapStudioControllerProvider._(
        argument: (databasePath, mapId),
        from: this,
      );

  @override
  String toString() => r'mapStudioControllerProvider';
}

abstract class _$MapStudioController extends $Notifier<MapStudioState> {
  late final _$args = ref.$arg as (String, String);
  String get databasePath => _$args.$1;
  String get mapId => _$args.$2;

  MapStudioState build(String databasePath, String mapId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<MapStudioState, MapStudioState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<MapStudioState, MapStudioState>,
              MapStudioState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args.$1, _$args.$2));
  }
}
