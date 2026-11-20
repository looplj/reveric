// 职责: 验证渠道模型名称、日期与任务路径匹配，防止不同型号混用能力。
// 关联文件:
//   lib/shared/models/video/catalog.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/video/catalog.dart';

void main() {
  test('official IDs retain their exact catalog entries', () {
    for (final entry in videoModelsCatalog.entries) {
      expect(lookupVideoModel(entry.key), same(entry.value));
    }
  });

  for (final entry in {
    'seedance-2.5': 'doubao-seedance-2-5-260628',
    'bytedance/seedance-2.5': 'doubao-seedance-2-5-260628',
    'bytedance/seedance-2.5/image-to-video': 'doubao-seedance-2-5-260628',
    'bytedance/seedance-2.5/text-to-video': 'doubao-seedance-2-5-260628',
    'bytedance/seedance-2.5-20260807/image-to-video':
        'doubao-seedance-2-5-260628',
    '  BYTEDANCE/Seedance_2_5  ': 'doubao-seedance-2-5-260628',
    'proxy/doubao-seedance-2-5-260628': 'doubao-seedance-2-5-260628',
    'seedance-2.5-flash': 'doubao-seedance-2-5-flash-261115',
    'bytedance/seedance-2.0': 'doubao-seedance-2-0-260128',
    'bytedance/seedance-2.0-mini': 'doubao-seedance-2-0-mini-260615',
    'bytedance/seedance-2.0-mini/image-to-video':
        'doubao-seedance-2-0-mini-260615',
    'bytedance/seedance-2.0-mini-20260811': 'doubao-seedance-2-0-mini-260615',
    'minimax/minimax-h3/image-to-video': 'MiniMax-H3',
    'alibaba/wan3.0-video': 'wan3.0-video',
    'alibaba/wan3.0-video-prime/image-to-video': 'wan3.0-video-prime',
  }.entries) {
    test('matches ${entry.key}', () {
      expect(
        lookupVideoModel(entry.key),
        same(videoModelsCatalog[entry.value]),
      );
    });
  }

  test('unknown variants and partial version numbers do not match', () {
    for (final id in [
      null,
      '',
      'unknown',
      'bytedance/seedance-2.0-faster',
      'doubao-seedance-2-0-faster-260128',
      'bytedance/seedance-2.0-mini-fast/image-to-video',
      'seedance-2.50',
      'seedance-2.5.1',
      'seedance-2.05',
      'seedance-2.5pro',
      'notseedance-2.5',
      'minimax-h30',
      'wan3.0-video-pro',
    ]) {
      expect(
        lookupVideoModel(id),
        isNull,
        reason: '$id must not use another model',
      );
    }
  });
}
