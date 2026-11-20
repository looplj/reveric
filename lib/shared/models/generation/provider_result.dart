// 职责: 定义图片与视频共用的提交、查询及输出合同，并严格解析协议返回值。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/services/plugins/host.dart
import 'dart:convert';

String _text(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field must be a nonempty string');
  }
  return value;
}

Map<String, dynamic> _object(Object? value, String field) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$field must be an object');
  }
  return value;
}

/// Canonical JSON round-trip also detaches mutable plugin/native response objects.
Map<String, dynamic>? providerResultState(Object? value) {
  if (value == null) {
    return null;
  }
  final object = _object(value, 'state');
  final seen = Set<Object>.identity();
  void validate(Object? item) {
    if (item == null ||
        item is String ||
        item is bool ||
        (item is num && item.isFinite)) {
      return;
    }
    if (item is! List && item is! Map<String, dynamic>) {
      throw const FormatException('State must contain JSON values');
    }
    if (!seen.add(item)) {
      throw const FormatException('State must not contain cycles');
    }
    try {
      for (final value
          in item is List ? item : (item as Map<String, dynamic>).values) {
        validate(value);
      }
    } finally {
      seen.remove(item);
    }
  }

  validate(object);
  final encoded = jsonEncode(object);
  if (utf8.encode(encoded).length > 64 * 1024) {
    throw const FormatException('State exceeds 64 KB');
  }
  return Map<String, dynamic>.unmodifiable(
    jsonDecode(encoded) as Map<String, dynamic>,
  );
}

sealed class ProviderOutput {
  const ProviderOutput();
  Map<String, dynamic> toJson();
  factory ProviderOutput.fromJson(Map<String, dynamic> value) =>
      switch (value['kind']) {
        'url' => ProviderUrlOutput(
          _text(value['url'], 'output.url'),
          headers: !value.containsKey('headers')
              ? const {}
              : _headers(value['headers']),
        ),
        'file' => ProviderFileOutput(
          handle: _text(value['handle'], 'output.handle'),
          mimeType: _text(value['mimeType'], 'output.mimeType'),
          byteLength:
              value['byteLength'] is int && (value['byteLength'] as int) > 0
              ? value['byteLength'] as int
              : throw const FormatException('Invalid output byteLength'),
        ),
        _ => throw const FormatException('Unknown output kind'),
      };
  static Map<String, String> _headers(Object? value) {
    if (value is! Map ||
        value.entries.any(
          (e) =>
              e.key is! String ||
              e.value is! String ||
              (e.key as String).isEmpty ||
              RegExp(r'[\r\n]').hasMatch('${e.key}${e.value}'),
        )) {
      throw const FormatException('Invalid output headers');
    }
    return Map<String, String>.from(value);
  }
}

final class ProviderUrlOutput extends ProviderOutput {
  ProviderUrlOutput(this.url, {Map<String, String> headers = const {}})
    : headers = Map.unmodifiable(ProviderOutput._headers(headers)) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Output URL must be HTTP(S)');
    }
  }
  final String url;
  final Map<String, String> headers;
  @override
  Map<String, dynamic> toJson() => {
    'kind': 'url',
    'url': url,
    if (headers.isNotEmpty) 'headers': headers,
  };
}

final class ProviderFileOutput extends ProviderOutput {
  ProviderFileOutput({
    required this.handle,
    required this.mimeType,
    required this.byteLength,
  }) {
    _text(handle, 'output.handle');
    _text(mimeType, 'output.mimeType');
    if (byteLength < 1) {
      throw const FormatException('Invalid output byteLength');
    }
  }
  final String handle, mimeType;
  final int byteLength;
  @override
  Map<String, dynamic> toJson() => {
    'kind': 'file',
    'handle': handle,
    'mimeType': mimeType,
    'byteLength': byteLength,
  };
}

class ProviderFailure implements Exception {
  const ProviderFailure({
    required this.code,
    required this.message,
    this.detail,
  });
  final String code, message;
  final String? detail;
  factory ProviderFailure.fromJson(Map<String, dynamic> value) {
    final detail = value['detail'];
    if (detail != null && detail is! String) {
      throw const FormatException('error.detail must be a string');
    }
    return ProviderFailure(
      code: _text(value['code'], 'error.code'),
      message: _text(value['message'], 'error.message'),
      detail: detail as String?,
    );
  }
  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    if (detail != null) 'detail': detail,
  };
  @override
  String toString() => '$code: $message';
}

