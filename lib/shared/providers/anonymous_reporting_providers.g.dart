// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'anonymous_reporting_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(anonymousReportingConsentService)
final anonymousReportingConsentServiceProvider =
    AnonymousReportingConsentServiceProvider._();

final class AnonymousReportingConsentServiceProvider
    extends
        $FunctionalProvider<
          AnonymousReportingConsentService,
          AnonymousReportingConsentService,
          AnonymousReportingConsentService
        >
    with $Provider<AnonymousReportingConsentService> {
  AnonymousReportingConsentServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'anonymousReportingConsentServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$anonymousReportingConsentServiceHash();

  @$internal
  @override
  $ProviderElement<AnonymousReportingConsentService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AnonymousReportingConsentService create(Ref ref) {
    return anonymousReportingConsentService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AnonymousReportingConsentService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AnonymousReportingConsentService>(
        value,
      ),
    );
  }
}

String _$anonymousReportingConsentServiceHash() =>
    r'f5d61a4a2c0b76dc7e83e81335f504ed33337315';

/// 匿名诊断上报设置。首次使用默认开启。

@ProviderFor(AnonymousReportingConsent)
final anonymousReportingConsentProvider = AnonymousReportingConsentProvider._();

/// 匿名诊断上报设置。首次使用默认开启。
final class AnonymousReportingConsentProvider
    extends $AsyncNotifierProvider<AnonymousReportingConsent, bool> {
  /// 匿名诊断上报设置。首次使用默认开启。
  AnonymousReportingConsentProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'anonymousReportingConsentProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$anonymousReportingConsentHash();

  @$internal
  @override
  AnonymousReportingConsent create() => AnonymousReportingConsent();
}

String _$anonymousReportingConsentHash() =>
    r'3ad629cbe0a1fdbb713da3e1439cc5b00b98ad9c';

/// 匿名诊断上报设置。首次使用默认开启。

abstract class _$AnonymousReportingConsent extends $AsyncNotifier<bool> {
  FutureOr<bool> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<bool>, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<bool>, bool>,
              AsyncValue<bool>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(anonymousOutboxService)
final anonymousOutboxServiceProvider = AnonymousOutboxServiceProvider._();

final class AnonymousOutboxServiceProvider
    extends
        $FunctionalProvider<
          AnonymousOutboxService,
          AnonymousOutboxService,
          AnonymousOutboxService
        >
    with $Provider<AnonymousOutboxService> {
  AnonymousOutboxServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'anonymousOutboxServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$anonymousOutboxServiceHash();

  @$internal
  @override
  $ProviderElement<AnonymousOutboxService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AnonymousOutboxService create(Ref ref) {
    return anonymousOutboxService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AnonymousOutboxService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AnonymousOutboxService>(value),
    );
  }
}

String _$anonymousOutboxServiceHash() =>
    r'48a053770a53884543da6c34afa3858adf38b143';
