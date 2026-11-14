// 职责: 验证统一媒体任务合同拒绝模糊提交和非法输出，并保留恢复所需状态与下载头。
// 关联文件:
//   lib/shared/models/generation/provider_result.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/generation/provider_result.dart';

void main() {
  test('preserves task state and keeps download headers per candidate', () {
    final submitted =
        ProviderSubmitResult.fromJson({
              'status': 'submitted',
              'remoteTaskId': 'remote',
              'state': {'node': 3},
            })
            as ProviderSubmitted;
    expect(
      ProviderQueryInput(
        submitted.remoteTaskId,
        state: submitted.state,
      ).toJson(),
      {
        'remoteTaskId': 'remote',
        'state': {'node': 3},
      },
    );
    final success =
        ProviderQueryResult.fromJson({
              'status': 'succeeded',
              'outputs': [
                {
                  'kind': 'url',
                  'url': 'https://example.com/a',
                  'headers': {'X-Token': 'private'},
                },
                {'kind': 'url', 'url': 'https://example.com/b'},
                {
                  'kind': 'file',
                  'handle': 'host-output',
                  'mimeType': 'image/png',
                  'byteLength': 123,
                },
              ],
            })
            as ProviderSucceeded;
    expect((success.outputs[0] as ProviderUrlOutput).headers, {
      'X-Token': 'private',
    });
    expect((success.outputs[1] as ProviderUrlOutput).headers, isEmpty);
    expect(
      ProviderSubmitResult.fromJson(
        jsonDecode(jsonEncode(success.toJson())),
      ).toJson(),
      success.toJson(),
    );
    expect(ProviderQueryResult.fromJson({'status': 'running'}).toJson(), {
      'status': 'running',
    });
    expect(
      ProviderQueryResult.fromJson({
        'status': 'running',
        'state': <String, dynamic>{},
      }).toJson(),
      {'status': 'running', 'state': <String, dynamic>{}},
    );
  });
  test('rejects unknown submission and invalid outputs', () {
    for (final value in <Map<String, dynamic>>[
      {'status': 'submitted'},
      {'status': 'submitted', 'remoteTaskId': ' '},
      {'status': 'succeeded', 'outputs': []},
      {'status': 'failed'},
      {'status': 'submitted', 'remoteTaskId': 'id', 'state': null},
    ]) {
      expect(() => ProviderSubmitResult.fromJson(value), throwsFormatException);
    }
    for (final value in <Map<String, dynamic>>[
      {'kind': 'url', 'url': 'file:///private/file'},
      {'kind': 'url', 'url': 'https://user:pass@example.com/a'},
      {'kind': 'base64', 'data': 'AAAA'},
      {
        'kind': 'url',
        'url': 'https://example.com/a',
        'headers': {'X-Token': 'x\r\nInjected: y'},
      },
      {'kind': 'file', 'handle': '', 'mimeType': 'image/png', 'byteLength': 12},
      {'kind': 'file', 'handle': 'h', 'mimeType': 'image/png', 'byteLength': 0},
    ]) {
      expect(() => ProviderOutput.fromJson(value), throwsFormatException);
    }
  });
  test('state is bounded strict JSON detached from caller mutation', () {
    final source = <String, dynamic>{
      'nested': {'value': 1},
    };
    final result = ProviderSubmitted('id', state: source);
    (source['nested'] as Map)['value'] = 2;
    expect(result.state!['nested'], {'value': 1});
    final cyclic = <String, dynamic>{};
    cyclic['self'] = cyclic;
    for (final state in [
      <String, dynamic>{'invalid': double.infinity},
      <String, dynamic>{'invalid': DateTime.now()},
      <String, dynamic>{'oversize': '中' * 30000},
      cyclic,
    ]) {
      expect(
        () => ProviderSubmitted('id', state: state),
        throwsFormatException,
      );
    }
  });
  test(
    'terminal query results retain diagnostics and reconciliation reason',
    () {
      for (final value in <Map<String, dynamic>>[
        {
          'status': 'failed',
          'error': {
            'code': 'moderation',
            'message': 'Review failed',
            'detail': 'policy',
          },
        },
        {'status': 'cancelled'},
        {'status': 'expired'},
        {'status': 'unknown', 'reason': 'not retained'},
      ]) {
        expect(ProviderQueryResult.fromJson(value).toJson(), value);
      }
    },
  );
}
