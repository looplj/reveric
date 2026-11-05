// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cover_studio_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 配置图片模型后可进入封面工作台。

@ProviderFor(canOpenCoverStudio)
final canOpenCoverStudioProvider = CanOpenCoverStudioProvider._();

/// 配置图片模型后可进入封面工作台。

final class CanOpenCoverStudioProvider
    extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  /// 配置图片模型后可进入封面工作台。
  CanOpenCoverStudioProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'canOpenCoverStudioProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$canOpenCoverStudioHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return canOpenCoverStudio(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$canOpenCoverStudioHash() =>
    r'dfe247e4ef9faae5182d30310363c73a55fe7914';

@ProviderFor(CoverStudioController)
final coverStudioControllerProvider = CoverStudioControllerFamily._();

final class CoverStudioControllerProvider
    extends $NotifierProvider<CoverStudioController, CoverStudioState> {
  CoverStudioControllerProvider._({
    required CoverStudioControllerFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'coverStudioControllerProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$coverStudioControllerHash();

  @override
  String toString() {
    return r'coverStudioControllerProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  CoverStudioController create() => CoverStudioController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CoverStudioState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CoverStudioState>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CoverStudioControllerProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$coverStudioControllerHash() =>
    r'536811c60b46991de9654841770500d999d5cf74';

final class CoverStudioControllerFamily extends $Family
    with
        $ClassFamilyOverride<
          CoverStudioController,
          CoverStudioState,
          CoverStudioState,
          CoverStudioState,
          String
        > {
  CoverStudioControllerFamily._()
    : super(
        retry: null,
        name: r'coverStudioControllerProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  CoverStudioControllerProvider call(String novelId) =>
      CoverStudioControllerProvider._(argument: novelId, from: this);

  @override
  String toString() => r'coverStudioControllerProvider';
}

abstract class _$CoverStudioController extends $Notifier<CoverStudioState> {
  late final _$args = ref.$arg as String;
  String get novelId => _$args;

  CoverStudioState build(String novelId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<CoverStudioState, CoverStudioState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<CoverStudioState, CoverStudioState>,
              CoverStudioState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}

/// 指定批次的格子视图，按序号排好。
///
/// 同步 provider 而不是自己合流两个 Stream：Riverpod 已经在管这两个 watch 的
/// 订阅与重算，手写 StreamController 只是把生命周期又扛回自己身上。

@ProviderFor(coverSlotViews)
final coverSlotViewsProvider = CoverSlotViewsFamily._();

/// 指定批次的格子视图，按序号排好。
///
/// 同步 provider 而不是自己合流两个 Stream：Riverpod 已经在管这两个 watch 的
/// 订阅与重算，手写 StreamController 只是把生命周期又扛回自己身上。

final class CoverSlotViewsProvider
    extends
        $FunctionalProvider<
          List<CoverSlotView>,
          List<CoverSlotView>,
          List<CoverSlotView>
        >
    with $Provider<List<CoverSlotView>> {
  /// 指定批次的格子视图，按序号排好。
  ///
  /// 同步 provider 而不是自己合流两个 Stream：Riverpod 已经在管这两个 watch 的
  /// 订阅与重算，手写 StreamController 只是把生命周期又扛回自己身上。
  CoverSlotViewsProvider._({
    required CoverSlotViewsFamily super.from,
    required (String, String?) super.argument,
  }) : super(
         retry: null,
         name: r'coverSlotViewsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$coverSlotViewsHash();

  @override
  String toString() {
    return r'coverSlotViewsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $ProviderElement<List<CoverSlotView>> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  List<CoverSlotView> create(Ref ref) {
    final argument = this.argument as (String, String?);
    return coverSlotViews(ref, argument.$1, argument.$2);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<CoverSlotView> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<CoverSlotView>>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CoverSlotViewsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$coverSlotViewsHash() => r'd12565efe3734bcca19368487c4b2a1df3905112';

/// 指定批次的格子视图，按序号排好。
///
/// 同步 provider 而不是自己合流两个 Stream：Riverpod 已经在管这两个 watch 的
/// 订阅与重算，手写 StreamController 只是把生命周期又扛回自己身上。

final class CoverSlotViewsFamily extends $Family
    with $FunctionalFamilyOverride<List<CoverSlotView>, (String, String?)> {
  CoverSlotViewsFamily._()
    : super(
        retry: null,
        name: r'coverSlotViewsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 指定批次的格子视图，按序号排好。
  ///
  /// 同步 provider 而不是自己合流两个 Stream：Riverpod 已经在管这两个 watch 的
  /// 订阅与重算，手写 StreamController 只是把生命周期又扛回自己身上。

  CoverSlotViewsProvider call(String batchId, String? novelId) =>
      CoverSlotViewsProvider._(argument: (batchId, novelId), from: this);

  @override
  String toString() => r'coverSlotViewsProvider';
}
