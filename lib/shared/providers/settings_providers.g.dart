// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'settings_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(appSettingsForm)
final appSettingsFormProvider = AppSettingsFormProvider._();

final class AppSettingsFormProvider
    extends
        $FunctionalProvider<
          FormFieldsController<AppSettingsFormField<dynamic>>?,
          FormFieldsController<AppSettingsFormField<dynamic>>?,
          FormFieldsController<AppSettingsFormField<dynamic>>?
        >
    with $Provider<FormFieldsController<AppSettingsFormField<dynamic>>?> {
  AppSettingsFormProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appSettingsFormProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appSettingsFormHash();

  @$internal
  @override
  $ProviderElement<FormFieldsController<AppSettingsFormField<dynamic>>?>
  $createElement($ProviderPointer pointer) => $ProviderElement(pointer);

  @override
  FormFieldsController<AppSettingsFormField<dynamic>>? create(Ref ref) {
    return appSettingsForm(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(
    FormFieldsController<AppSettingsFormField<dynamic>>? value,
  ) {
    return $ProviderOverride(
      origin: this,
      providerOverride:
          $SyncValueProvider<
            FormFieldsController<AppSettingsFormField<dynamic>>?
          >(value),
    );
  }
}

String _$appSettingsFormHash() => r'28f3a0e30726a674bb689bb7f4f2ae49af07c64d';

@ProviderFor(aiProviderForm)
final aiProviderFormProvider = AiProviderFormFamily._();

final class AiProviderFormProvider
    extends
        $FunctionalProvider<
          FormFieldsController<AiProviderFormField<dynamic>>?,
          FormFieldsController<AiProviderFormField<dynamic>>?,
          FormFieldsController<AiProviderFormField<dynamic>>?
        >
    with $Provider<FormFieldsController<AiProviderFormField<dynamic>>?> {
  AiProviderFormProvider._({
    required AiProviderFormFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'aiProviderFormProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$aiProviderFormHash();

  @override
  String toString() {
    return r'aiProviderFormProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<FormFieldsController<AiProviderFormField<dynamic>>?>
  $createElement($ProviderPointer pointer) => $ProviderElement(pointer);

  @override
  FormFieldsController<AiProviderFormField<dynamic>>? create(Ref ref) {
    final argument = this.argument as String;
    return aiProviderForm(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(
    FormFieldsController<AiProviderFormField<dynamic>>? value,
  ) {
    return $ProviderOverride(
      origin: this,
      providerOverride:
          $SyncValueProvider<
            FormFieldsController<AiProviderFormField<dynamic>>?
          >(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiProviderFormProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$aiProviderFormHash() => r'ad4701a9dc0fe3fb3c022fe0c0a0b15cdcb114e1';

final class AiProviderFormFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FormFieldsController<AiProviderFormField<dynamic>>?,
          String
        > {
  AiProviderFormFamily._()
    : super(
        retry: null,
        name: r'aiProviderFormProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  AiProviderFormProvider call(String providerId) =>
      AiProviderFormProvider._(argument: providerId, from: this);

  @override
  String toString() => r'aiProviderFormProvider';
}

@ProviderFor(appSettingsDatabase)
final appSettingsDatabaseProvider = AppSettingsDatabaseProvider._();

final class AppSettingsDatabaseProvider
    extends $FunctionalProvider<AppDatabase, AppDatabase, AppDatabase>
    with $Provider<AppDatabase> {
  AppSettingsDatabaseProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appSettingsDatabaseProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appSettingsDatabaseHash();

  @$internal
  @override
  $ProviderElement<AppDatabase> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AppDatabase create(Ref ref) {
    return appSettingsDatabase(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AppDatabase value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AppDatabase>(value),
    );
  }
}

String _$appSettingsDatabaseHash() =>
    r'a3c64864f9ad06b4fe40d4c8d2daf763703554db';

@ProviderFor(AppSettingsNotifier)
final appSettingsProvider = AppSettingsNotifierProvider._();

final class AppSettingsNotifierProvider
    extends $AsyncNotifierProvider<AppSettingsNotifier, AppSettings> {
  AppSettingsNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appSettingsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appSettingsNotifierHash();

  @$internal
  @override
  AppSettingsNotifier create() => AppSettingsNotifier();
}

String _$appSettingsNotifierHash() =>
    r'88422c1ed6ec9d66b180b7cd165bbc299b8ee278';

abstract class _$AppSettingsNotifier extends $AsyncNotifier<AppSettings> {
  FutureOr<AppSettings> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<AppSettings>, AppSettings>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<AppSettings>, AppSettings>,
              AsyncValue<AppSettings>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(currentTheme)
final currentThemeProvider = CurrentThemeProvider._();

final class CurrentThemeProvider
    extends
        $FunctionalProvider<
          RevericThemeData,
          RevericThemeData,
          RevericThemeData
        >
    with $Provider<RevericThemeData> {
  CurrentThemeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'currentThemeProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$currentThemeHash();

  @$internal
  @override
  $ProviderElement<RevericThemeData> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  RevericThemeData create(Ref ref) {
    return currentTheme(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(RevericThemeData value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<RevericThemeData>(value),
    );
  }
}

String _$currentThemeHash() => r'621eeee33489a7bb2848d8316ce708be5f4a64e5';

@ProviderFor(currentThemeForBrightness)
final currentThemeForBrightnessProvider = CurrentThemeForBrightnessFamily._();

final class CurrentThemeForBrightnessProvider
    extends
        $FunctionalProvider<
          RevericThemeData,
          RevericThemeData,
          RevericThemeData
        >
    with $Provider<RevericThemeData> {
  CurrentThemeForBrightnessProvider._({
    required CurrentThemeForBrightnessFamily super.from,
    required Brightness super.argument,
  }) : super(
         retry: null,
         name: r'currentThemeForBrightnessProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$currentThemeForBrightnessHash();

  @override
  String toString() {
    return r'currentThemeForBrightnessProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<RevericThemeData> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  RevericThemeData create(Ref ref) {
    final argument = this.argument as Brightness;
    return currentThemeForBrightness(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(RevericThemeData value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<RevericThemeData>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CurrentThemeForBrightnessProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$currentThemeForBrightnessHash() =>
    r'534190b322545753e5fb187b1342cad0ab3171f9';

final class CurrentThemeForBrightnessFamily extends $Family
    with $FunctionalFamilyOverride<RevericThemeData, Brightness> {
  CurrentThemeForBrightnessFamily._()
    : super(
        retry: null,
        name: r'currentThemeForBrightnessProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  CurrentThemeForBrightnessProvider call(Brightness brightness) =>
      CurrentThemeForBrightnessProvider._(argument: brightness, from: this);

  @override
  String toString() => r'currentThemeForBrightnessProvider';
}

@ProviderFor(currentThemeType)
final currentThemeTypeProvider = CurrentThemeTypeProvider._();

final class CurrentThemeTypeProvider
    extends $FunctionalProvider<AppTheme, AppTheme, AppTheme>
    with $Provider<AppTheme> {
  CurrentThemeTypeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'currentThemeTypeProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$currentThemeTypeHash();

  @$internal
  @override
  $ProviderElement<AppTheme> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AppTheme create(Ref ref) {
    return currentThemeType(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AppTheme value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AppTheme>(value),
    );
  }
}

String _$currentThemeTypeHash() => r'd25d442c046aa53b53dc97425f102a7cc4734dd8';

@ProviderFor(currentThemeMode)
final currentThemeModeProvider = CurrentThemeModeProvider._();

final class CurrentThemeModeProvider
    extends $FunctionalProvider<AppThemeMode, AppThemeMode, AppThemeMode>
    with $Provider<AppThemeMode> {
  CurrentThemeModeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'currentThemeModeProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$currentThemeModeHash();

  @$internal
  @override
  $ProviderElement<AppThemeMode> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AppThemeMode create(Ref ref) {
    return currentThemeMode(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AppThemeMode value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AppThemeMode>(value),
    );
  }
}

String _$currentThemeModeHash() => r'72022c9bcba670ea3c861c727c93e01604026402';

@ProviderFor(uiTextScale)
final uiTextScaleProvider = UiTextScaleProvider._();

final class UiTextScaleProvider
    extends $FunctionalProvider<double, double, double>
    with $Provider<double> {
  UiTextScaleProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'uiTextScaleProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$uiTextScaleHash();

  @$internal
  @override
  $ProviderElement<double> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  double create(Ref ref) {
    return uiTextScale(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(double value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<double>(value),
    );
  }
}

String _$uiTextScaleHash() => r'35f472e0e3acd5a4d6d65fd7caea019ca9b33e4d';

@ProviderFor(aiSettings)
final aiSettingsProvider = AiSettingsProvider._();

final class AiSettingsProvider
    extends $FunctionalProvider<AiSettings, AiSettings, AiSettings>
    with $Provider<AiSettings> {
  AiSettingsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'aiSettingsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$aiSettingsHash();

  @$internal
  @override
  $ProviderElement<AiSettings> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AiSettings create(Ref ref) {
    return aiSettings(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiSettings value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiSettings>(value),
    );
  }
}

String _$aiSettingsHash() => r'47d7e74f99d0107d10e296e9a54e830b62e43715';

@ProviderFor(availableAiModels)
final availableAiModelsProvider = AvailableAiModelsProvider._();

final class AvailableAiModelsProvider
    extends
        $FunctionalProvider<
          List<AiModelOption>,
          List<AiModelOption>,
          List<AiModelOption>
        >
    with $Provider<List<AiModelOption>> {
  AvailableAiModelsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'availableAiModelsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$availableAiModelsHash();

  @$internal
  @override
  $ProviderElement<List<AiModelOption>> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  List<AiModelOption> create(Ref ref) {
    return availableAiModels(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<AiModelOption> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<AiModelOption>>(value),
    );
  }
}

String _$availableAiModelsHash() => r'4b8ef9e795c483ad3a200f516a4883d12191a02f';

@ProviderFor(availableAiModelOptionsByKind)
final availableAiModelOptionsByKindProvider =
    AvailableAiModelOptionsByKindFamily._();

final class AvailableAiModelOptionsByKindProvider
    extends
        $FunctionalProvider<
          List<AiModelOption>,
          List<AiModelOption>,
          List<AiModelOption>
        >
    with $Provider<List<AiModelOption>> {
  AvailableAiModelOptionsByKindProvider._({
    required AvailableAiModelOptionsByKindFamily super.from,
    required AiModelKind super.argument,
  }) : super(
         retry: null,
         name: r'availableAiModelOptionsByKindProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$availableAiModelOptionsByKindHash();

  @override
  String toString() {
    return r'availableAiModelOptionsByKindProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<List<AiModelOption>> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  List<AiModelOption> create(Ref ref) {
    final argument = this.argument as AiModelKind;
    return availableAiModelOptionsByKind(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<AiModelOption> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<AiModelOption>>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AvailableAiModelOptionsByKindProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$availableAiModelOptionsByKindHash() =>
    r'576e6331027514b2acce922a3496888631ac133c';

final class AvailableAiModelOptionsByKindFamily extends $Family
    with $FunctionalFamilyOverride<List<AiModelOption>, AiModelKind> {
  AvailableAiModelOptionsByKindFamily._()
    : super(
        retry: null,
        name: r'availableAiModelOptionsByKindProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  AvailableAiModelOptionsByKindProvider call(AiModelKind kind) =>
      AvailableAiModelOptionsByKindProvider._(argument: kind, from: this);

  @override
  String toString() => r'availableAiModelOptionsByKindProvider';
}

@ProviderFor(defaultAiModelOptionId)
final defaultAiModelOptionIdProvider = DefaultAiModelOptionIdFamily._();

final class DefaultAiModelOptionIdProvider
    extends $FunctionalProvider<String?, String?, String?>
    with $Provider<String?> {
  DefaultAiModelOptionIdProvider._({
    required DefaultAiModelOptionIdFamily super.from,
    required AiModelKind super.argument,
  }) : super(
         retry: null,
         name: r'defaultAiModelOptionIdProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$defaultAiModelOptionIdHash();

  @override
  String toString() {
    return r'defaultAiModelOptionIdProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<String?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  String? create(Ref ref) {
    final argument = this.argument as AiModelKind;
    return defaultAiModelOptionId(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DefaultAiModelOptionIdProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$defaultAiModelOptionIdHash() =>
    r'f1a944a79f287751c90282ffa8b9cf656ceb2a2f';

final class DefaultAiModelOptionIdFamily extends $Family
    with $FunctionalFamilyOverride<String?, AiModelKind> {
  DefaultAiModelOptionIdFamily._()
    : super(
        retry: null,
        name: r'defaultAiModelOptionIdProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  DefaultAiModelOptionIdProvider call(AiModelKind kind) =>
      DefaultAiModelOptionIdProvider._(argument: kind, from: this);

  @override
  String toString() => r'defaultAiModelOptionIdProvider';
}

@ProviderFor(defaultAiModelOptionIdForRole)
final defaultAiModelOptionIdForRoleProvider =
    DefaultAiModelOptionIdForRoleFamily._();

final class DefaultAiModelOptionIdForRoleProvider
    extends $FunctionalProvider<String?, String?, String?>
    with $Provider<String?> {
  DefaultAiModelOptionIdForRoleProvider._({
    required DefaultAiModelOptionIdForRoleFamily super.from,
    required AiModelRole super.argument,
  }) : super(
         retry: null,
         name: r'defaultAiModelOptionIdForRoleProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$defaultAiModelOptionIdForRoleHash();

  @override
  String toString() {
    return r'defaultAiModelOptionIdForRoleProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $ProviderElement<String?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  String? create(Ref ref) {
    final argument = this.argument as AiModelRole;
    return defaultAiModelOptionIdForRole(ref, argument);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DefaultAiModelOptionIdForRoleProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$defaultAiModelOptionIdForRoleHash() =>
    r'9f1257988c12b6a51c2a50d4578b7ec70556de55';

final class DefaultAiModelOptionIdForRoleFamily extends $Family
    with $FunctionalFamilyOverride<String?, AiModelRole> {
  DefaultAiModelOptionIdForRoleFamily._()
    : super(
        retry: null,
        name: r'defaultAiModelOptionIdForRoleProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  DefaultAiModelOptionIdForRoleProvider call(AiModelRole role) =>
      DefaultAiModelOptionIdForRoleProvider._(argument: role, from: this);

  @override
  String toString() => r'defaultAiModelOptionIdForRoleProvider';
}

@ProviderFor(resolvedAiModelOptionIdForRole)
final resolvedAiModelOptionIdForRoleProvider =
    ResolvedAiModelOptionIdForRoleFamily._();

final class ResolvedAiModelOptionIdForRoleProvider
    extends $FunctionalProvider<String?, String?, String?>
    with $Provider<String?> {
  ResolvedAiModelOptionIdForRoleProvider._({
    required ResolvedAiModelOptionIdForRoleFamily super.from,
    required ({AiModelRole role, String? databasePath}) super.argument,
  }) : super(
         retry: null,
         name: r'resolvedAiModelOptionIdForRoleProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$resolvedAiModelOptionIdForRoleHash();

  @override
  String toString() {
    return r'resolvedAiModelOptionIdForRoleProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $ProviderElement<String?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  String? create(Ref ref) {
    final argument =
        this.argument as ({AiModelRole role, String? databasePath});
    return resolvedAiModelOptionIdForRole(
      ref,
      role: argument.role,
      databasePath: argument.databasePath,
    );
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ResolvedAiModelOptionIdForRoleProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$resolvedAiModelOptionIdForRoleHash() =>
    r'dd44a7f443f7bd3d02aa2d8af0fcb8a06ca10ab2';

final class ResolvedAiModelOptionIdForRoleFamily extends $Family
    with
        $FunctionalFamilyOverride<
          String?,
          ({AiModelRole role, String? databasePath})
        > {
  ResolvedAiModelOptionIdForRoleFamily._()
    : super(
        retry: null,
        name: r'resolvedAiModelOptionIdForRoleProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ResolvedAiModelOptionIdForRoleProvider call({
    required AiModelRole role,
    String? databasePath,
  }) => ResolvedAiModelOptionIdForRoleProvider._(
    argument: (role: role, databasePath: databasePath),
    from: this,
  );

  @override
  String toString() => r'resolvedAiModelOptionIdForRoleProvider';
}

@ProviderFor(resolvedAiModelOptionIdForKind)
final resolvedAiModelOptionIdForKindProvider =
    ResolvedAiModelOptionIdForKindFamily._();

final class ResolvedAiModelOptionIdForKindProvider
    extends $FunctionalProvider<String?, String?, String?>
    with $Provider<String?> {
  ResolvedAiModelOptionIdForKindProvider._({
    required ResolvedAiModelOptionIdForKindFamily super.from,
    required ({AiModelKind kind, String? databasePath}) super.argument,
  }) : super(
         retry: null,
         name: r'resolvedAiModelOptionIdForKindProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$resolvedAiModelOptionIdForKindHash();

  @override
  String toString() {
    return r'resolvedAiModelOptionIdForKindProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $ProviderElement<String?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  String? create(Ref ref) {
    final argument =
        this.argument as ({AiModelKind kind, String? databasePath});
    return resolvedAiModelOptionIdForKind(
      ref,
      kind: argument.kind,
      databasePath: argument.databasePath,
    );
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ResolvedAiModelOptionIdForKindProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$resolvedAiModelOptionIdForKindHash() =>
    r'ceae513eeac57ab2f655f728e1fbb59e5bdf0220';

final class ResolvedAiModelOptionIdForKindFamily extends $Family
    with
        $FunctionalFamilyOverride<
          String?,
          ({AiModelKind kind, String? databasePath})
        > {
  ResolvedAiModelOptionIdForKindFamily._()
    : super(
        retry: null,
        name: r'resolvedAiModelOptionIdForKindProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ResolvedAiModelOptionIdForKindProvider call({
    required AiModelKind kind,
    String? databasePath,
  }) => ResolvedAiModelOptionIdForKindProvider._(
    argument: (kind: kind, databasePath: databasePath),
    from: this,
  );

  @override
  String toString() => r'resolvedAiModelOptionIdForKindProvider';
}

@ProviderFor(currentAiConfig)
final currentAiConfigProvider = CurrentAiConfigFamily._();

final class CurrentAiConfigProvider
    extends $FunctionalProvider<AiProvider?, AiProvider?, AiProvider?>
    with $Provider<AiProvider?> {
  CurrentAiConfigProvider._({
    required CurrentAiConfigFamily super.from,
    required ({String? providerId, String? model}) super.argument,
  }) : super(
         retry: null,
         name: r'currentAiConfigProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$currentAiConfigHash();

  @override
  String toString() {
    return r'currentAiConfigProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $ProviderElement<AiProvider?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AiProvider? create(Ref ref) {
    final argument = this.argument as ({String? providerId, String? model});
    return currentAiConfig(
      ref,
      providerId: argument.providerId,
      model: argument.model,
    );
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiProvider? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiProvider?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CurrentAiConfigProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$currentAiConfigHash() => r'10529ebc3a71925fdc0e1cc241550ebf9a423ee8';

final class CurrentAiConfigFamily extends $Family
    with
        $FunctionalFamilyOverride<
          AiProvider?,
          ({String? providerId, String? model})
        > {
  CurrentAiConfigFamily._()
    : super(
        retry: null,
        name: r'currentAiConfigProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  CurrentAiConfigProvider call({String? providerId, String? model}) =>
      CurrentAiConfigProvider._(
        argument: (providerId: providerId, model: model),
        from: this,
      );

  @override
  String toString() => r'currentAiConfigProvider';
}

@ProviderFor(resolvedAiModelOptionForRole)
final resolvedAiModelOptionForRoleProvider =
    ResolvedAiModelOptionForRoleFamily._();

final class ResolvedAiModelOptionForRoleProvider
    extends $FunctionalProvider<AiModelOption?, AiModelOption?, AiModelOption?>
    with $Provider<AiModelOption?> {
  ResolvedAiModelOptionForRoleProvider._({
    required ResolvedAiModelOptionForRoleFamily super.from,
    required ({AiModelRole role, String? databasePath}) super.argument,
  }) : super(
         retry: null,
         name: r'resolvedAiModelOptionForRoleProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$resolvedAiModelOptionForRoleHash();

  @override
  String toString() {
    return r'resolvedAiModelOptionForRoleProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $ProviderElement<AiModelOption?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AiModelOption? create(Ref ref) {
    final argument =
        this.argument as ({AiModelRole role, String? databasePath});
    return resolvedAiModelOptionForRole(
      ref,
      role: argument.role,
      databasePath: argument.databasePath,
    );
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiModelOption? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiModelOption?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ResolvedAiModelOptionForRoleProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$resolvedAiModelOptionForRoleHash() =>
    r'07c2e1f307e90150630f8fc0d8a7ba57d1d88b43';

final class ResolvedAiModelOptionForRoleFamily extends $Family
    with
        $FunctionalFamilyOverride<
          AiModelOption?,
          ({AiModelRole role, String? databasePath})
        > {
  ResolvedAiModelOptionForRoleFamily._()
    : super(
        retry: null,
        name: r'resolvedAiModelOptionForRoleProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ResolvedAiModelOptionForRoleProvider call({
    required AiModelRole role,
    String? databasePath,
  }) => ResolvedAiModelOptionForRoleProvider._(
    argument: (role: role, databasePath: databasePath),
    from: this,
  );

  @override
  String toString() => r'resolvedAiModelOptionForRoleProvider';
}

@ProviderFor(resolvedAiModelOptionForKind)
final resolvedAiModelOptionForKindProvider =
    ResolvedAiModelOptionForKindFamily._();

final class ResolvedAiModelOptionForKindProvider
    extends $FunctionalProvider<AiModelOption?, AiModelOption?, AiModelOption?>
    with $Provider<AiModelOption?> {
  ResolvedAiModelOptionForKindProvider._({
    required ResolvedAiModelOptionForKindFamily super.from,
    required ({AiModelKind kind, String? databasePath}) super.argument,
  }) : super(
         retry: null,
         name: r'resolvedAiModelOptionForKindProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$resolvedAiModelOptionForKindHash();

  @override
  String toString() {
    return r'resolvedAiModelOptionForKindProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $ProviderElement<AiModelOption?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  AiModelOption? create(Ref ref) {
    final argument =
        this.argument as ({AiModelKind kind, String? databasePath});
    return resolvedAiModelOptionForKind(
      ref,
      kind: argument.kind,
      databasePath: argument.databasePath,
    );
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AiModelOption? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AiModelOption?>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ResolvedAiModelOptionForKindProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$resolvedAiModelOptionForKindHash() =>
    r'485754747ba1a4de831c414212019b6cd203e562';

final class ResolvedAiModelOptionForKindFamily extends $Family
    with
        $FunctionalFamilyOverride<
          AiModelOption?,
          ({AiModelKind kind, String? databasePath})
        > {
  ResolvedAiModelOptionForKindFamily._()
    : super(
        retry: null,
        name: r'resolvedAiModelOptionForKindProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ResolvedAiModelOptionForKindProvider call({
    required AiModelKind kind,
    String? databasePath,
  }) => ResolvedAiModelOptionForKindProvider._(
    argument: (kind: kind, databasePath: databasePath),
    from: this,
  );

  @override
  String toString() => r'resolvedAiModelOptionForKindProvider';
}

@ProviderFor(isAiConfigured)
final isAiConfiguredProvider = IsAiConfiguredProvider._();

final class IsAiConfiguredProvider extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  IsAiConfiguredProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'isAiConfiguredProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$isAiConfiguredHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return isAiConfigured(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$isAiConfiguredHash() => r'00014d5e278b7147e7f0760da0a606912615fc13';

@ProviderFor(currentSearchEngine)
final currentSearchEngineProvider = CurrentSearchEngineProvider._();

final class CurrentSearchEngineProvider
    extends $FunctionalProvider<SearchEngine, SearchEngine, SearchEngine>
    with $Provider<SearchEngine> {
  CurrentSearchEngineProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'currentSearchEngineProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$currentSearchEngineHash();

  @$internal
  @override
  $ProviderElement<SearchEngine> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  SearchEngine create(Ref ref) {
    return currentSearchEngine(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SearchEngine value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SearchEngine>(value),
    );
  }
}

String _$currentSearchEngineHash() =>
    r'60f79627830c3ff21229f802a6f3fcbf2e836db2';

@ProviderFor(memoryAutoExtract)
final memoryAutoExtractProvider = MemoryAutoExtractProvider._();

final class MemoryAutoExtractProvider
    extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  MemoryAutoExtractProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'memoryAutoExtractProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$memoryAutoExtractHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return memoryAutoExtract(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$memoryAutoExtractHash() => r'c07312e32dc4c2c97e7349b92ed1c6dfc1c458e7';

@ProviderFor(memoryExtractionIntervalMinutes)
final memoryExtractionIntervalMinutesProvider =
    MemoryExtractionIntervalMinutesProvider._();

final class MemoryExtractionIntervalMinutesProvider
    extends $FunctionalProvider<int, int, int>
    with $Provider<int> {
  MemoryExtractionIntervalMinutesProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'memoryExtractionIntervalMinutesProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$memoryExtractionIntervalMinutesHash();

  @$internal
  @override
  $ProviderElement<int> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  int create(Ref ref) {
    return memoryExtractionIntervalMinutes(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(int value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<int>(value),
    );
  }
}

String _$memoryExtractionIntervalMinutesHash() =>
    r'be59cea21c288bb7dcfc344cc2203bdc74e1a01b';

@ProviderFor(changeRecordRetentionDays)
final changeRecordRetentionDaysProvider = ChangeRecordRetentionDaysProvider._();

final class ChangeRecordRetentionDaysProvider
    extends $FunctionalProvider<int, int, int>
    with $Provider<int> {
  ChangeRecordRetentionDaysProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'changeRecordRetentionDaysProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$changeRecordRetentionDaysHash();

  @$internal
  @override
  $ProviderElement<int> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  int create(Ref ref) {
    return changeRecordRetentionDays(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(int value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<int>(value),
    );
  }
}

String _$changeRecordRetentionDaysHash() =>
    r'42abed8dfea63487c2384deb5ffb78f462417790';

@ProviderFor(backupDirectory)
final backupDirectoryProvider = BackupDirectoryProvider._();

final class BackupDirectoryProvider
    extends $FunctionalProvider<String, String, String>
    with $Provider<String> {
  BackupDirectoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'backupDirectoryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$backupDirectoryHash();

  @$internal
  @override
  $ProviderElement<String> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  String create(Ref ref) {
    return backupDirectory(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String>(value),
    );
  }
}

String _$backupDirectoryHash() => r'd5c8cd1958a913a0d5f0e1d000a47c3678e9ddbb';

@ProviderFor(backupFrequency)
final backupFrequencyProvider = BackupFrequencyProvider._();

final class BackupFrequencyProvider
    extends
        $FunctionalProvider<BackupFrequency, BackupFrequency, BackupFrequency>
    with $Provider<BackupFrequency> {
  BackupFrequencyProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'backupFrequencyProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$backupFrequencyHash();

  @$internal
  @override
  $ProviderElement<BackupFrequency> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  BackupFrequency create(Ref ref) {
    return backupFrequency(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(BackupFrequency value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<BackupFrequency>(value),
    );
  }
}

String _$backupFrequencyHash() => r'3a18a44cb8871f1c83692e4ba5845bb9b25bce42';

@ProviderFor(lastBackupTime)
final lastBackupTimeProvider = LastBackupTimeProvider._();

final class LastBackupTimeProvider
    extends $FunctionalProvider<DateTime?, DateTime?, DateTime?>
    with $Provider<DateTime?> {
  LastBackupTimeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lastBackupTimeProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lastBackupTimeHash();

  @$internal
  @override
  $ProviderElement<DateTime?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  DateTime? create(Ref ref) {
    return lastBackupTime(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DateTime? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DateTime?>(value),
    );
  }
}

String _$lastBackupTimeHash() => r'9c9a2e0efe0b0b4ef04d8f41dde75013c96a6e88';

@ProviderFor(backupService)
final backupServiceProvider = BackupServiceProvider._();

final class BackupServiceProvider
    extends $FunctionalProvider<BackupService, BackupService, BackupService>
    with $Provider<BackupService> {
  BackupServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'backupServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$backupServiceHash();

  @$internal
  @override
  $ProviderElement<BackupService> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  BackupService create(Ref ref) {
    return backupService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(BackupService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<BackupService>(value),
    );
  }
}

String _$backupServiceHash() => r'74e878b8ec8677fffe3b5b1aea6d3ee5c504c106';

@ProviderFor(autoBackupScheduler)
final autoBackupSchedulerProvider = AutoBackupSchedulerProvider._();

final class AutoBackupSchedulerProvider
    extends
        $FunctionalProvider<
          AutoBackupScheduler,
          AutoBackupScheduler,
          AutoBackupScheduler
        >
    with $Provider<AutoBackupScheduler> {
  AutoBackupSchedulerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'autoBackupSchedulerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$autoBackupSchedulerHash();

  @$internal
  @override
  $ProviderElement<AutoBackupScheduler> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  AutoBackupScheduler create(Ref ref) {
    return autoBackupScheduler(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(AutoBackupScheduler value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<AutoBackupScheduler>(value),
    );
  }
}

String _$autoBackupSchedulerHash() =>
    r'fc65468c47d20ac731b4dcfbf73cf0484927eb99';

@ProviderFor(storageCleanupScheduler)
final storageCleanupSchedulerProvider = StorageCleanupSchedulerProvider._();

final class StorageCleanupSchedulerProvider
    extends
        $FunctionalProvider<
          StorageCleanupService,
          StorageCleanupService,
          StorageCleanupService
        >
    with $Provider<StorageCleanupService> {
  StorageCleanupSchedulerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'storageCleanupSchedulerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$storageCleanupSchedulerHash();

  @$internal
  @override
  $ProviderElement<StorageCleanupService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  StorageCleanupService create(Ref ref) {
    return storageCleanupScheduler(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(StorageCleanupService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<StorageCleanupService>(value),
    );
  }
}

String _$storageCleanupSchedulerHash() =>
    r'6546d33b581e76cd9774a8c4edbc33dea82466ab';
