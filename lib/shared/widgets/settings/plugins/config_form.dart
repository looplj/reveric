// 职责: 插件配置表单 — 按清单 settings 与 actions 用 A2UI 组件库渲染，保存时校验并把配置与凭据变更交给调用方持久化，操作时把未保存的输入交给调用方执行，并在操作栏下方显示最近一次结果。
// 关联文件:
//   lib/shared/widgets/settings/plugins/config_surface.dart
//   lib/shared/models/plugin/setting_field.dart
//   lib/shared/models/plugin/action.dart
//   lib/shared/widgets/a2ui/surface_view.dart
//   lib/shared/widgets/a2ui/session.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/form.json
//   assets/translations/zh-CN/form.json
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
//   .agents/rules/design-system.md

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../models/plugin/action.dart';
import '../../../models/plugin/setting_field.dart';
import '../../../theme/theme.dart';
import '../../a2ui/session.dart';
import '../../a2ui/surface_view.dart';
import 'config_surface.dart';

final _log = AppLogger.forModule('PluginConfigForm');

/// 保存配置；失败时抛出异常，表单显示保存失败并保留用户输入。
typedef PluginConfigSaver =
    Future<void> Function(PluginConfigSubmission submission);

/// 用表单当前（可能未保存）的输入执行设置页操作。
typedef PluginActionRunner =
    Future<PluginActionResult> Function(
      String name,
      PluginConfigSubmission submission,
    );

/// 操作栏下方的结果行，显示最近一次保存或操作的结果。
class _Status {
  const _Status(this.text, {required this.ok, this.action, this.inputs});

  final String text;
  final bool ok;

  /// 产生结果的操作及其输入；输入变化后结果过期并清除。保存结果为 null。
  final String? action;
  final String? inputs;
}

/// 已保存配置的比较基准；保存成功后更新，用于判断是否有未保存的输入。
class _Baseline {
  _Baseline(this.settings);
  String settings;
}

String _encodeSettings(PluginConfigSubmission submission) =>
    jsonEncode(submission.settings);

/// 插件配置表单。插件未启用时也可展示；凭据原文不回显，只显示是否已设置。
///
/// [fields] 应保持同一实例，字段声明变化（如插件更新）时传入新实例会重建表单。
class PluginConfigForm extends HookWidget {
  const PluginConfigForm({
    super.key,
    required this.fields,
    required this.values,
    required this.savedSecrets,
    required this.onSave,
    this.actions = const [],
    this.onAction,
    this.modelOptions = const [],
    this.dirty,
  });

  final List<PluginSettingField> fields;

  /// 已保存的普通配置。
  final Map<String, Object?> values;

  /// 已保存凭据的字段名。
  final Set<String> savedSecrets;
  final PluginConfigSaver onSave;

  /// 设置页操作；[onAction] 为 null 时不显示操作按钮。
  final List<PluginAction> actions;
  final PluginActionRunner? onAction;

  /// `model` 字段可选的聊天模型。
  final List<PluginConfigModelOption> modelOptions;

  /// 有尚未保存的输入时为 true，供离开确认使用。
  final ValueNotifier<bool>? dirty;

  List<PluginAction> get _actions => onAction == null ? const [] : actions;

