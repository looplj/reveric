// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'update_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// UpdateSource 单例

@ProviderFor(updateSource)
final updateSourceProvider = UpdateSourceProvider._();

/// UpdateSource 单例

final class UpdateSourceProvider
    extends $FunctionalProvider<UpdateSource, UpdateSource, UpdateSource>
    with $Provider<UpdateSource> {
  /// UpdateSource 单例
  UpdateSourceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'updateSourceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$updateSourceHash();

  @$internal
  @override
  $ProviderElement<UpdateSource> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  UpdateSource create(Ref ref) {
    return updateSource(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(UpdateSource value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<UpdateSource>(value),
    );
  }
}

String _$updateSourceHash() => r'32e4c959ae11493906989b2a6d31f69d0dec9880';

/// UpdateService 单例

@ProviderFor(updateService)
final updateServiceProvider = UpdateServiceProvider._();

/// UpdateService 单例

final class UpdateServiceProvider
    extends $FunctionalProvider<UpdateService, UpdateService, UpdateService>
    with $Provider<UpdateService> {
  /// UpdateService 单例
  UpdateServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'updateServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$updateServiceHash();

  @$internal
  @override
  $ProviderElement<UpdateService> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  UpdateService create(Ref ref) {
    return updateService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(UpdateService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<UpdateService>(value),
    );
  }
}

String _$updateServiceHash() => r'd8041abd3328efd5f88d8843728787d0ba5389f7';

/// 初始化 UpdateService（注入版本号）

@ProviderFor(updateServiceInit)
final updateServiceInitProvider = UpdateServiceInitProvider._();

/// 初始化 UpdateService（注入版本号）

final class UpdateServiceInitProvider
    extends $FunctionalProvider<AsyncValue<void>, void, FutureOr<void>>
    with $FutureModifier<void>, $FutureProvider<void> {
  /// 初始化 UpdateService（注入版本号）
  UpdateServiceInitProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'updateServiceInitProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$updateServiceInitHash();

  @$internal
  @override
  $FutureProviderElement<void> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<void> create(Ref ref) {
    return updateServiceInit(ref);
  }
}

String _$updateServiceInitHash() => r'ac43e742f93fccc34ab0e28b251c3e47ae39d639';

/// 跨页面保留一份轻量检查结果，供关于页、更新入口与提醒共同消费。

@ProviderFor(LatestRelease)
final latestReleaseProvider = LatestReleaseProvider._();

/// 跨页面保留一份轻量检查结果，供关于页、更新入口与提醒共同消费。
final class LatestReleaseProvider
    extends $AsyncNotifierProvider<LatestRelease, UpdateCheckResult?> {
  /// 跨页面保留一份轻量检查结果，供关于页、更新入口与提醒共同消费。
  LatestReleaseProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'latestReleaseProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$latestReleaseHash();

  @$internal
  @override
  LatestRelease create() => LatestRelease();
}

String _$latestReleaseHash() => r'd17296d77f4332ac414231a1bf30cd975082b884';

/// 跨页面保留一份轻量检查结果，供关于页、更新入口与提醒共同消费。

abstract class _$LatestRelease extends $AsyncNotifier<UpdateCheckResult?> {
  FutureOr<UpdateCheckResult?> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref as $Ref<AsyncValue<UpdateCheckResult?>, UpdateCheckResult?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<UpdateCheckResult?>, UpdateCheckResult?>,
              AsyncValue<UpdateCheckResult?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// 小型入口只订阅版本变化，检查失败与刷新不会影响布局。

@ProviderFor(availableUpdate)
final availableUpdateProvider = AvailableUpdateProvider._();

/// 小型入口只订阅版本变化，检查失败与刷新不会影响布局。

final class AvailableUpdateProvider
    extends $FunctionalProvider<UpdateInfo?, UpdateInfo?, UpdateInfo?>
    with $Provider<UpdateInfo?> {
  /// 小型入口只订阅版本变化，检查失败与刷新不会影响布局。
  AvailableUpdateProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'availableUpdateProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$availableUpdateHash();

  @$internal
  @override
  $ProviderElement<UpdateInfo?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  UpdateInfo? create(Ref ref) {
    return availableUpdate(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(UpdateInfo? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<UpdateInfo?>(value),
    );
  }
}

String _$availableUpdateHash() => r'6f3a0c6b269fafb1dce59c5a15f7516e5d4033f2';

/// 调试页向全局轻提示发送验证请求，不修改真实版本或提醒历史。

@ProviderFor(UpdateReminderPreview)
final updateReminderPreviewProvider = UpdateReminderPreviewProvider._();

/// 调试页向全局轻提示发送验证请求，不修改真实版本或提醒历史。
final class UpdateReminderPreviewProvider
    extends $NotifierProvider<UpdateReminderPreview, int> {
  /// 调试页向全局轻提示发送验证请求，不修改真实版本或提醒历史。
  UpdateReminderPreviewProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'updateReminderPreviewProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$updateReminderPreviewHash();

  @$internal
  @override
  UpdateReminderPreview create() => UpdateReminderPreview();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(int value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<int>(value),
    );
  }
}

String _$updateReminderPreviewHash() =>
    r'3f4f5445266bc28caad33dbeb5e9ceda718566d5';

/// 调试页向全局轻提示发送验证请求，不修改真实版本或提醒历史。

abstract class _$UpdateReminderPreview extends $Notifier<int> {
  int build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<int, int>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<int, int>,
              int,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// 更新下载状态

@ProviderFor(UpdateDownloadNotifier)
final updateDownloadProvider = UpdateDownloadNotifierProvider._();

/// 更新下载状态
final class UpdateDownloadNotifierProvider
    extends $NotifierProvider<UpdateDownloadNotifier, UpdateProgress> {
  /// 更新下载状态
  UpdateDownloadNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'updateDownloadProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$updateDownloadNotifierHash();

  @$internal
  @override
  UpdateDownloadNotifier create() => UpdateDownloadNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(UpdateProgress value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<UpdateProgress>(value),
    );
  }
}

String _$updateDownloadNotifierHash() =>
    r'365480f9d59c31ec85f9ce1a68609ca6c874d9af';

/// 更新下载状态

abstract class _$UpdateDownloadNotifier extends $Notifier<UpdateProgress> {
  UpdateProgress build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<UpdateProgress, UpdateProgress>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<UpdateProgress, UpdateProgress>,
              UpdateProgress,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
