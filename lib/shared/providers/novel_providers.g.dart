// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'novel_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(appDatabase)
final appDatabaseProvider = AppDatabaseProvider._();

final class AppDatabaseProvider
    extends $FunctionalProvider<AppDatabase, AppDatabase, AppDatabase>
    with $Provider<AppDatabase> {
  AppDatabaseProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appDatabaseProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appDatabaseHash();

  @$internal
  @override
  $ProviderElement<AppDatabase> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AppDatabase create(Ref ref) {
    return appDatabase(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AppDatabase value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AppDatabase>(value),
    );
  }
}

String _$appDatabaseHash() => r'44154e51c3f3079ee293d8ad0ebd1e17cca871ed';

@ProviderFor(imageLibraryService)
final imageLibraryServiceProvider = ImageLibraryServiceProvider._();

final class ImageLibraryServiceProvider
    extends
        $FunctionalProvider<
          ImageLibraryService,
          ImageLibraryService,
          ImageLibraryService
        >
    with $Provider<ImageLibraryService> {
  ImageLibraryServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'imageLibraryServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$imageLibraryServiceHash();

  @$internal
  @override
  $ProviderElement<ImageLibraryService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  ImageLibraryService create(Ref ref) {
    return imageLibraryService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ImageLibraryService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ImageLibraryService>(value),
    );
  }
}

String _$imageLibraryServiceHash() =>
    r'2e356b45a8729eb1985c04c3c1cbecd8edfc5daf';

@ProviderFor(imageAssets)
final imageAssetsProvider = ImageAssetsFamily._();