  @override
  Widget build(BuildContext context) {
    final strings = _strings(context);
    final locale = Localizations.localeOf(context);
    final onSaveRef = useRef(onSave);
    onSaveRef.value = onSave;
    final onActionRef = useRef(onAction);
    onActionRef.value = onAction;
    final actions = _actions;
    // 可选模型变化时重建表单；同一列表内容的新实例不重建，避免丢失输入。
    final modelSignature = [
      for (final option in modelOptions)
        '${option.selection.providerId}::${option.selection.model}:${option.label}',
    ].join('\n');
    final status = useMemoized(() => ValueNotifier<_Status?>(null), [
      fields,
      actions,
      locale,
      modelSignature,
    ]);
    useEffect(() => status.dispose, [status]);
    final baseline = useMemoized(() => _Baseline(''), [
      fields,
      actions,
      locale,
      modelSignature,
    ]);
    final session = useMemoized(() {
      late final A2uiSurfaceSession session;
      session = A2uiSurfaceSession.load(
        surfaceId: 'plugin-config',
        messages: buildPluginConfigMessages(
          fields: fields,
          values: values,
          savedSecrets: savedSecrets,
          strings: strings,
          locale: locale,
          actions: actions,
          modelOptions: modelOptions,
        ),
        onAction: (event) => switch (event.name) {
          clearSecretEvent => _clearSecret(session, event, strings, status),
          saveConfigEvent => _save(
            session: session,
            event: event,
            strings: strings,
            status: status,
            baseline: baseline,
            onSave: onSaveRef.value,
          ),
          runActionEvent => _runAction(
            session: session,
            event: event,
            strings: strings,
            status: status,
            locale: locale,
            onAction: onActionRef.value,
          ),
          _ => Future.value(const <A2uiDataUpdate>[]),
        },
      );
      baseline.settings = _encodeSettings(
        readPluginConfigSubmission(
          fields: fields,
          data: session.dataSnapshot(),
        ).submission,
      );
      return session;
    }, [fields, actions, locale, modelSignature]);
    // 页面数据每次变化后在 Dart 侧重算字段规则与操作可用性，写入 /valid、/actionReady
    // 供 checks 引用，并清除输入已变化的操作结果；写入会再触发一次，结果不变即停止。
    useEffect(() {
      final dataModel = session.surface?.dataModel;
      if (dataModel == null) {
        return null;
      }
      var scheduled = false;
      final subscription = dataModel.subscribe<Object?>('/', (_) {
        if (scheduled) {
          return;
        }
        scheduled = true;
        // 不在数据通知回调内同步写页面数据。
        scheduleMicrotask(() {
          scheduled = false;
          _refreshDerived(session, status, baseline);
        });
      });
      return subscription.unsubscribe;
    }, [session]);
    // 界面在本帧才卸载，会话推迟到帧末释放，保证晚于界面释放。
    useEffect(
      () =>
          () => WidgetsBinding.instance.addPostFrameCallback(
            (_) => session.dispose(),
          ),
      [session],
    );

    if (fields.isEmpty && actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        A2uiSurfaceView(key: ObjectKey(session), session: session),
        ValueListenableBuilder<_Status?>(
          valueListenable: status,
          builder: (context, value, _) =>
              value == null ? const SizedBox.shrink() : _StatusLine(value),
        ),
      ],
    );
  }

  void _refreshDerived(
    A2uiSurfaceSession session,
    ValueNotifier<_Status?> status,
    _Baseline baseline,
  ) {
    if (session.isDisposed) {
      return;
    }
    final data = session.dataSnapshot();
    final root = data is Map ? data : const {};
    final actions = _actions;
    _updateDirty(data, baseline);
    final validity = pluginConfigValidity(fields: fields, data: data);
    final readiness = pluginActionReadiness(
      fields: fields,
      actions: actions,
      data: data,
    );
    const equality = DeepCollectionEquality();
    final updates = [
      if (!equality.equals(root['valid'], validity))
        A2uiDataUpdate(path: '/valid', value: validity),
      if (!equality.equals(root['actionReady'], readiness))
        A2uiDataUpdate(path: '/actionReady', value: readiness),
    ];
    final shown = status.value;
    final action = actions.firstWhereOrNull(
      (item) => item.name == shown?.action,
    );
    if (action != null &&
        shown?.inputs !=
            pluginActionInputs(fields: fields, action: action, data: data)) {
      status.value = null;
    }
    if (updates.isNotEmpty) {
      session.applyDataUpdates(updates);
    }
  }

  void _updateDirty(Object? data, _Baseline baseline) {
    final notifier = dirty;
    if (notifier == null) {
      return;
    }
    final submission = readPluginConfigSubmission(
      fields: fields,
      data: data,
    ).submission;
    notifier.value =
        submission.secrets.isNotEmpty ||
        _encodeSettings(submission) != baseline.settings;
  }

  /// 用页面当前输入执行操作；结果返回前输入已变化时不显示，避免结果对应旧输入。
  Future<List<A2uiDataUpdate>> _runAction({
    required A2uiSurfaceSession session,
    required A2uiActionEvent event,
    required PluginConfigStrings strings,
    required ValueNotifier<_Status?> status,
    required Locale locale,
    required PluginActionRunner? onAction,
  }) async {
    final name = event.context['action'];
    final action = _actions.firstWhereOrNull((item) => item.name == name);
    if (name is! String || action == null || onAction == null) {
      return const [];
    }
    status.value = null;
    final inputs = pluginActionInputs(
      fields: fields,
      action: action,
      data: event.data,
    );
    final submission = readPluginConfigSubmission(
      fields: fields,
      data: event.data,
    ).submission;
    PluginActionResult result;
    try {
      result = await onAction(name, submission);
    } on Object catch (error, stackTrace) {
      _log.error(
        'run plugin action failed: $name',
        error: error,
        stackTrace: stackTrace,
      );
      result = (ok: false, code: null);
    }
    if (session.isDisposed ||
        pluginActionInputs(
              fields: fields,
              action: action,
              data: session.dataSnapshot(),
            ) !=
            inputs) {
      return const [];
    }
    status.value = _Status(
      strings.actionResult(
        action.title.resolve(locale),
        pluginActionResultText(result, strings),
      ),
      ok: result.ok,
      action: name,
      inputs: inputs,
    );
    return const [];
  }

  /// 清空只标记待清除，点保存后才生效；清空必填凭据会在保存时关闭插件。
  Future<List<A2uiDataUpdate>> _clearSecret(
    A2uiSurfaceSession session,
    A2uiActionEvent event,
    PluginConfigStrings strings,
    ValueNotifier<_Status?> status,
  ) async {
    final key = event.context['key'];
    final field = fields.firstWhereOrNull((field) => field.key == key);
    if (key is! String || field == null) {
      return const [];
    }
    session.applyMessages([pluginSecretRowUpdate(key, saved: false)]);
    // 保存结果不再对应当前输入；操作结果按其输入是否变化另行清除。
    if (status.value?.action == null) {
      status.value = null;
    }
    return [
      A2uiDataUpdate(path: '/secrets/$key', value: ''),
      A2uiDataUpdate(path: '/secretSaved/$key', value: false),
      A2uiDataUpdate(path: '/secretCleared/$key', value: true),
      A2uiDataUpdate(
        path: '/secretHints/$key',
        value: field.required
            ? strings.requiredSecretClearHint
            : strings.secretClearHint,
      ),
    ];
  }

  Future<List<A2uiDataUpdate>> _save({
    required A2uiSurfaceSession session,
    required A2uiActionEvent event,
    required PluginConfigStrings strings,
    required ValueNotifier<_Status?> status,
    required _Baseline baseline,
    required PluginConfigSaver onSave,
  }) async {
    final (:submission, :issues) = readPluginConfigSubmission(
      fields: fields,
      data: event.data,
    );
    if (issues.isNotEmpty) {
      // 按钮的 checks 已拦截界面可见的问题；这里是保存前的最终校验。
      _log.warning('save blocked by invalid settings: $issues');
      status.value = _Status(strings.saveFailed, ok: false);
      return const [];
    }
    try {
      await onSave(submission);
    } on Object catch (error, stackTrace) {
      _log.error(
        'save plugin settings failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!session.isDisposed) {
        status.value = _Status(strings.saveFailed, ok: false);
      }
      return const [];
    }
    if (session.isDisposed) {
      return const [];
    }
    final updates = <A2uiDataUpdate>[];
    for (final MapEntry(:key, :value) in submission.secrets.entries) {
      final saved = value != null;
      session.applyMessages([pluginSecretRowUpdate(key, saved: saved)]);
      updates.addAll([
        A2uiDataUpdate(path: '/secrets/$key', value: ''),
        A2uiDataUpdate(path: '/secretSaved/$key', value: saved),
        A2uiDataUpdate(path: '/secretCleared/$key', value: false),
        A2uiDataUpdate(
          path: '/secretHints/$key',
          value: saved ? strings.secretSavedHint : '',
        ),
      ]);
    }
    baseline.settings = _encodeSettings(submission);
    status.value = _Status(strings.saved, ok: true);
    // 没有凭据更新时页面数据不变，不会触发重算，这里先按新基准刷新；
    // 凭据草稿随下面的更新清空，届时再重算一次。
    _updateDirty(session.dataSnapshot(), baseline);
    return updates;
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine(this.status);

  final _Status status;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final color = status.ok ? colors.success : colors.warningText;
    return Padding(
      padding: const EdgeInsets.only(top: RevericSpacing.sm),
      child: Row(
        children: [
          RevericIcon(
            status.ok ? RevericIcons.check : RevericIcons.warning_circle,
            size: 16,
            color: color,
          ),
          const SizedBox(width: RevericSpacing.xs),
          Expanded(
            child: Text(
              status.text,
              style: typo.uiSmall.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// 在 build 顶层取好全部文案；带参数的文案先取成模板，生成消息时再填值，
/// 避免在 hook 初始化阶段读取 InheritedWidget。
PluginConfigStrings _strings(BuildContext context) {
  final maxLengthTemplate = context.t(
    LocaleKeys.formMaxLength,
    namedArgs: {'length': '{length}'},
  );
  final rangeTemplate = context.t(
    LocaleKeys.formNumberRange,
    namedArgs: {'min': '{min}', 'max': '{max}'},
  );
  final minTemplate = context.t(
    LocaleKeys.formNumberMin,
    namedArgs: {'min': '{min}'},
  );
  final maxTemplate = context.t(
    LocaleKeys.formNumberMax,
    namedArgs: {'max': '{max}'},
  );
  final actionRequiresTemplate = context.t(
    LocaleKeys.pluginActionRequires,
    namedArgs: {'field': '{field}'},
  );
  final actionResultTemplate = context.t(
    LocaleKeys.pluginActionResult,
    namedArgs: {'action': '{action}', 'result': '{result}'},
  );
  final modelUnavailableTemplate = context.t(
    LocaleKeys.pluginConfigModelUnavailable,
    namedArgs: {'model': '{model}'},
  );

  String rangeText(num? min, num? max) {
    final template = min != null && max != null
        ? rangeTemplate
        : (min != null ? minTemplate : maxTemplate);
    return template.replaceAll('{min}', '$min').replaceAll('{max}', '$max');
  }

  return PluginConfigStrings(
    save: context.t(LocaleKeys.commonSave),
    saved: context.t(LocaleKeys.commonSaved),
    saveFailed: context.t(LocaleKeys.commonSaveFailed),
    clear: context.t(LocaleKeys.commonClear),
    required: context.t(LocaleKeys.formRequired),
    secretSavedHint: context.t(LocaleKeys.pluginConfigSecretSavedHint),
    secretClearHint: context.t(LocaleKeys.pluginConfigSecretClearHint),
    requiredSecretClearHint: context.t(
      LocaleKeys.pluginConfigRequiredSecretClearHint,
    ),
    invalidInteger: context.t(LocaleKeys.formInvalidInteger),
    invalidNumber: context.t(LocaleKeys.formInvalidNumber),
    maxLength: (length) => maxLengthTemplate.replaceAll('{length}', '$length'),
    range: rangeText,
    actionSucceeded: context.t(LocaleKeys.pluginActionSucceeded),
    actionUnauthorized: context.t(LocaleKeys.pluginActionUnauthorized),
    actionNetwork: context.t(LocaleKeys.pluginActionNetwork),
    actionTimeout: context.t(LocaleKeys.pluginActionTimeout),
    actionFailed: context.t(LocaleKeys.pluginActionFailed),
    actionRequires: (field) =>
        actionRequiresTemplate.replaceAll('{field}', field),
    actionResult: (action, result) => actionResultTemplate
        .replaceAll('{action}', action)
        .replaceAll('{result}', result),
    modelDefault: context.t(LocaleKeys.pluginConfigModelDefault),
    modelUnavailable: (model) =>
        modelUnavailableTemplate.replaceAll('{model}', model),
  );
}