class ProviderQueryInput {
  ProviderQueryInput(this.remoteTaskId, {Map<String, dynamic>? state})
    : state = providerResultState(state) {
    _text(remoteTaskId, 'remoteTaskId');
  }
  final String remoteTaskId;
  final Map<String, dynamic>? state;
  Map<String, dynamic> toJson() => {
    'remoteTaskId': remoteTaskId,
    if (state != null) 'state': state,
  };
}

sealed class ProviderSubmitResult {
  const ProviderSubmitResult();
  Map<String, dynamic> toJson();
  factory ProviderSubmitResult.fromJson(Map<String, dynamic> value) =>
      switch (value['status']) {
        'submitted' => ProviderSubmitted(
          _text(value['remoteTaskId'], 'remoteTaskId'),
          state: value.containsKey('state')
              ? _object(value['state'], 'state')
              : null,
        ),
        'succeeded' => ProviderSucceeded.fromJson(value),
        _ => throw const FormatException('Invalid submission status'),
      };
}

final class ProviderSubmitted extends ProviderSubmitResult {
  ProviderSubmitted(this.remoteTaskId, {Map<String, dynamic>? state})
    : state = providerResultState(state) {
    _text(remoteTaskId, 'remoteTaskId');
  }
  final String remoteTaskId;
  final Map<String, dynamic>? state;
  @override
  Map<String, dynamic> toJson() => {
    'status': 'submitted',
    'remoteTaskId': remoteTaskId,
    if (state != null) 'state': state,
  };
}

sealed class ProviderQueryResult {
  const ProviderQueryResult();
  Map<String, dynamic> toJson();
  factory ProviderQueryResult.fromJson(Map<String, dynamic> value) =>
      switch (value['status']) {
        'succeeded' => ProviderSucceeded.fromJson(value),
        'queued' => ProviderPending(
          queued: true,
          state: value.containsKey('state')
              ? _object(value['state'], 'state')
              : null,
        ),
        'running' => ProviderPending(
          state: value.containsKey('state')
              ? _object(value['state'], 'state')
              : null,
        ),
        'failed' => ProviderFailed(
          ProviderFailure.fromJson(_object(value['error'], 'error')),
        ),
        'cancelled' => const ProviderStopped(cancelled: true),
        'expired' => const ProviderStopped(),
        'unknown' => ProviderUnknown(_text(value['reason'], 'reason')),
        _ => throw const FormatException('Invalid query status'),
      };
}

final class ProviderSucceeded
    implements ProviderSubmitResult, ProviderQueryResult {
  ProviderSucceeded(List<ProviderOutput> outputs)
    : outputs = List.unmodifiable(outputs) {
    if (outputs.isEmpty) {
      throw const FormatException('At least one output is required');
    }
  }
  final List<ProviderOutput> outputs;
  factory ProviderSucceeded.fromJson(Map<String, dynamic> value) {
    final outputs = value['outputs'];
    if (outputs is! List) {
      throw const FormatException('Expected outputs array');
    }
    return ProviderSucceeded(
      outputs
          .map((v) => ProviderOutput.fromJson(_object(v, 'output')))
          .toList(),
    );
  }
  @override
  Map<String, dynamic> toJson() => {
    'status': 'succeeded',
    'outputs': outputs.map((v) => v.toJson()).toList(),
  };
}

final class ProviderPending extends ProviderQueryResult {
  ProviderPending({this.queued = false, Map<String, dynamic>? state})
    : state = providerResultState(state);
  final bool queued;
  final Map<String, dynamic>? state;
  @override
  Map<String, dynamic> toJson() => {
    'status': queued ? 'queued' : 'running',
    if (state != null) 'state': state,
  };
}

final class ProviderFailed extends ProviderQueryResult {
  const ProviderFailed(this.error);
  final ProviderFailure error;
  @override
  Map<String, dynamic> toJson() => {
    'status': 'failed',
    'error': error.toJson(),
  };
}

final class ProviderStopped extends ProviderQueryResult {
  const ProviderStopped({this.cancelled = false});
  final bool cancelled;
  @override
  Map<String, dynamic> toJson() => {
    'status': cancelled ? 'cancelled' : 'expired',
  };
}

final class ProviderUnknown extends ProviderQueryResult {
  const ProviderUnknown(this.reason);
  final String reason;
  @override
  Map<String, dynamic> toJson() => {'status': 'unknown', 'reason': reason};
}
