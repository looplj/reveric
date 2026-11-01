// 职责: 通过真实 fjs 工具与原生页面共享私有 SQLite，验证类型桥接、声明边界及启停持久化。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/sqlite.dart
//   lib/shared/services/plugins/sql_bridge.dart
import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final path = Platform.environment['FJS_PROBE_LIBRARY'];
    if (path == null) {
      throw StateError('Set FJS_PROBE_LIBRARY');
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(path));
  });
  test(
    'tool and native page share exact int64/blob data across enable cycles',
    () async {
      final root = await Directory.systemTemp.createTemp('plugin-sql-host-');
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final directory = await Directory(
        '${root.path}/plugins/test.sql/1.0.0',
      ).create(recursive: true);
      await File('${directory.path}/001.sql').writeAsString(
        'CREATE TABLE notes(id INTEGER PRIMARY KEY, text TEXT NOT NULL, big INTEGER, data BLOB, deleted_at INTEGER);',
      );
      await File('${directory.path}/page.js').writeAsString("""
var __revericView={mount(context){__revericUi.mount(()=>{
const rows=__revericUi.resource(()=>0,()=>context.sqlite.query({sql:'SELECT big,data FROM notes'}));
return __revericUi.element('Text',{get text(){const row=rows.value()?.[0];return row?String(row.big)+':'+Array.from(row.data).join(','):rows.error()?String(rows.error()):'Loading';}});
},context.root);}};
""");
      final package = PluginPackage(
        'plugins/test.sql/1.0.0',
        PluginManifest.fromJson({
          'id': 'test.sql',
          'name': 'SQL',
          'version': '1.0.0',
          'main': 'index.js',
          'pluginApiVersion': '^1',
          'pages': {
            'page': {
              'title': 'SQL page',
              'location': 'home.plugin',
              'protocol': 'reveric-tsx-v1',
              'source': 'page.js',
            },
          },
          'database': {
            'version': 1,
            'migrations': [
              {'version': 1, 'source': '001.sql'},
            ],
          },
        }),
        """
var __revericPlugin={apply(setup){

setup.tools.register({name:'Store',description:'Store data',inputSchema:{type:'object'},handler:async(input,context)=>{
const insert=await context.sqlite.execute({sql:'INSERT INTO notes(text,big,data) VALUES (?,?,?)',params:['stored',9223372036854775807n,new Uint8Array([0,255,1])]});
const row=(await context.sqlite.query({sql:'SELECT big,data FROM notes WHERE id=?',params:[insert.lastInsertRowId]}))[0];
return {rowId:String(insert.lastInsertRowId),big:String(row.big),blob:Array.from(row.data)};
}});
}};
""",
        source: 'local',
      );
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package],
        applicationSupport: () async => root,
      );
      try {
        await host.start();
        await host.setEnabled(package.manifest.id, true);
        expect(host.statuses.single.state, 'available');
        expect(await host.execute('Store', {}), {
          'rowId': '1',
          'big': '9223372036854775807',
          'blob': [0, 255, 1],
        });
        final session = await host.openTsxView(
          host.views.single,
          workId: null,
          confirmDiscard: () async => true,
        );
        try {
          final end = DateTime.now().add(const Duration(seconds: 8));
          while (!session.tree.nodes.values.any(
            (n) => n.props['text'] == '9223372036854775807:0,255,1',
          )) {
            if (session.error.value != null) {
              throw StateError(session.error.value!);
            }
            if (DateTime.now().isAfter(end)) {
              throw TimeoutException(
                'SQL native page ${session.tree.nodes.values.map((n) => n.props)}',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          final databases = await host.privateDatabases();
          final long = databases.call('test.sql', 'query', {
            'statement': {
              'sql':
                  'WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT SUM(x) AS total FROM n',
            },
          });
          final pending = session.hostCall('sqlite.execute', {
            'statement': {
              'sql': "INSERT INTO notes(text) VALUES ('cancelled page')",
            },
          });
          final cancelled = expectLater(
            pending,
            throwsA(
              isA<PluginHostError>().having((e) => e.code, 'code', 'cancelled'),
            ),
          );
          await Future<void>.delayed(Duration.zero);
          await session.close();
          await cancelled;
          await long;
        } finally {
          await session.close();
          session.dispose();
        }
        await host.setEnabled('test.sql', false);
        await host.setEnabled('test.sql', true);
        expect(host.statuses.single.state, 'available');
        expect((await host.execute('Store', {}))['rowId'], '2');
        expect(
          File('${root.path}/plugin_data/test.sql/data.sqlite').existsSync(),
          true,
        );
        expect(
          await db
              .customSelect("SELECT name FROM sqlite_master WHERE name='notes'")
              .get(),
          isEmpty,
        );
      } finally {
        await host.dispose();
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'undeclared SQL returns diagnostic error without creating an empty private DB',
    () async {
      final root = await Directory.systemTemp.createTemp('plugin-no-db-');
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final package = PluginPackage(
        'unused',
        PluginManifest.fromJson({
          'id': 'test.no-db',
          'name': 'No database',
          'version': '1.0.0',
          'pluginApiVersion': '^1',
          'main': 'index.js',
        }),
        """
var __revericPlugin={apply(setup){setup.tools.register({name:'Undeclared',description:'Query',inputSchema:{type:'object'},handler:async(input,context)=>{try{await context.sqlite.query({sql:'SELECT 1'});return {unexpected:true};}catch(error){return {code:error.code};}}});}};
""",
      );
      final host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package],
        applicationSupport: () async => root,
      );
      try {
        await host.start();
        await host.setEnabled(package.manifest.id, true);
        expect(await host.execute('Undeclared', {}), {
          'code': 'database_not_declared',
        });
        expect(Directory('${root.path}/plugin_data').existsSync(), false);
      } finally {
        await host.dispose();
        await database.close();
        await root.delete(recursive: true);
      }
    },
  );
}
