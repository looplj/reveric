// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'storyboard.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(storyboardService)
final storyboardServiceProvider = StoryboardServiceFamily._();

final class StoryboardServiceProvider
    extends
        $FunctionalProvider<
          StoryboardService,
          StoryboardService,
          StoryboardService
        >
    with $Provider<StoryboardService> {
  StoryboardServiceProvider._({
    required StoryboardServiceFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'storyboardServiceProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$storyboardServiceHash();

  @override
  String toString() {
    return r'storyboardServiceProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<StoryboardService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  StoryboardService create(Ref ref) {
    final argument = this.argument as String;
    return storyboardService(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(StoryboardService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<StoryboardService>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is StoryboardServiceProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$storyboardServiceHash() => r'f2961a3579baeda5b2a83244d2dee5de6d2ff30e';

final class StoryboardServiceFamily extends $Family
    with $FunctionalFamilyOverride<StoryboardService, String> {
  StoryboardServiceFamily._()
    : super(
        retry: null,
        name: r'storyboardServiceProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  StoryboardServiceProvider call(String databasePath) =>
      StoryboardServiceProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'storyboardServiceProvider';
}

@ProviderFor(storyboardShots)
final storyboardShotsProvider = StoryboardShotsFamily._();

final class StoryboardShotsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ProductionClipRow>>,
          List<ProductionClipRow>,
          Stream<List<ProductionClipRow>>
        >
    with
        $FutureModifier<List<ProductionClipRow>>,
        $StreamProvider<List<ProductionClipRow>> {
  StoryboardShotsProvider._({
    required StoryboardShotsFamily super.from,
    required (String, String) super.argument,
  }) : super(
         retry: null,
         name: r'storyboardShotsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$storyboardShotsHash();

  @override
  String toString() {
    return r'storyboardShotsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<ProductionClipRow>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<ProductionClipRow>> create(Ref ref) {
    final argument = this.argument as (String, String);
    return storyboardShots(ref, argument.$1, argument.$2);
  }

  @override
  bool operator ==(Object other) {
    return other is StoryboardShotsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$storyboardShotsHash() => r'da5fe99ea01cba7786e88a319b7fe3cfb9702e3a';

final class StoryboardShotsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<ProductionClipRow>>,
          (String, String)
        > {
  StoryboardShotsFamily._()
    : super(
        retry: null,
        name: r'storyboardShotsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  StoryboardShotsProvider call(String databasePath, String episodeId) =>
      StoryboardShotsProvider._(
        argument: (databasePath, episodeId),
        from: this,
      );

  @override
  String toString() => r'storyboardShotsProvider';
}

@ProviderFor(episodeProduction)
final episodeProductionProvider = EpisodeProductionFamily._();

final class EpisodeProductionProvider
    extends
        $FunctionalProvider<
          AsyncValue<ScreenplayRow?>,
          ScreenplayRow?,
          Stream<ScreenplayRow?>
        >
    with $FutureModifier<ScreenplayRow?>, $StreamProvider<ScreenplayRow?> {
  EpisodeProductionProvider._({
    required EpisodeProductionFamily super.from,
    required (String, String) super.argument,
  }) : super(
         retry: null,
         name: r'episodeProductionProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$episodeProductionHash();

  @override
  String toString() {
    return r'episodeProductionProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<ScreenplayRow?> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<ScreenplayRow?> create(Ref ref) {
    final argument = this.argument as (String, String);
    return episodeProduction(ref, argument.$1, argument.$2);
  }

  @override
  bool operator ==(Object other) {
    return other is EpisodeProductionProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$episodeProductionHash() => r'c4954b5de671a3d2df2ff70bb9c2395ddaaecdc9';

final class EpisodeProductionFamily extends $Family
    with $FunctionalFamilyOverride<Stream<ScreenplayRow?>, (String, String)> {
  EpisodeProductionFamily._()
    : super(
        retry: null,
        name: r'episodeProductionProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  EpisodeProductionProvider call(String databasePath, String episodeId) =>
      EpisodeProductionProvider._(
        argument: (databasePath, episodeId),
        from: this,
      );

  @override
  String toString() => r'episodeProductionProvider';
}
