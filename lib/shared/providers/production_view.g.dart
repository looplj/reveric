// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'production_view.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 制片页当前视图，由左栏入口和制片页共同驱动。
///
/// 左栏写入目标视图，制片页监听后带着焦点切换；切换被拒（编辑未保存等）时
/// 制片页把状态写回实际视图。保活以便离开制片分区后再回来仍停在上次的视图。

@ProviderFor(ProductionView)
final productionViewProvider = ProductionViewFamily._();

/// 制片页当前视图，由左栏入口和制片页共同驱动。
///
/// 左栏写入目标视图，制片页监听后带着焦点切换；切换被拒（编辑未保存等）时
/// 制片页把状态写回实际视图。保活以便离开制片分区后再回来仍停在上次的视图。
final class ProductionViewProvider
    extends $NotifierProvider<ProductionView, ProductionViewMode> {
  /// 制片页当前视图，由左栏入口和制片页共同驱动。
  ///
  /// 左栏写入目标视图，制片页监听后带着焦点切换；切换被拒（编辑未保存等）时
  /// 制片页把状态写回实际视图。保活以便离开制片分区后再回来仍停在上次的视图。
  ProductionViewProvider._({
    required ProductionViewFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'productionViewProvider',
         isAutoDispose: false,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$productionViewHash();

  @override
  String toString() {
    return r'productionViewProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  ProductionView create() => ProductionView();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ProductionViewMode value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ProductionViewMode>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ProductionViewProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$productionViewHash() => r'5a3f86e6db77430798d6cc9db684b4153c7e149e';

/// 制片页当前视图，由左栏入口和制片页共同驱动。
///
/// 左栏写入目标视图，制片页监听后带着焦点切换；切换被拒（编辑未保存等）时
/// 制片页把状态写回实际视图。保活以便离开制片分区后再回来仍停在上次的视图。

final class ProductionViewFamily extends $Family
    with
        $ClassFamilyOverride<
          ProductionView,
          ProductionViewMode,
          ProductionViewMode,
          ProductionViewMode,
          String
        > {
  ProductionViewFamily._()
    : super(
        retry: null,
        name: r'productionViewProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: false,
      );

  /// 制片页当前视图，由左栏入口和制片页共同驱动。
  ///
  /// 左栏写入目标视图，制片页监听后带着焦点切换；切换被拒（编辑未保存等）时
  /// 制片页把状态写回实际视图。保活以便离开制片分区后再回来仍停在上次的视图。

  ProductionViewProvider call(String novelId) =>
      ProductionViewProvider._(argument: novelId, from: this);

  @override
  String toString() => r'productionViewProvider';
}

/// 制片页当前视图，由左栏入口和制片页共同驱动。
///
/// 左栏写入目标视图，制片页监听后带着焦点切换；切换被拒（编辑未保存等）时
/// 制片页把状态写回实际视图。保活以便离开制片分区后再回来仍停在上次的视图。

abstract class _$ProductionView extends $Notifier<ProductionViewMode> {
  late final _$args = ref.$arg as String;
  String get novelId => _$args;

  ProductionViewMode build(String novelId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ProductionViewMode, ProductionViewMode>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ProductionViewMode, ProductionViewMode>,
              ProductionViewMode,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}

/// 制片页里打开的剪辑或导演台；名称用于面包屑，调度 ID 用于 AI 上下文。
///
/// 按作品内容库路径区分：剪辑和导演台只持有路径。工作区外壳在制片分区时 watch 保活。

@ProviderFor(ProductionSubpage)
final productionSubpageProvider = ProductionSubpageFamily._();

/// 制片页里打开的剪辑或导演台；名称用于面包屑，调度 ID 用于 AI 上下文。
///
/// 按作品内容库路径区分：剪辑和导演台只持有路径。工作区外壳在制片分区时 watch 保活。
final class ProductionSubpageProvider
    extends $NotifierProvider<ProductionSubpage, ProductionSubpageContext?> {
  /// 制片页里打开的剪辑或导演台；名称用于面包屑，调度 ID 用于 AI 上下文。
  ///
  /// 按作品内容库路径区分：剪辑和导演台只持有路径。工作区外壳在制片分区时 watch 保活。
  ProductionSubpageProvider._({
    required ProductionSubpageFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'productionSubpageProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$productionSubpageHash();

  @override
  String toString() {
    return r'productionSubpageProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  ProductionSubpage create() => ProductionSubpage();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ProductionSubpageContext? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ProductionSubpageContext?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ProductionSubpageProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$productionSubpageHash() => r'86f594fd7f444a97df9a4ab31361618cc363f981';

/// 制片页里打开的剪辑或导演台；名称用于面包屑，调度 ID 用于 AI 上下文。
///
/// 按作品内容库路径区分：剪辑和导演台只持有路径。工作区外壳在制片分区时 watch 保活。

final class ProductionSubpageFamily extends $Family
    with
        $ClassFamilyOverride<
          ProductionSubpage,
          ProductionSubpageContext?,
          ProductionSubpageContext?,
          ProductionSubpageContext?,
          String
        > {
  ProductionSubpageFamily._()
    : super(
        retry: null,
        name: r'productionSubpageProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// 制片页里打开的剪辑或导演台；名称用于面包屑，调度 ID 用于 AI 上下文。
  ///
  /// 按作品内容库路径区分：剪辑和导演台只持有路径。工作区外壳在制片分区时 watch 保活。

  ProductionSubpageProvider call(String databasePath) =>
      ProductionSubpageProvider._(argument: databasePath, from: this);

  @override
  String toString() => r'productionSubpageProvider';
}

/// 制片页里打开的剪辑或导演台；名称用于面包屑，调度 ID 用于 AI 上下文。
///
/// 按作品内容库路径区分：剪辑和导演台只持有路径。工作区外壳在制片分区时 watch 保活。

abstract class _$ProductionSubpage
    extends $Notifier<ProductionSubpageContext?> {
  late final _$args = ref.$arg as String;
  String get databasePath => _$args;

  ProductionSubpageContext? build(String databasePath);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref as $Ref<ProductionSubpageContext?, ProductionSubpageContext?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ProductionSubpageContext?, ProductionSubpageContext?>,
              ProductionSubpageContext?,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}