final class ImageAssetsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<AssetRow>>,
          List<AssetRow>,
          Stream<List<AssetRow>>
        >
    with $FutureModifier<List<AssetRow>>, $StreamProvider<List<AssetRow>> {
  ImageAssetsProvider._({
    required ImageAssetsFamily super.from,
    required (String?, {String? purpose}) super.argument,
  }) : super(
         retry: null,
         name: r'imageAssetsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$imageAssetsHash();

  @override
  String toString() {
    return r'imageAssetsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<AssetRow>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<AssetRow>> create(Ref ref) {
    final argument = this.argument as (String?, {String? purpose});
    return imageAssets(ref, argument.$1, purpose: argument.purpose);
  }

  @override
  bool operator ==(Object other) {
    return other is ImageAssetsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$imageAssetsHash() => r'4070ad85da5c28a184996a9cbd828691a4d45c7b';

final class ImageAssetsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<AssetRow>>,
          (String?, {String? purpose})
        > {
  ImageAssetsFamily._()
    : super(
        retry: null,
        name: r'imageAssetsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ImageAssetsProvider call(String? novelId, {String? purpose}) =>
      ImageAssetsProvider._(argument: (novelId, purpose: purpose), from: this);

  @override
  String toString() => r'imageAssetsProvider';
}

@ProviderFor(imageBatches)
final imageBatchesProvider = ImageBatchesFamily._();

final class ImageBatchesProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ImageBatchRow>>,
          List<ImageBatchRow>,
          Stream<List<ImageBatchRow>>
        >
    with
        $FutureModifier<List<ImageBatchRow>>,
        $StreamProvider<List<ImageBatchRow>> {
  ImageBatchesProvider._({
    required ImageBatchesFamily super.from,
    required (String?, {String? purpose}) super.argument,
  }) : super(
         retry: null,
         name: r'imageBatchesProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$imageBatchesHash();

  @override
  String toString() {
    return r'imageBatchesProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<ImageBatchRow>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<ImageBatchRow>> create(Ref ref) {
    final argument = this.argument as (String?, {String? purpose});
    return imageBatches(ref, argument.$1, purpose: argument.purpose);
  }

  @override
  bool operator ==(Object other) {
    return other is ImageBatchesProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$imageBatchesHash() => r'c07a25f8a07a042e00f70247b72f7aed5f5d99ba';

final class ImageBatchesFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<ImageBatchRow>>,
          (String?, {String? purpose})
        > {
  ImageBatchesFamily._()
    : super(
        retry: null,
        name: r'imageBatchesProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ImageBatchesProvider call(String? novelId, {String? purpose}) =>
      ImageBatchesProvider._(argument: (novelId, purpose: purpose), from: this);

  @override
  String toString() => r'imageBatchesProvider';
}

@ProviderFor(imageBatchSlots)
final imageBatchSlotsProvider = ImageBatchSlotsFamily._();

final class ImageBatchSlotsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ImageBatchSlotRow>>,
          List<ImageBatchSlotRow>,
          Stream<List<ImageBatchSlotRow>>
        >
    with
        $FutureModifier<List<ImageBatchSlotRow>>,
        $StreamProvider<List<ImageBatchSlotRow>> {
  ImageBatchSlotsProvider._({
    required ImageBatchSlotsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'imageBatchSlotsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$imageBatchSlotsHash();

  @override
  String toString() {
    return r'imageBatchSlotsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<List<ImageBatchSlotRow>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<ImageBatchSlotRow>> create(Ref ref) {
    final argument = this.argument as String;
    return imageBatchSlots(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ImageBatchSlotsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$imageBatchSlotsHash() => r'37e0af69a948200b7a55e1d65f251a989fabe2c0';

final class ImageBatchSlotsFamily extends $Family
    with $FunctionalFamilyOverride<Stream<List<ImageBatchSlotRow>>, String> {
  ImageBatchSlotsFamily._()
    : super(
        retry: null,
        name: r'imageBatchSlotsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ImageBatchSlotsProvider call(String batchId) =>
      ImageBatchSlotsProvider._(argument: batchId, from: this);

  @override
  String toString() => r'imageBatchSlotsProvider';
}

@ProviderFor(novels)
final novelsProvider = NovelsProvider._();

final class NovelsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Novel>>,
          List<Novel>,
          Stream<List<Novel>>
        >
    with $FutureModifier<List<Novel>>, $StreamProvider<List<Novel>> {
  NovelsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'novelsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$novelsHash();

  @$internal
  @override
  $StreamProviderElement<List<Novel>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<Novel>> create(Ref ref) {
    return novels(ref);
  }
}

String _$novelsHash() => r'836d37d1c2e466f470badb39df794e810ddd8b9b';

/// 回收站中的作品。

@ProviderFor(deletedNovels)
final deletedNovelsProvider = DeletedNovelsProvider._();

/// 回收站中的作品。

final class DeletedNovelsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Novel>>,
          List<Novel>,
          Stream<List<Novel>>
        >
    with $FutureModifier<List<Novel>>, $StreamProvider<List<Novel>> {
  /// 回收站中的作品。
  DeletedNovelsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'deletedNovelsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$deletedNovelsHash();

  @$internal
  @override
  $StreamProviderElement<List<Novel>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<Novel>> create(Ref ref) {
    return deletedNovels(ref);
  }
}

String _$deletedNovelsHash() => r'430ba7c27e91cbebe8977551600907ab3ab48871';

@ProviderFor(novel)
final novelProvider = NovelFamily._();

final class NovelProvider
    extends $FunctionalProvider<AsyncValue<Novel?>, Novel?, Stream<Novel?>>
    with $FutureModifier<Novel?>, $StreamProvider<Novel?> {
  NovelProvider._({
    required NovelFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'novelProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$novelHash();

  @override
  String toString() {
    return r'novelProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<Novel?> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<Novel?> create(Ref ref) {
    final argument = this.argument as String;
    return novel(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is NovelProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$novelHash() => r'56507444887f4dabb1ba39d6e90f14dff8680c5b';

final class NovelFamily extends $Family
    with $FunctionalFamilyOverride<Stream<Novel?>, String> {
  NovelFamily._()
    : super(
        retry: null,
        name: r'novelProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  NovelProvider call(String novelId) =>
      NovelProvider._(argument: novelId, from: this);

  @override
  String toString() => r'novelProvider';
}

@ProviderFor(novelByContentDatabasePath)
final novelByContentDatabasePathProvider = NovelByContentDatabasePathFamily._();

final class NovelByContentDatabasePathProvider
    extends $FunctionalProvider<AsyncValue<Novel?>, Novel?, Stream<Novel?>>
    with $FutureModifier<Novel?>, $StreamProvider<Novel?> {
  NovelByContentDatabasePathProvider._({
    required NovelByContentDatabasePathFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'novelByContentDatabasePathProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$novelByContentDatabasePathHash();

  @override
  String toString() {
    return r'novelByContentDatabasePathProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<Novel?> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<Novel?> create(Ref ref) {
    final argument = this.argument as String;
    return novelByContentDatabasePath(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is NovelByContentDatabasePathProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$novelByContentDatabasePathHash() =>
    r'41b388a36b14f0c5d73b74f815a862ae3f7aefe9';

final class NovelByContentDatabasePathFamily extends $Family
    with $FunctionalFamilyOverride<Stream<Novel?>, String> {
  NovelByContentDatabasePathFamily._()
    : super(
        retry: null,
        name: r'novelByContentDatabasePathProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  NovelByContentDatabasePathProvider call(String databasePath) =>
      NovelByContentDatabasePathProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'novelByContentDatabasePathProvider';
}

@ProviderFor(novelActions)
final novelActionsProvider = NovelActionsProvider._();

final class NovelActionsProvider
    extends
        $FunctionalProvider<
          NovelActionsService,
          NovelActionsService,
          NovelActionsService
        >
    with $Provider<NovelActionsService> {
  NovelActionsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'novelActionsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$novelActionsHash();

  @$internal
  @override
  $ProviderElement<NovelActionsService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  NovelActionsService create(Ref ref) {
    return novelActions(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(NovelActionsService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<NovelActionsService>(value),
    );
  }
}

String _$novelActionsHash() => r'dd478a9a9a9b1984a51cc9d44941d8afef3e9c27';

@ProviderFor(novelContentDatabase)
final novelContentDatabaseProvider = NovelContentDatabaseFamily._();

final class NovelContentDatabaseProvider
    extends
        $FunctionalProvider<
          NovelContentDatabase,
          NovelContentDatabase,
          NovelContentDatabase
        >
    with $Provider<NovelContentDatabase> {
  NovelContentDatabaseProvider._({
    required NovelContentDatabaseFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'novelContentDatabaseProvider',
         isAutoDispose: false,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$novelContentDatabaseHash();

  @override
  String toString() {
    return r'novelContentDatabaseProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<NovelContentDatabase> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  NovelContentDatabase create(Ref ref) {
    final argument = this.argument as String;
    return novelContentDatabase(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(NovelContentDatabase value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<NovelContentDatabase>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is NovelContentDatabaseProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$novelContentDatabaseHash() =>
    r'cdec070cd1c7a018e5de916499f94d1ef27f323b';

final class NovelContentDatabaseFamily extends $Family
    with $FunctionalFamilyOverride<NovelContentDatabase, String> {
  NovelContentDatabaseFamily._()
    : super(
        retry: null,
        name: r'novelContentDatabaseProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: false,
      );

  NovelContentDatabaseProvider call(String databasePath) =>
      NovelContentDatabaseProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'novelContentDatabaseProvider';
}

@ProviderFor(novelContentService)
final novelContentServiceProvider = NovelContentServiceFamily._();

final class NovelContentServiceProvider
    extends
        $FunctionalProvider<
          NovelContentService,
          NovelContentService,
          NovelContentService
        >
    with $Provider<NovelContentService> {
  NovelContentServiceProvider._({
    required NovelContentServiceFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'novelContentServiceProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$novelContentServiceHash();

  @override
  String toString() {
    return r'novelContentServiceProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<NovelContentService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  NovelContentService create(Ref ref) {
    final argument = this.argument as String;
    return novelContentService(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(NovelContentService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<NovelContentService>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is NovelContentServiceProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$novelContentServiceHash() =>
    r'5f9f4baa8d1a4358596c594b58a0383f2676cb06';

final class NovelContentServiceFamily extends $Family
    with $FunctionalFamilyOverride<NovelContentService, String> {
  NovelContentServiceFamily._()
    : super(
        retry: null,
        name: r'novelContentServiceProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  NovelContentServiceProvider call(String databasePath) =>
      NovelContentServiceProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'novelContentServiceProvider';
}

@ProviderFor(novelExport)
final novelExportProvider = NovelExportFamily._();

final class NovelExportProvider
    extends
        $FunctionalProvider<
          NovelExportService,
          NovelExportService,
          NovelExportService
        >
    with $Provider<NovelExportService> {
  NovelExportProvider._({
    required NovelExportFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'novelExportProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$novelExportHash();

  @override
  String toString() {
    return r'novelExportProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<NovelExportService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  NovelExportService create(Ref ref) {
    final argument = this.argument as String;
    return novelExport(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(NovelExportService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<NovelExportService>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is NovelExportProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$novelExportHash() => r'7cde4f6243e182f0d20fa7a9b0353e214b683e5a';

final class NovelExportFamily extends $Family
    with $FunctionalFamilyOverride<NovelExportService, String> {
  NovelExportFamily._()
    : super(
        retry: null,
        name: r'novelExportProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  NovelExportProvider call(String databasePath) =>
      NovelExportProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'novelExportProvider';
}

@ProviderFor(workingOverlayService)
final workingOverlayServiceProvider = WorkingOverlayServiceFamily._();

final class WorkingOverlayServiceProvider
    extends
        $FunctionalProvider<
          WorkingOverlayService,
          WorkingOverlayService,
          WorkingOverlayService
        >
    with $Provider<WorkingOverlayService> {
  WorkingOverlayServiceProvider._({
    required WorkingOverlayServiceFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'workingOverlayServiceProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$workingOverlayServiceHash();

  @override
  String toString() {
    return r'workingOverlayServiceProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<WorkingOverlayService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  WorkingOverlayService create(Ref ref) {
    final argument = this.argument as String;
    return workingOverlayService(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(WorkingOverlayService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<WorkingOverlayService>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WorkingOverlayServiceProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$workingOverlayServiceHash() =>
    r'387e22f806d0df064e7bddd001e0b86c73c691ab';

final class WorkingOverlayServiceFamily extends $Family
    with $FunctionalFamilyOverride<WorkingOverlayService, String> {
  WorkingOverlayServiceFamily._()
    : super(
        retry: null,
        name: r'workingOverlayServiceProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  WorkingOverlayServiceProvider call(String databasePath) =>
      WorkingOverlayServiceProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'workingOverlayServiceProvider';
}

@ProviderFor(chapters)
final chaptersProvider = ChaptersFamily._();

final class ChaptersProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Chapter>>,
          List<Chapter>,
          Stream<List<Chapter>>
        >
    with $FutureModifier<List<Chapter>>, $StreamProvider<List<Chapter>> {
  ChaptersProvider._({
    required ChaptersFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'chaptersProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$chaptersHash();

  @override
  String toString() {
    return r'chaptersProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<List<Chapter>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<Chapter>> create(Ref ref) {
    final argument = this.argument as String;
    return chapters(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ChaptersProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$chaptersHash() => r'41ecf843016adadfc35e68c57eb3ee6c3df7c471';

final class ChaptersFamily extends $Family
    with $FunctionalFamilyOverride<Stream<List<Chapter>>, String> {
  ChaptersFamily._()
    : super(
        retry: null,
        name: r'chaptersProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ChaptersProvider call(String databasePath) =>
      ChaptersProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'chaptersProvider';
}

@ProviderFor(chapterTree)
final chapterTreeProvider = ChapterTreeFamily._();

final class ChapterTreeProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Chapter>>,
          List<Chapter>,
          Stream<List<Chapter>>
        >
    with $FutureModifier<List<Chapter>>, $StreamProvider<List<Chapter>> {
  ChapterTreeProvider._({
    required ChapterTreeFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'chapterTreeProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$chapterTreeHash();

  @override
  String toString() {
    return r'chapterTreeProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<List<Chapter>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<Chapter>> create(Ref ref) {
    final argument = this.argument as String;
    return chapterTree(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ChapterTreeProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$chapterTreeHash() => r'606d753abc1c3344298df96540852b3b0e6d4931';

final class ChapterTreeFamily extends $Family
    with $FunctionalFamilyOverride<Stream<List<Chapter>>, String> {
  ChapterTreeFamily._()
    : super(
        retry: null,
        name: r'chapterTreeProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ChapterTreeProvider call(String databasePath) =>
      ChapterTreeProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'chapterTreeProvider';
}

/// 当前故事状态快照（最新 active）。没有快照时发出 null。

@ProviderFor(currentStateSnapshot)
final currentStateSnapshotProvider = CurrentStateSnapshotFamily._();

/// 当前故事状态快照（最新 active）。没有快照时发出 null。

final class CurrentStateSnapshotProvider
    extends
        $FunctionalProvider<
          AsyncValue<NovelStateSnapshot?>,
          NovelStateSnapshot?,
          Stream<NovelStateSnapshot?>
        >
    with
        $FutureModifier<NovelStateSnapshot?>,
        $StreamProvider<NovelStateSnapshot?> {
  /// 当前故事状态快照（最新 active）。没有快照时发出 null。
  CurrentStateSnapshotProvider._({
    required CurrentStateSnapshotFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'currentStateSnapshotProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$currentStateSnapshotHash();

  @override
  String toString() {
    return r'currentStateSnapshotProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<NovelStateSnapshot?> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<NovelStateSnapshot?> create(Ref ref) {
    final argument = this.argument as String;
    return currentStateSnapshot(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is CurrentStateSnapshotProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$currentStateSnapshotHash() =>
    r'78d1cd73e55c6748a4b94df9ef5a43bf4b2b0acf';

/// 当前故事状态快照（最新 active）。没有快照时发出 null。

final class CurrentStateSnapshotFamily extends $Family
    with $FunctionalFamilyOverride<Stream<NovelStateSnapshot?>, String> {
  CurrentStateSnapshotFamily._()
    : super(
        retry: null,
        name: r'currentStateSnapshotProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 当前故事状态快照（最新 active）。没有快照时发出 null。

  CurrentStateSnapshotProvider call(String databasePath) =>
      CurrentStateSnapshotProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'currentStateSnapshotProvider';
}

@ProviderFor(chapterById)
final chapterByIdProvider = ChapterByIdFamily._();

final class ChapterByIdProvider
    extends
        $FunctionalProvider<AsyncValue<Chapter?>, Chapter?, Stream<Chapter?>>
    with $FutureModifier<Chapter?>, $StreamProvider<Chapter?> {
  ChapterByIdProvider._({
    required ChapterByIdFamily super.from,
    required ({String path, String chapterId}) super.argument,
  }) : super(
         retry: null,
         name: r'chapterByIdProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$chapterByIdHash();

  @override
  String toString() {
    return r'chapterByIdProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<Chapter?> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<Chapter?> create(Ref ref) {
    final argument = this.argument as ({String path, String chapterId});
    return chapterById(ref, path: argument.path, chapterId: argument.chapterId);
  }

  @override
  bool operator ==(Object other) {
    return other is ChapterByIdProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$chapterByIdHash() => r'c401277e59b5441db34f81222431d1669c3a4535';

final class ChapterByIdFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<Chapter?>,
          ({String path, String chapterId})
        > {
  ChapterByIdFamily._()
    : super(
        retry: null,
        name: r'chapterByIdProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ChapterByIdProvider call({required String path, required String chapterId}) =>
      ChapterByIdProvider._(
        argument: (path: path, chapterId: chapterId),
        from: this,
      );

  @override
  String toString() => r'chapterByIdProvider';
}

/// 编辑器正文加载专用：只含原表正文列，不含 VIEW 计算章号（章号走章节树）。
/// 避开 `chapters` VIEW 的窗口函数开销，详见 [ChapterDao.watchContentById]。

@ProviderFor(chapterContentById)
final chapterContentByIdProvider = ChapterContentByIdFamily._();

/// 编辑器正文加载专用：只含原表正文列，不含 VIEW 计算章号（章号走章节树）。
/// 避开 `chapters` VIEW 的窗口函数开销，详见 [ChapterDao.watchContentById]。

final class ChapterContentByIdProvider
    extends
        $FunctionalProvider<AsyncValue<Chapter?>, Chapter?, Stream<Chapter?>>
    with $FutureModifier<Chapter?>, $StreamProvider<Chapter?> {
  /// 编辑器正文加载专用：只含原表正文列，不含 VIEW 计算章号（章号走章节树）。
  /// 避开 `chapters` VIEW 的窗口函数开销，详见 [ChapterDao.watchContentById]。
  ChapterContentByIdProvider._({
    required ChapterContentByIdFamily super.from,
    required ({String path, String chapterId}) super.argument,
  }) : super(
         retry: null,
         name: r'chapterContentByIdProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$chapterContentByIdHash();

  @override
  String toString() {
    return r'chapterContentByIdProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<Chapter?> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<Chapter?> create(Ref ref) {
    final argument = this.argument as ({String path, String chapterId});
    return chapterContentById(
      ref,
      path: argument.path,
      chapterId: argument.chapterId,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ChapterContentByIdProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$chapterContentByIdHash() =>
    r'f3e56d467fdd85bf72cd873e09dda99bf403b5f6';

/// 编辑器正文加载专用：只含原表正文列，不含 VIEW 计算章号（章号走章节树）。
/// 避开 `chapters` VIEW 的窗口函数开销，详见 [ChapterDao.watchContentById]。

final class ChapterContentByIdFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<Chapter?>,
          ({String path, String chapterId})
        > {
  ChapterContentByIdFamily._()
    : super(
        retry: null,
        name: r'chapterContentByIdProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 编辑器正文加载专用：只含原表正文列，不含 VIEW 计算章号（章号走章节树）。
  /// 避开 `chapters` VIEW 的窗口函数开销，详见 [ChapterDao.watchContentById]。

  ChapterContentByIdProvider call({
    required String path,
    required String chapterId,
  }) => ChapterContentByIdProvider._(
    argument: (path: path, chapterId: chapterId),
    from: this,
  );

  @override
  String toString() => r'chapterContentByIdProvider';
}

@ProviderFor(lastWrittenChapter)
final lastWrittenChapterProvider = LastWrittenChapterFamily._();

final class LastWrittenChapterProvider
    extends
        $FunctionalProvider<AsyncValue<Chapter?>, Chapter?, Stream<Chapter?>>
    with $FutureModifier<Chapter?>, $StreamProvider<Chapter?> {
  LastWrittenChapterProvider._({
    required LastWrittenChapterFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'lastWrittenChapterProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$lastWrittenChapterHash();

  @override
  String toString() {
    return r'lastWrittenChapterProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<Chapter?> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<Chapter?> create(Ref ref) {
    final argument = this.argument as String;
    return lastWrittenChapter(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is LastWrittenChapterProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$lastWrittenChapterHash() =>
    r'c81fda2554152b71c0ace2dc92f7c049d2828020';

final class LastWrittenChapterFamily extends $Family
    with $FunctionalFamilyOverride<Stream<Chapter?>, String> {
  LastWrittenChapterFamily._()
    : super(
        retry: null,
        name: r'lastWrittenChapterProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  LastWrittenChapterProvider call(String databasePath) =>
      LastWrittenChapterProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'lastWrittenChapterProvider';
}

@ProviderFor(lastEditedChapter)
final lastEditedChapterProvider = LastEditedChapterFamily._();

final class LastEditedChapterProvider
    extends
        $FunctionalProvider<AsyncValue<Chapter?>, Chapter?, Stream<Chapter?>>
    with $FutureModifier<Chapter?>, $StreamProvider<Chapter?> {
  LastEditedChapterProvider._({
    required LastEditedChapterFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'lastEditedChapterProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$lastEditedChapterHash();

  @override
  String toString() {
    return r'lastEditedChapterProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<Chapter?> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<Chapter?> create(Ref ref) {
    final argument = this.argument as String;
    return lastEditedChapter(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is LastEditedChapterProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$lastEditedChapterHash() => r'e174f4531db917334446e83dee06737709e0e23d';

final class LastEditedChapterFamily extends $Family
    with $FunctionalFamilyOverride<Stream<Chapter?>, String> {
  LastEditedChapterFamily._()
    : super(
        retry: null,
        name: r'lastEditedChapterProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  LastEditedChapterProvider call(String databasePath) =>
      LastEditedChapterProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'lastEditedChapterProvider';
}

@ProviderFor(characterProfiles)
final characterProfilesProvider = CharacterProfilesFamily._();

final class CharacterProfilesProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<CharacterProfile>>,
          List<CharacterProfile>,
          Stream<List<CharacterProfile>>
        >
    with
        $FutureModifier<List<CharacterProfile>>,
        $StreamProvider<List<CharacterProfile>> {
  CharacterProfilesProvider._({
    required CharacterProfilesFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'characterProfilesProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$characterProfilesHash();

  @override
  String toString() {
    return r'characterProfilesProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<List<CharacterProfile>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<CharacterProfile>> create(Ref ref) {
    final argument = this.argument as String;
    return characterProfiles(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is CharacterProfilesProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$characterProfilesHash() => r'eb2cf2a50383b91013354440dd4b2856c38432d3';

final class CharacterProfilesFamily extends $Family
    with $FunctionalFamilyOverride<Stream<List<CharacterProfile>>, String> {
  CharacterProfilesFamily._()
    : super(
        retry: null,
        name: r'characterProfilesProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  CharacterProfilesProvider call(String databasePath) =>
      CharacterProfilesProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'characterProfilesProvider';
}

@ProviderFor(items)
final itemsProvider = ItemsFamily._();

final class ItemsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Item>>,
          List<Item>,
          Stream<List<Item>>
        >
    with $FutureModifier<List<Item>>, $StreamProvider<List<Item>> {
  ItemsProvider._({
    required ItemsFamily super.from,
    required ({String path, String type}) super.argument,
  }) : super(
         retry: null,
         name: r'itemsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$itemsHash();

  @override
  String toString() {
    return r'itemsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<Item>> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<List<Item>> create(Ref ref) {
    final argument = this.argument as ({String path, String type});
    return items(ref, path: argument.path, type: argument.type);
  }

  @override
  bool operator ==(Object other) {
    return other is ItemsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$itemsHash() => r'ec1a3fffc97b2f522b80227166ee6908ad034846';

final class ItemsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<Item>>,
          ({String path, String type})
        > {
  ItemsFamily._()
    : super(
        retry: null,
        name: r'itemsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ItemsProvider call({required String path, required String type}) =>
      ItemsProvider._(argument: (path: path, type: type), from: this);

  @override
  String toString() => r'itemsProvider';
}

@ProviderFor(foreshadowings)
final foreshadowingsProvider = ForeshadowingsFamily._();

final class ForeshadowingsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Foreshadowing>>,
          List<Foreshadowing>,
          Stream<List<Foreshadowing>>
        >
    with
        $FutureModifier<List<Foreshadowing>>,
        $StreamProvider<List<Foreshadowing>> {
  ForeshadowingsProvider._({
    required ForeshadowingsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'foreshadowingsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$foreshadowingsHash();

  @override
  String toString() {
    return r'foreshadowingsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<List<Foreshadowing>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<Foreshadowing>> create(Ref ref) {
    final argument = this.argument as String;
    return foreshadowings(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ForeshadowingsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$foreshadowingsHash() => r'1754de4a217753d87e4c78faed2bfdfd8d2d6c61';

final class ForeshadowingsFamily extends $Family
    with $FunctionalFamilyOverride<Stream<List<Foreshadowing>>, String> {
  ForeshadowingsFamily._()
    : super(
        retry: null,
        name: r'foreshadowingsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ForeshadowingsProvider call(String databasePath) =>
      ForeshadowingsProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'foreshadowingsProvider';
}

@ProviderFor(workingChanges)
final workingChangesProvider = WorkingChangesFamily._();

final class WorkingChangesProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<WorkingChange>>,
          List<WorkingChange>,
          Stream<List<WorkingChange>>
        >
    with
        $FutureModifier<List<WorkingChange>>,
        $StreamProvider<List<WorkingChange>> {
  WorkingChangesProvider._({
    required WorkingChangesFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'workingChangesProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$workingChangesHash();

  @override
  String toString() {
    return r'workingChangesProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<List<WorkingChange>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<WorkingChange>> create(Ref ref) {
    final argument = this.argument as String;
    return workingChanges(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is WorkingChangesProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$workingChangesHash() => r'16d4f6623289d795e770361069aa035cac215d0a';

final class WorkingChangesFamily extends $Family
    with $FunctionalFamilyOverride<Stream<List<WorkingChange>>, String> {
  WorkingChangesFamily._()
    : super(
        retry: null,
        name: r'workingChangesProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  WorkingChangesProvider call(String databasePath) =>
      WorkingChangesProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'workingChangesProvider';
}

@ProviderFor(sessionChanges)
final sessionChangesProvider = SessionChangesFamily._();

final class SessionChangesProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<WorkingChange>>,
          List<WorkingChange>,
          Stream<List<WorkingChange>>
        >
    with
        $FutureModifier<List<WorkingChange>>,
        $StreamProvider<List<WorkingChange>> {
  SessionChangesProvider._({
    required SessionChangesFamily super.from,
    required (String, String?) super.argument,
  }) : super(
         retry: null,
         name: r'sessionChangesProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$sessionChangesHash();

  @override
  String toString() {
    return r'sessionChangesProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<WorkingChange>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<WorkingChange>> create(Ref ref) {
    final argument = this.argument as (String, String?);
    return sessionChanges(ref, argument.$1, argument.$2);
  }

  @override
  bool operator ==(Object other) {
    return other is SessionChangesProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$sessionChangesHash() => r'9a220b23a867efcc3de02a95d8f3464071efef89';

final class SessionChangesFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<WorkingChange>>,
          (String, String?)
        > {
  SessionChangesFamily._()
    : super(
        retry: null,
        name: r'sessionChangesProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  SessionChangesProvider call(String databasePath, String? sessionId) =>
      SessionChangesProvider._(argument: (databasePath, sessionId), from: this);

  @override
  String toString() => r'sessionChangesProvider';
}

/// 只订阅审阅涉及的资源表；直接手动编辑也会使右侧快照刷新。

@ProviderFor(workingFieldReviews)
final workingFieldReviewsProvider = WorkingFieldReviewsFamily._();

/// 只订阅审阅涉及的资源表；直接手动编辑也会使右侧快照刷新。

final class WorkingFieldReviewsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<WorkingFieldReview>>,
          List<WorkingFieldReview>,
          Stream<List<WorkingFieldReview>>
        >
    with
        $FutureModifier<List<WorkingFieldReview>>,
        $StreamProvider<List<WorkingFieldReview>> {
  /// 只订阅审阅涉及的资源表；直接手动编辑也会使右侧快照刷新。
  WorkingFieldReviewsProvider._({
    required WorkingFieldReviewsFamily super.from,
    required (String, List<WorkingChange>) super.argument,
  }) : super(
         retry: null,
         name: r'workingFieldReviewsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$workingFieldReviewsHash();

  @override
  String toString() {
    return r'workingFieldReviewsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<WorkingFieldReview>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<WorkingFieldReview>> create(Ref ref) {
    final argument = this.argument as (String, List<WorkingChange>);
    return workingFieldReviews(ref, argument.$1, argument.$2);
  }

  @override
  bool operator ==(Object other) {
    return other is WorkingFieldReviewsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$workingFieldReviewsHash() =>
    r'26cf0e1f66687ece1d091947f9f9df3ff2a58b90';

/// 只订阅审阅涉及的资源表；直接手动编辑也会使右侧快照刷新。

final class WorkingFieldReviewsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<WorkingFieldReview>>,
          (String, List<WorkingChange>)
        > {
  WorkingFieldReviewsFamily._()
    : super(
        retry: null,
        name: r'workingFieldReviewsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 只订阅审阅涉及的资源表；直接手动编辑也会使右侧快照刷新。

  WorkingFieldReviewsProvider call(
    String databasePath,
    List<WorkingChange> changes,
  ) => WorkingFieldReviewsProvider._(
    argument: (databasePath, changes),
    from: this,
  );

  @override
  String toString() => r'workingFieldReviewsProvider';
}

@ProviderFor(changeCommits)
final changeCommitsProvider = ChangeCommitsFamily._();

final class ChangeCommitsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ChangeCommit>>,
          List<ChangeCommit>,
          Stream<List<ChangeCommit>>
        >
    with
        $FutureModifier<List<ChangeCommit>>,
        $StreamProvider<List<ChangeCommit>> {
  ChangeCommitsProvider._({
    required ChangeCommitsFamily super.from,
    required ({String path, int? limit}) super.argument,
  }) : super(
         retry: null,
         name: r'changeCommitsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$changeCommitsHash();

  @override
  String toString() {
    return r'changeCommitsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<ChangeCommit>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<ChangeCommit>> create(Ref ref) {
    final argument = this.argument as ({String path, int? limit});
    return changeCommits(ref, path: argument.path, limit: argument.limit);
  }

  @override
  bool operator ==(Object other) {
    return other is ChangeCommitsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$changeCommitsHash() => r'eefd28ffe1eec5620a6daeee0a8aa6f0c28e8aeb';

final class ChangeCommitsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<ChangeCommit>>,
          ({String path, int? limit})
        > {
  ChangeCommitsFamily._()
    : super(
        retry: null,
        name: r'changeCommitsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ChangeCommitsProvider call({required String path, int? limit}) =>
      ChangeCommitsProvider._(argument: (path: path, limit: limit), from: this);

  @override
  String toString() => r'changeCommitsProvider';
}

@ProviderFor(changeCommitItems)
final changeCommitItemsProvider = ChangeCommitItemsFamily._();

final class ChangeCommitItemsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ChangeCommitItem>>,
          List<ChangeCommitItem>,
          FutureOr<List<ChangeCommitItem>>
        >
    with
        $FutureModifier<List<ChangeCommitItem>>,
        $FutureProvider<List<ChangeCommitItem>> {
  ChangeCommitItemsProvider._({
    required ChangeCommitItemsFamily super.from,
    required ({String path, String commitId}) super.argument,
  }) : super(
         retry: null,
         name: r'changeCommitItemsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$changeCommitItemsHash();

  @override
  String toString() {
    return r'changeCommitItemsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<List<ChangeCommitItem>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<ChangeCommitItem>> create(Ref ref) {
    final argument = this.argument as ({String path, String commitId});
    return changeCommitItems(
      ref,
      path: argument.path,
      commitId: argument.commitId,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ChangeCommitItemsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$changeCommitItemsHash() => r'3e5ab450ca1e9eba30158eef7e9fbc9201b7c7ee';

final class ChangeCommitItemsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<ChangeCommitItem>>,
          ({String path, String commitId})
        > {
  ChangeCommitItemsFamily._()
    : super(
        retry: null,
        name: r'changeCommitItemsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ChangeCommitItemsProvider call({
    required String path,
    required String commitId,
  }) => ChangeCommitItemsProvider._(
    argument: (path: path, commitId: commitId),
    from: this,
  );

  @override
  String toString() => r'changeCommitItemsProvider';
}

@ProviderFor(changeCommitResourceItems)
final changeCommitResourceItemsProvider = ChangeCommitResourceItemsFamily._();

final class ChangeCommitResourceItemsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ChangeCommitItem>>,
          List<ChangeCommitItem>,
          FutureOr<List<ChangeCommitItem>>
        >
    with
        $FutureModifier<List<ChangeCommitItem>>,
        $FutureProvider<List<ChangeCommitItem>> {
  ChangeCommitResourceItemsProvider._({
    required ChangeCommitResourceItemsFamily super.from,
    required ({String path, String commitId, String resourceId}) super.argument,
  }) : super(
         retry: null,
         name: r'changeCommitResourceItemsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$changeCommitResourceItemsHash();

  @override
  String toString() {
    return r'changeCommitResourceItemsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<List<ChangeCommitItem>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<ChangeCommitItem>> create(Ref ref) {
    final argument =
        this.argument as ({String path, String commitId, String resourceId});
    return changeCommitResourceItems(
      ref,
      path: argument.path,
      commitId: argument.commitId,
      resourceId: argument.resourceId,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ChangeCommitResourceItemsProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$changeCommitResourceItemsHash() =>
    r'6a738764e78c244f3ff1ef607ad0a9e179cd3e57';

final class ChangeCommitResourceItemsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<ChangeCommitItem>>,
          ({String path, String commitId, String resourceId})
        > {
  ChangeCommitResourceItemsFamily._()
    : super(
        retry: null,
        name: r'changeCommitResourceItemsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ChangeCommitResourceItemsProvider call({
    required String path,
    required String commitId,
    required String resourceId,
  }) => ChangeCommitResourceItemsProvider._(
    argument: (path: path, commitId: commitId, resourceId: resourceId),
    from: this,
  );

  @override
  String toString() => r'changeCommitResourceItemsProvider';
}

@ProviderFor(resourceChangeHistory)
final resourceChangeHistoryProvider = ResourceChangeHistoryFamily._();

final class ResourceChangeHistoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ChangeCommitItem>>,
          List<ChangeCommitItem>,
          FutureOr<List<ChangeCommitItem>>
        >
    with
        $FutureModifier<List<ChangeCommitItem>>,
        $FutureProvider<List<ChangeCommitItem>> {
  ResourceChangeHistoryProvider._({
    required ResourceChangeHistoryFamily super.from,
    required ({String path, String resourcePath, int? limit}) super.argument,
  }) : super(
         retry: null,
         name: r'resourceChangeHistoryProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$resourceChangeHistoryHash();

  @override
  String toString() {
    return r'resourceChangeHistoryProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<List<ChangeCommitItem>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<ChangeCommitItem>> create(Ref ref) {
    final argument =
        this.argument as ({String path, String resourcePath, int? limit});
    return resourceChangeHistory(
      ref,
      path: argument.path,
      resourcePath: argument.resourcePath,
      limit: argument.limit,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ResourceChangeHistoryProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$resourceChangeHistoryHash() =>
    r'899322893be596960d75c024a2d4e60a55ca2035';

final class ResourceChangeHistoryFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<ChangeCommitItem>>,
          ({String path, String resourcePath, int? limit})
        > {
  ResourceChangeHistoryFamily._()
    : super(
        retry: null,
        name: r'resourceChangeHistoryProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ResourceChangeHistoryProvider call({
    required String path,
    required String resourcePath,
    int? limit,
  }) => ResourceChangeHistoryProvider._(
    argument: (path: path, resourcePath: resourcePath, limit: limit),
    from: this,
  );

  @override
  String toString() => r'resourceChangeHistoryProvider';
}

@ProviderFor(resourceIdChangeHistory)
final resourceIdChangeHistoryProvider = ResourceIdChangeHistoryFamily._();

final class ResourceIdChangeHistoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ChangeCommitItem>>,
          List<ChangeCommitItem>,
          FutureOr<List<ChangeCommitItem>>
        >
    with
        $FutureModifier<List<ChangeCommitItem>>,
        $FutureProvider<List<ChangeCommitItem>> {
  ResourceIdChangeHistoryProvider._({
    required ResourceIdChangeHistoryFamily super.from,
    required ({String path, String resourceId, int? limit}) super.argument,
  }) : super(
         retry: null,
         name: r'resourceIdChangeHistoryProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$resourceIdChangeHistoryHash();

  @override
  String toString() {
    return r'resourceIdChangeHistoryProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<List<ChangeCommitItem>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<ChangeCommitItem>> create(Ref ref) {
    final argument =
        this.argument as ({String path, String resourceId, int? limit});
    return resourceIdChangeHistory(
      ref,
      path: argument.path,
      resourceId: argument.resourceId,
      limit: argument.limit,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ResourceIdChangeHistoryProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$resourceIdChangeHistoryHash() =>
    r'3817726f389e4a894c67c5d04900e7ba24769fcb';

final class ResourceIdChangeHistoryFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<ChangeCommitItem>>,
          ({String path, String resourceId, int? limit})
        > {
  ResourceIdChangeHistoryFamily._()
    : super(
        retry: null,
        name: r'resourceIdChangeHistoryProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ResourceIdChangeHistoryProvider call({
    required String path,
    required String resourceId,
    int? limit,
  }) => ResourceIdChangeHistoryProvider._(
    argument: (path: path, resourceId: resourceId, limit: limit),
    from: this,
  );

  @override
  String toString() => r'resourceIdChangeHistoryProvider';
}

@ProviderFor(aiSessionPersistenceService)
final aiSessionPersistenceServiceProvider =
    AiSessionPersistenceServiceFamily._();

final class AiSessionPersistenceServiceProvider
    extends
        $FunctionalProvider<
          AiSessionPersistenceService,
          AiSessionPersistenceService,
          AiSessionPersistenceService
        >
    with $Provider<AiSessionPersistenceService> {
  AiSessionPersistenceServiceProvider._({
    required AiSessionPersistenceServiceFamily super.from,
    required ({String novelId, String? databasePath}) super.argument,
  }) : super(
         retry: null,
         name: r'aiSessionPersistenceServiceProvider',
         isAutoDispose: false,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiSessionPersistenceServiceHash();

  @override
  String toString() {
    return r'aiSessionPersistenceServiceProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $ProviderElement<AiSessionPersistenceService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiSessionPersistenceService create(Ref ref) {
    final argument = this.argument as ({String novelId, String? databasePath});
    return aiSessionPersistenceService(
      ref,
      novelId: argument.novelId,
      databasePath: argument.databasePath,
    );
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiSessionPersistenceService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiSessionPersistenceService>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiSessionPersistenceServiceProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiSessionPersistenceServiceHash() =>
    r'fb664400c95c251968a280474e3ecd7e8801270d';

final class AiSessionPersistenceServiceFamily extends $Family
    with
        $FunctionalFamilyOverride<
          AiSessionPersistenceService,
          ({String novelId, String? databasePath})
        > {
  AiSessionPersistenceServiceFamily._()
    : super(
        retry: null,
        name: r'aiSessionPersistenceServiceProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: false,
      );

  AiSessionPersistenceServiceProvider call({
    required String novelId,
    String? databasePath,
  }) => AiSessionPersistenceServiceProvider._(
    argument: (novelId: novelId, databasePath: databasePath),
    from: this,
  );

  @override
  String toString() => r'aiSessionPersistenceServiceProvider';
}

@ProviderFor(aiChatSessions)
final aiChatSessionsProvider = AiChatSessionsFamily._();

final class AiChatSessionsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<AiChatSession>>,
          List<AiChatSession>,
          Stream<List<AiChatSession>>
        >
    with
        $FutureModifier<List<AiChatSession>>,
        $StreamProvider<List<AiChatSession>> {
  AiChatSessionsProvider._({
    required AiChatSessionsFamily super.from,
    required ({String novelId, String? databasePath}) super.argument,
  }) : super(
         retry: null,
         name: r'aiChatSessionsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiChatSessionsHash();

  @override
  String toString() {
    return r'aiChatSessionsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<AiChatSession>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<AiChatSession>> create(Ref ref) {
    final argument = this.argument as ({String novelId, String? databasePath});
    return aiChatSessions(
      ref,
      novelId: argument.novelId,
      databasePath: argument.databasePath,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiChatSessionsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiChatSessionsHash() => r'de02f213dae98fc72515764f0955efacee22075f';

final class AiChatSessionsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<AiChatSession>>,
          ({String novelId, String? databasePath})
        > {
  AiChatSessionsFamily._()
    : super(
        retry: null,
        name: r'aiChatSessionsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  AiChatSessionsProvider call({
    required String novelId,
    String? databasePath,
  }) => AiChatSessionsProvider._(
    argument: (novelId: novelId, databasePath: databasePath),
    from: this,
  );

  @override
  String toString() => r'aiChatSessionsProvider';
}

/// 当前小说的 chat 会话总数（不含 council / monologue / theater / roleplay）。
///
/// 用于 setup_phase 门控等只需数量的场景；用 SQL COUNT，不加载会话列表。

@ProviderFor(novelChatSessionCount)
final novelChatSessionCountProvider = NovelChatSessionCountFamily._();

/// 当前小说的 chat 会话总数（不含 council / monologue / theater / roleplay）。
///
/// 用于 setup_phase 门控等只需数量的场景；用 SQL COUNT，不加载会话列表。

final class NovelChatSessionCountProvider
    extends $FunctionalProvider<AsyncValue<int>, int, Stream<int>>
    with $FutureModifier<int>, $StreamProvider<int> {
  /// 当前小说的 chat 会话总数（不含 council / monologue / theater / roleplay）。
  ///
  /// 用于 setup_phase 门控等只需数量的场景；用 SQL COUNT，不加载会话列表。
  NovelChatSessionCountProvider._({
    required NovelChatSessionCountFamily super.from,
    required ({String novelId, String? databasePath}) super.argument,
  }) : super(
         retry: null,
         name: r'novelChatSessionCountProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$novelChatSessionCountHash();

  @override
  String toString() {
    return r'novelChatSessionCountProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<int> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<int> create(Ref ref) {
    final argument = this.argument as ({String novelId, String? databasePath});
    return novelChatSessionCount(
      ref,
      novelId: argument.novelId,
      databasePath: argument.databasePath,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is NovelChatSessionCountProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$novelChatSessionCountHash() =>
    r'935a8b8e3016950fcd4e1de82763a3fcba40f32f';

/// 当前小说的 chat 会话总数（不含 council / monologue / theater / roleplay）。
///
/// 用于 setup_phase 门控等只需数量的场景；用 SQL COUNT，不加载会话列表。

final class NovelChatSessionCountFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<int>,
          ({String novelId, String? databasePath})
        > {
  NovelChatSessionCountFamily._()
    : super(
        retry: null,
        name: r'novelChatSessionCountProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 当前小说的 chat 会话总数（不含 council / monologue / theater / roleplay）。
  ///
  /// 用于 setup_phase 门控等只需数量的场景；用 SQL COUNT，不加载会话列表。

  NovelChatSessionCountProvider call({
    required String novelId,
    String? databasePath,
  }) => NovelChatSessionCountProvider._(
    argument: (novelId: novelId, databasePath: databasePath),
    from: this,
  );

  @override
  String toString() => r'novelChatSessionCountProvider';
}

@ProviderFor(aiChatSessionsPage)
final aiChatSessionsPageProvider = AiChatSessionsPageFamily._();

final class AiChatSessionsPageProvider
    extends
        $FunctionalProvider<
          AsyncValue<({bool hasMore, List<AiChatSession> sessions})>,
          ({bool hasMore, List<AiChatSession> sessions}),
          Stream<({bool hasMore, List<AiChatSession> sessions})>
        >
    with
        $FutureModifier<({bool hasMore, List<AiChatSession> sessions})>,
        $StreamProvider<({bool hasMore, List<AiChatSession> sessions})> {
  AiChatSessionsPageProvider._({
    required AiChatSessionsPageFamily super.from,
    required ({String novelId, String? databasePath, int limit}) super.argument,
  }) : super(
         retry: null,
         name: r'aiChatSessionsPageProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiChatSessionsPageHash();

  @override
  String toString() {
    return r'aiChatSessionsPageProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<({bool hasMore, List<AiChatSession> sessions})>
  $createElement($ProviderPointer pointer) => $StreamProviderElement(pointer);

  @override
  Stream<({bool hasMore, List<AiChatSession> sessions})> create(Ref ref) {
    final argument =
        this.argument as ({String novelId, String? databasePath, int limit});
    return aiChatSessionsPage(
      ref,
      novelId: argument.novelId,
      databasePath: argument.databasePath,
      limit: argument.limit,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiChatSessionsPageProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiChatSessionsPageHash() =>
    r'28b232eb88f135010c19a04699c53de7d485fe79';

final class AiChatSessionsPageFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<({bool hasMore, List<AiChatSession> sessions})>,
          ({String novelId, String? databasePath, int limit})
        > {
  AiChatSessionsPageFamily._()
    : super(
        retry: null,
        name: r'aiChatSessionsPageProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  AiChatSessionsPageProvider call({
    required String novelId,
    String? databasePath,
    required int limit,
  }) => AiChatSessionsPageProvider._(
    argument: (novelId: novelId, databasePath: databasePath, limit: limit),
    from: this,
  );

  @override
  String toString() => r'aiChatSessionsPageProvider';
}

/// 监听当前 novel 在 `novel_states` 表中持久化的 active chat session id。
///
/// 进入 NovelEditor 时若 `initialSessionId` 为空，应优先使用该 id 还原上次
/// active 的 chat 会话，而不是 fallback 到「最近更新」的会话。

@ProviderFor(activeChatSessionId)
final activeChatSessionIdProvider = ActiveChatSessionIdFamily._();

/// 监听当前 novel 在 `novel_states` 表中持久化的 active chat session id。
///
/// 进入 NovelEditor 时若 `initialSessionId` 为空，应优先使用该 id 还原上次
/// active 的 chat 会话，而不是 fallback 到「最近更新」的会话。

final class ActiveChatSessionIdProvider
    extends $FunctionalProvider<AsyncValue<String?>, String?, Stream<String?>>
    with $FutureModifier<String?>, $StreamProvider<String?> {
  /// 监听当前 novel 在 `novel_states` 表中持久化的 active chat session id。
  ///
  /// 进入 NovelEditor 时若 `initialSessionId` 为空，应优先使用该 id 还原上次
  /// active 的 chat 会话，而不是 fallback 到「最近更新」的会话。
  ActiveChatSessionIdProvider._({
    required ActiveChatSessionIdFamily super.from,
    required ({String novelId, String? databasePath}) super.argument,
  }) : super(
         retry: null,
         name: r'activeChatSessionIdProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$activeChatSessionIdHash();

  @override
  String toString() {
    return r'activeChatSessionIdProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<String?> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<String?> create(Ref ref) {
    final argument = this.argument as ({String novelId, String? databasePath});
    return activeChatSessionId(
      ref,
      novelId: argument.novelId,
      databasePath: argument.databasePath,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ActiveChatSessionIdProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$activeChatSessionIdHash() =>
    r'463a20356fe13638be07c14ce3997be4b66c3722';

/// 监听当前 novel 在 `novel_states` 表中持久化的 active chat session id。
///
/// 进入 NovelEditor 时若 `initialSessionId` 为空，应优先使用该 id 还原上次
/// active 的 chat 会话，而不是 fallback 到「最近更新」的会话。

final class ActiveChatSessionIdFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<String?>,
          ({String novelId, String? databasePath})
        > {
  ActiveChatSessionIdFamily._()
    : super(
        retry: null,
        name: r'activeChatSessionIdProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 监听当前 novel 在 `novel_states` 表中持久化的 active chat session id。
  ///
  /// 进入 NovelEditor 时若 `initialSessionId` 为空，应优先使用该 id 还原上次
  /// active 的 chat 会话，而不是 fallback 到「最近更新」的会话。

  ActiveChatSessionIdProvider call({
    required String novelId,
    String? databasePath,
  }) => ActiveChatSessionIdProvider._(
    argument: (novelId: novelId, databasePath: databasePath),
    from: this,
  );

  @override
  String toString() => r'activeChatSessionIdProvider';
}

@ProviderFor(aiChatSessionsByMode)
final aiChatSessionsByModeProvider = AiChatSessionsByModeFamily._();

final class AiChatSessionsByModeProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<AiChatSession>>,
          List<AiChatSession>,
          Stream<List<AiChatSession>>
        >
    with
        $FutureModifier<List<AiChatSession>>,
        $StreamProvider<List<AiChatSession>> {
  AiChatSessionsByModeProvider._({
    required AiChatSessionsByModeFamily super.from,
    required ({String novelId, String? databasePath, String mode})
    super.argument,
  }) : super(
         retry: null,
         name: r'aiChatSessionsByModeProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiChatSessionsByModeHash();

  @override
  String toString() {
    return r'aiChatSessionsByModeProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<AiChatSession>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<AiChatSession>> create(Ref ref) {
    final argument =
        this.argument as ({String novelId, String? databasePath, String mode});
    return aiChatSessionsByMode(
      ref,
      novelId: argument.novelId,
      databasePath: argument.databasePath,
      mode: argument.mode,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiChatSessionsByModeProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiChatSessionsByModeHash() =>
    r'cf3dbbcab9368e06a025d4dac0489812a92534e9';

final class AiChatSessionsByModeFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<AiChatSession>>,
          ({String novelId, String? databasePath, String mode})
        > {
  AiChatSessionsByModeFamily._()
    : super(
        retry: null,
        name: r'aiChatSessionsByModeProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  AiChatSessionsByModeProvider call({
    required String novelId,
    String? databasePath,
    required String mode,
  }) => AiChatSessionsByModeProvider._(
    argument: (novelId: novelId, databasePath: databasePath, mode: mode),
    from: this,
  );

  @override
  String toString() => r'aiChatSessionsByModeProvider';
}

@ProviderFor(documents)
final documentsProvider = DocumentsFamily._();

final class DocumentsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Document>>,
          List<Document>,
          Stream<List<Document>>
        >
    with $FutureModifier<List<Document>>, $StreamProvider<List<Document>> {
  DocumentsProvider._({
    required DocumentsFamily super.from,
    required ({String path, String type}) super.argument,
  }) : super(
         retry: null,
         name: r'documentsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$documentsHash();

  @override
  String toString() {
    return r'documentsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<Document>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<Document>> create(Ref ref) {
    final argument = this.argument as ({String path, String type});
    return documents(ref, path: argument.path, type: argument.type);
  }

  @override
  bool operator ==(Object other) {
    return other is DocumentsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$documentsHash() => r'ef14db751a0a28e92fa6579a248cf0f230388c9d';

final class DocumentsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<Document>>,
          ({String path, String type})
        > {
  DocumentsFamily._()
    : super(
        retry: null,
        name: r'documentsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  DocumentsProvider call({required String path, required String type}) =>
      DocumentsProvider._(argument: (path: path, type: type), from: this);

  @override
  String toString() => r'documentsProvider';
}

@ProviderFor(outlines)
final outlinesProvider = OutlinesFamily._();

final class OutlinesProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<OutlineDraft>>,
          List<OutlineDraft>,
          Stream<List<OutlineDraft>>
        >
    with
        $FutureModifier<List<OutlineDraft>>,
        $StreamProvider<List<OutlineDraft>> {
  OutlinesProvider._({
    required OutlinesFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'outlinesProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$outlinesHash();

  @override
  String toString() {
    return r'outlinesProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $StreamProviderElement<List<OutlineDraft>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<OutlineDraft>> create(Ref ref) {
    final argument = this.argument as String;
    return outlines(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is OutlinesProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$outlinesHash() => r'b7ea8102a19ece8cdc590766069eaed3d346d6ee';

final class OutlinesFamily extends $Family
    with $FunctionalFamilyOverride<Stream<List<OutlineDraft>>, String> {
  OutlinesFamily._()
    : super(
        retry: null,
        name: r'outlinesProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  OutlinesProvider call(String databasePath) =>
      OutlinesProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'outlinesProvider';
}

@ProviderFor(outline)
final outlineProvider = OutlineFamily._();

final class OutlineProvider
    extends
        $FunctionalProvider<
          AsyncValue<OutlineDraft?>,
          OutlineDraft?,
          Stream<OutlineDraft?>
        >
    with $FutureModifier<OutlineDraft?>, $StreamProvider<OutlineDraft?> {
  OutlineProvider._({
    required OutlineFamily super.from,
    required ({String path, String documentId}) super.argument,
  }) : super(
         retry: null,
         name: r'outlineProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$outlineHash();

  @override
  String toString() {
    return r'outlineProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<OutlineDraft?> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<OutlineDraft?> create(Ref ref) {
    final argument = this.argument as ({String path, String documentId});
    return outline(ref, path: argument.path, documentId: argument.documentId);
  }

  @override
  bool operator ==(Object other) {
    return other is OutlineProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$outlineHash() => r'e83d4140a316286e5869c5a54b9ff13ad2659d6c';

final class OutlineFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<OutlineDraft?>,
          ({String path, String documentId})
        > {
  OutlineFamily._()
    : super(
        retry: null,
        name: r'outlineProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  OutlineProvider call({required String path, required String documentId}) =>
      OutlineProvider._(
        argument: (path: path, documentId: documentId),
        from: this,
      );

  @override
  String toString() => r'outlineProvider';
}

@ProviderFor(entityRelations)
final entityRelationsProvider = EntityRelationsFamily._();

final class EntityRelationsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<RelationSummary>>,
          List<RelationSummary>,
          Stream<List<RelationSummary>>
        >
    with
        $FutureModifier<List<RelationSummary>>,
        $StreamProvider<List<RelationSummary>> {
  EntityRelationsProvider._({
    required EntityRelationsFamily super.from,
    required ({
      String path,
      String entityType,
      String entityId,
      String? relationType,
    })
    super.argument,
  }) : super(
         retry: null,
         name: r'entityRelationsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$entityRelationsHash();

  @override
  String toString() {
    return r'entityRelationsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $StreamProviderElement<List<RelationSummary>> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<List<RelationSummary>> create(Ref ref) {
    final argument =
        this.argument
            as ({
              String path,
              String entityType,
              String entityId,
              String? relationType,
            });
    return entityRelations(
      ref,
      path: argument.path,
      entityType: argument.entityType,
      entityId: argument.entityId,
      relationType: argument.relationType,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is EntityRelationsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$entityRelationsHash() => r'b45ec3e6f34f231ded59d28c2002b9b81e8c2cd3';

final class EntityRelationsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          Stream<List<RelationSummary>>,
          ({
            String path,
            String entityType,
            String entityId,
            String? relationType,
          })
        > {
  EntityRelationsFamily._()
    : super(
        retry: null,
        name: r'entityRelationsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  EntityRelationsProvider call({
    required String path,
    required String entityType,
    required String entityId,
    String? relationType,
  }) => EntityRelationsProvider._(
    argument: (
      path: path,
      entityType: entityType,
      entityId: entityId,
      relationType: relationType,
    ),
    from: this,
  );

  @override
  String toString() => r'entityRelationsProvider';
}
