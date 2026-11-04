// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Global broker that the tool execution layer uses to request user approval
/// for Write / Edit calls. The UI listens on this to render pending tool
/// cards.

@ProviderFor(aiToolApprovalController)
final aiToolApprovalControllerProvider = AiToolApprovalControllerProvider._();

/// Global broker that the tool execution layer uses to request user approval
/// for Write / Edit calls. The UI listens on this to render pending tool
/// cards.

final class AiToolApprovalControllerProvider
    extends
        $FunctionalProvider<
          AiToolApprovalController,
          AiToolApprovalController,
          AiToolApprovalController
        >
    with $Provider<AiToolApprovalController> {
  /// Global broker that the tool execution layer uses to request user approval
  /// for Write / Edit calls. The UI listens on this to render pending tool
  /// cards.
  AiToolApprovalControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'aiToolApprovalControllerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$aiToolApprovalControllerHash();

  @$internal
  @override
  $ProviderElement<AiToolApprovalController> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiToolApprovalController create(Ref ref) {
    return aiToolApprovalController(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiToolApprovalController value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiToolApprovalController>(value),
    );
  }
}

String _$aiToolApprovalControllerHash() =>
    r'73d4649d8b9f8cb230422fda47fa0743846f3d2a';

@ProviderFor(AiChatRuntime)
final aiChatRuntimeProvider = AiChatRuntimeFamily._();

