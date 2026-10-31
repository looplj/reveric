// 职责: 验证视图 source map 能把运行时产物位置改写回 TSX 源码位置。
// 关联文件:
//   lib/shared/services/plugins/source_map.dart
//   assets/plugins/reveric.memory/dist/views/manage.js.map
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/plugins/source_map.dart';

void main() {
  test('maps built view frames back to TSX lines', () {
    const view = 'assets/plugins/reveric.memory/dist/views/manage';
    final generated = File('$view.js').readAsLinesSync();
    final source = File(
      'plugins/memory/src/views/manage.tsx',
    ).readAsLinesSync();
    final map = PluginSourceMap.parse(File('$view.js.map').readAsStringSync());
    final line = generated.indexWhere((text) => text.contains('搜索记忆'));
    final column = generated[line].indexOf('搜索记忆') + 1;
    final expected = source.indexWhere((text) => text.contains('搜索记忆')) + 1;
    final rewritten = map.rewrite(
      'Error\n    at f (plugin-view.js:${line + 1}:$column)\n    at g (eval_script:1:1)',
      'plugin-view.js',
    );
    expect(
      rewritten,
      contains('(plugins/memory/src/views/manage.tsx:$expected:'),
    );
    expect(rewritten, contains('eval_script:1:1'));
  });
  test('rejects malformed maps', () {
    expect(
      () =>
          PluginSourceMap.parse('{"version":3,"sources":[],"mappings":"AAAA"}'),
      throwsFormatException,
    );
  });
}