final class AiChatRuntimeProvider
    extends $NotifierProvider<AiChatRuntime, AiChatRuntimeState> {
  AiChatRuntimeProvider._({
    required AiChatRuntimeFamily super.from,
    required String? super.argument,
  }) : super(
         retry: null,
         name: r'aiChatRuntimeProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiChatRuntimeHash();

  @override
  String toString() {
    return r'aiChatRuntimeProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  AiChatRuntime create() => AiChatRuntime();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiChatRuntimeState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiChatRuntimeState>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiChatRuntimeProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiChatRuntimeHash() => r'5d378f71b9630f32725358a8a6da8f12ac79d40b';

final class AiChatRuntimeFamily extends $Family
    with
        $ClassFamilyOverride<
          AiChatRuntime,
          AiChatRuntimeState,
          AiChatRuntimeState,
          AiChatRuntimeState,
          String?
        > {
  AiChatRuntimeFamily._()
    : super(
        retry: null,
        name: r'aiChatRuntimeProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  AiChatRuntimeProvider call(String? sessionId) =>
      AiChatRuntimeProvider._(argument: sessionId, from: this);

  @override
  String toString() => r'aiChatRuntimeProvider';
}

abstract class _$AiChatRuntime extends $Notifier<AiChatRuntimeState> {
  late final _$args = ref.$arg as String?;
  String? get sessionId => _$args;

  AiChatRuntimeState build(String? sessionId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AiChatRuntimeState, AiChatRuntimeState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AiChatRuntimeState, AiChatRuntimeState>,
              AiChatRuntimeState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}

/// AI 聊天会话 Notifier

@ProviderFor(AiChatSession)
final aiChatSessionProvider = AiChatSessionFamily._();

/// AI 聊天会话 Notifier
final class AiChatSessionProvider
    extends $NotifierProvider<AiChatSession, AiChatSessionState> {
  /// AI 聊天会话 Notifier
  AiChatSessionProvider._({
    required AiChatSessionFamily super.from,
    required String? super.argument,
  }) : super(
         retry: null,
         name: r'aiChatSessionProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiChatSessionHash();

  @override
  String toString() {
    return r'aiChatSessionProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  AiChatSession create() => AiChatSession();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiChatSessionState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiChatSessionState>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiChatSessionProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiChatSessionHash() => r'1e770d3a9a3ef9363d7738f997404bae01c38aa0';

/// AI 聊天会话 Notifier

final class AiChatSessionFamily extends $Family
    with
        $ClassFamilyOverride<
          AiChatSession,
          AiChatSessionState,
          AiChatSessionState,
          AiChatSessionState,
          String?
        > {
  AiChatSessionFamily._()
    : super(
        retry: null,
        name: r'aiChatSessionProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// AI 聊天会话 Notifier

  AiChatSessionProvider call(String? sessionId) =>
      AiChatSessionProvider._(argument: sessionId, from: this);

  @override
  String toString() => r'aiChatSessionProvider';
}

/// AI 聊天会话 Notifier

abstract class _$AiChatSession extends $Notifier<AiChatSessionState> {
  late final _$args = ref.$arg as String?;
  String? get sessionId => _$args;

  AiChatSessionState build(String? sessionId);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AiChatSessionState, AiChatSessionState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AiChatSessionState, AiChatSessionState>,
              AiChatSessionState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}

/// AI 会话上下文 Notifier

@ProviderFor(AiSessionContextNotifier)
final aiSessionContextProvider = AiSessionContextNotifierProvider._();

/// AI 会话上下文 Notifier
final class AiSessionContextNotifierProvider
    extends $NotifierProvider<AiSessionContextNotifier, AiSessionContext> {
  /// AI 会话上下文 Notifier
  AiSessionContextNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'aiSessionContextProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$aiSessionContextNotifierHash();

  @$internal
  @override
  AiSessionContextNotifier create() => AiSessionContextNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiSessionContext value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiSessionContext>(value),
    );
  }
}

String _$aiSessionContextNotifierHash() =>
    r'e61d2923fbf9fd5491da84261f30e02ff231b632';

/// AI 会话上下文 Notifier

abstract class _$AiSessionContextNotifier extends $Notifier<AiSessionContext> {
  AiSessionContext build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AiSessionContext, AiSessionContext>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AiSessionContext, AiSessionContext>,
              AiSessionContext,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// 章节写作状态 Notifier

@ProviderFor(ChapterWriting)
final chapterWritingProvider = ChapterWritingProvider._();

/// 章节写作状态 Notifier
final class ChapterWritingProvider
    extends $NotifierProvider<ChapterWriting, ChapterWritingState?> {
  /// 章节写作状态 Notifier
  ChapterWritingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'chapterWritingProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$chapterWritingHash();

  @$internal
  @override
  ChapterWriting create() => ChapterWriting();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ChapterWritingState? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ChapterWritingState?>(value),
    );
  }
}

String _$chapterWritingHash() => r'1f1fc87d29bf3b1ae5a87bfe2e6b13ad05dfaf2c';

/// 章节写作状态 Notifier

abstract class _$ChapterWriting extends $Notifier<ChapterWritingState?> {
  ChapterWritingState? build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ChapterWritingState?, ChapterWritingState?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ChapterWritingState?, ChapterWritingState?>,
              ChapterWritingState?,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// 共享 http.Client 的引用计数注册表。
///
/// 必须 keepAlive:借用方(聊天、dreaming、剧场等)的生命周期远长于任何单个页面
/// 或 provider,client 何时关闭只能由 [AiHttpClientLease.release] 决定,不能交给
/// autoDispose。

@ProviderFor(aiHttpClientRegistry)
final aiHttpClientRegistryProvider = AiHttpClientRegistryProvider._();

/// 共享 http.Client 的引用计数注册表。
///
/// 必须 keepAlive:借用方(聊天、dreaming、剧场等)的生命周期远长于任何单个页面
/// 或 provider,client 何时关闭只能由 [AiHttpClientLease.release] 决定,不能交给
/// autoDispose。

final class AiHttpClientRegistryProvider
    extends
        $FunctionalProvider<
          AiHttpClientRegistry,
          AiHttpClientRegistry,
          AiHttpClientRegistry
        >
    with $Provider<AiHttpClientRegistry> {
  /// 共享 http.Client 的引用计数注册表。
  ///
  /// 必须 keepAlive:借用方(聊天、dreaming、剧场等)的生命周期远长于任何单个页面
  /// 或 provider,client 何时关闭只能由 [AiHttpClientLease.release] 决定,不能交给
  /// autoDispose。
  AiHttpClientRegistryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'aiHttpClientRegistryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$aiHttpClientRegistryHash();

  @$internal
  @override
  $ProviderElement<AiHttpClientRegistry> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiHttpClientRegistry create(Ref ref) {
    return aiHttpClientRegistry(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiHttpClientRegistry value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiHttpClientRegistry>(value),
    );
  }
}

String _$aiHttpClientRegistryHash() =>
    r'6048a62d1605b782d3ab19fdb4c351a0e1ffc726';

/// AI 服务 Provider

@ProviderFor(aiService)
final aiServiceProvider = AiServiceFamily._();

/// AI 服务 Provider

final class AiServiceProvider
    extends $FunctionalProvider<AiClient?, AiClient?, AiClient?>
    with $Provider<AiClient?> {
  /// AI 服务 Provider
  AiServiceProvider._({
    required AiServiceFamily super.from,
    required String? super.argument,
  }) : super(
         retry: null,
         name: r'aiServiceProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiServiceHash();

  @override
  String toString() {
    return r'aiServiceProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<AiClient?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AiClient? create(Ref ref) {
    final argument = this.argument as String?;
    return aiService(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiClient? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiClient?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiServiceProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiServiceHash() => r'3879bf10897f04ccaea1b48b73d4a36f785c3d46';

/// AI 服务 Provider

final class AiServiceFamily extends $Family
    with $FunctionalFamilyOverride<AiClient?, String?> {
  AiServiceFamily._()
    : super(
        retry: null,
        name: r'aiServiceProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// AI 服务 Provider

  AiServiceProvider call(String? sessionId) =>
      AiServiceProvider._(argument: sessionId, from: this);

  @override
  String toString() => r'aiServiceProvider';
}

/// AI 服务异步 Provider（用于执行 AI 操作）

@ProviderFor(aiServiceAsync)
final aiServiceAsyncProvider = AiServiceAsyncFamily._();

/// AI 服务异步 Provider（用于执行 AI 操作）

final class AiServiceAsyncProvider
    extends
        $FunctionalProvider<
          AsyncValue<AiClient?>,
          AiClient?,
          FutureOr<AiClient?>
        >
    with $FutureModifier<AiClient?>, $FutureProvider<AiClient?> {
  /// AI 服务异步 Provider（用于执行 AI 操作）
  AiServiceAsyncProvider._({
    required AiServiceAsyncFamily super.from,
    required String? super.argument,
  }) : super(
         retry: null,
         name: r'aiServiceAsyncProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiServiceAsyncHash();

  @override
  String toString() {
    return r'aiServiceAsyncProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<AiClient?> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<AiClient?> create(Ref ref) {
    final argument = this.argument as String?;
    return aiServiceAsync(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is AiServiceAsyncProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiServiceAsyncHash() => r'f324522d97fb1ae67cd350624a336f26dd1c11af';

/// AI 服务异步 Provider（用于执行 AI 操作）

final class AiServiceAsyncFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<AiClient?>, String?> {
  AiServiceAsyncFamily._()
    : super(
        retry: null,
        name: r'aiServiceAsyncProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// AI 服务异步 Provider（用于执行 AI 操作）

  AiServiceAsyncProvider call(String? sessionId) =>
      AiServiceAsyncProvider._(argument: sessionId, from: this);

  @override
  String toString() => r'aiServiceAsyncProvider';
}

@ProviderFor(coverStudioImageModelSelection)
final coverStudioImageModelSelectionProvider =
    CoverStudioImageModelSelectionProvider._();

final class CoverStudioImageModelSelectionProvider
    extends
        $FunctionalProvider<
          CoverStudioImageModelSelection?,
          CoverStudioImageModelSelection?,
          CoverStudioImageModelSelection?
        >
    with $Provider<CoverStudioImageModelSelection?> {
  CoverStudioImageModelSelectionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'coverStudioImageModelSelectionProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$coverStudioImageModelSelectionHash();

  @$internal
  @override
  $ProviderElement<CoverStudioImageModelSelection?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  CoverStudioImageModelSelection? create(Ref ref) {
    return coverStudioImageModelSelection(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CoverStudioImageModelSelection? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CoverStudioImageModelSelection?>(
        value,
      ),
    );
  }
}

String _$coverStudioImageModelSelectionHash() =>
    r'67f7d381109477bcd2dc2513c1ce85b86b07a38a';

@ProviderFor(imageGenerationConfig)
final imageGenerationConfigProvider = ImageGenerationConfigProvider._();

final class ImageGenerationConfigProvider
    extends $FunctionalProvider<AiProvider?, AiProvider?, AiProvider?>
    with $Provider<AiProvider?> {
  ImageGenerationConfigProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'imageGenerationConfigProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$imageGenerationConfigHash();

  @$internal
  @override
  $ProviderElement<AiProvider?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AiProvider? create(Ref ref) {
    return imageGenerationConfig(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiProvider? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiProvider?>(value),
    );
  }
}

String _$imageGenerationConfigHash() =>
    r'e9ae274707ddc63c70f8fc18976149182f4c12b7';

@ProviderFor(imageGenerationCallback)
final imageGenerationCallbackProvider = ImageGenerationCallbackFamily._();

final class ImageGenerationCallbackProvider
    extends
        $FunctionalProvider<
          AiImageGenerationCallback?,
          AiImageGenerationCallback?,
          AiImageGenerationCallback?
        >
    with $Provider<AiImageGenerationCallback?> {
  ImageGenerationCallbackProvider._({
    required ImageGenerationCallbackFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'imageGenerationCallbackProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$imageGenerationCallbackHash();

  @override
  String toString() {
    return r'imageGenerationCallbackProvider'
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
    final argument = this.argument as String;
    return imageGenerationCallback(ref, argument);
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
    return other is ImageGenerationCallbackProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$imageGenerationCallbackHash() =>
    r'a977a07dc097f96bc2555a1107e067735a249f2f';

final class ImageGenerationCallbackFamily extends $Family
    with $FunctionalFamilyOverride<AiImageGenerationCallback?, String> {
  ImageGenerationCallbackFamily._()
    : super(
        retry: null,
        name: r'imageGenerationCallbackProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ImageGenerationCallbackProvider call(String workId) =>
      ImageGenerationCallbackProvider._(argument: workId, from: this);

  @override
  String toString() => r'imageGenerationCallbackProvider';
}

@ProviderFor(coverImageGenerationCallback)
final coverImageGenerationCallbackProvider =
    CoverImageGenerationCallbackProvider._();

final class CoverImageGenerationCallbackProvider
    extends
        $FunctionalProvider<
          AiImageGenerationCallback?,
          AiImageGenerationCallback?,
          AiImageGenerationCallback?
        >
    with $Provider<AiImageGenerationCallback?> {
  CoverImageGenerationCallbackProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'coverImageGenerationCallbackProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$coverImageGenerationCallbackHash();

  @$internal
  @override
  $ProviderElement<AiImageGenerationCallback?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiImageGenerationCallback? create(Ref ref) {
    return coverImageGenerationCallback(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiImageGenerationCallback? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiImageGenerationCallback?>(value),
    );
  }
}

String _$coverImageGenerationCallbackHash() =>
    r'627f4a73c067007835376c774f5071aabb2f7e5a';

@ProviderFor(coverImageMultiEditCallback)
final coverImageMultiEditCallbackProvider =
    CoverImageMultiEditCallbackProvider._();

final class CoverImageMultiEditCallbackProvider
    extends
        $FunctionalProvider<
          AiMultiImageEditCallback?,
          AiMultiImageEditCallback?,
          AiMultiImageEditCallback?
        >
    with $Provider<AiMultiImageEditCallback?> {
  CoverImageMultiEditCallbackProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'coverImageMultiEditCallbackProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$coverImageMultiEditCallbackHash();

  @$internal
  @override
  $ProviderElement<AiMultiImageEditCallback?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiMultiImageEditCallback? create(Ref ref) {
    return coverImageMultiEditCallback(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiMultiImageEditCallback? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiMultiImageEditCallback?>(value),
    );
  }
}

String _$coverImageMultiEditCallbackHash() =>
    r'd7fa0460de559ff6bfb7c2e306820b57358cf391';

@ProviderFor(imageEditCallback)
final imageEditCallbackProvider = ImageEditCallbackFamily._();

final class ImageEditCallbackProvider
    extends
        $FunctionalProvider<
          AiImageEditCallback?,
          AiImageEditCallback?,
          AiImageEditCallback?
        >
    with $Provider<AiImageEditCallback?> {
  ImageEditCallbackProvider._({
    required ImageEditCallbackFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'imageEditCallbackProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$imageEditCallbackHash();

  @override
  String toString() {
    return r'imageEditCallbackProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<AiImageEditCallback?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiImageEditCallback? create(Ref ref) {
    final argument = this.argument as String;
    return imageEditCallback(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiImageEditCallback? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiImageEditCallback?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ImageEditCallbackProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$imageEditCallbackHash() => r'9c21ee708dfe8a402c0eab7a1e497fa598885f58';

final class ImageEditCallbackFamily extends $Family
    with $FunctionalFamilyOverride<AiImageEditCallback?, String> {
  ImageEditCallbackFamily._()
    : super(
        retry: null,
        name: r'imageEditCallbackProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ImageEditCallbackProvider call(String workId) =>
      ImageEditCallbackProvider._(argument: workId, from: this);

  @override
  String toString() => r'imageEditCallbackProvider';
}

@ProviderFor(imageMultiEditCallback)
final imageMultiEditCallbackProvider = ImageMultiEditCallbackProvider._();

final class ImageMultiEditCallbackProvider
    extends
        $FunctionalProvider<
          AiMultiImageEditCallback?,
          AiMultiImageEditCallback?,
          AiMultiImageEditCallback?
        >
    with $Provider<AiMultiImageEditCallback?> {
  ImageMultiEditCallbackProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'imageMultiEditCallbackProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$imageMultiEditCallbackHash();

  @$internal
  @override
  $ProviderElement<AiMultiImageEditCallback?> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AiMultiImageEditCallback? create(Ref ref) {
    return imageMultiEditCallback(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiMultiImageEditCallback? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiMultiImageEditCallback?>(value),
    );
  }
}

String _$imageMultiEditCallbackHash() =>
    r'455be7eff0db3071d1466a5f02ab0d480082afcf';

@ProviderFor(isImageGenerationConfigured)
final isImageGenerationConfiguredProvider =
    IsImageGenerationConfiguredProvider._();

final class IsImageGenerationConfiguredProvider
    extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  IsImageGenerationConfiguredProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'isImageGenerationConfiguredProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$isImageGenerationConfiguredHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return isImageGenerationConfigured(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$isImageGenerationConfiguredHash() =>
    r'9e9d5dc5e901bebe70b38b8188243de00b480695';
