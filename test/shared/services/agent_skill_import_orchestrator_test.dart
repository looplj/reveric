// 职责: 验证远程技能下载、分支定位、附件保留、大小限制及取消行为。
// 关联文件:
//   lib/shared/services/agent_skill_import_orchestrator.dart
//   lib/shared/services/agent_skill_import_source.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/services/agent_skill_import_orchestrator.dart';
import 'package:reveric/shared/services/agent_skill_import_source.dart';
import 'package:reveric/shared/services/agent_skill_transfer.dart';

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
String _skill(String name) =>
    '---\nname: $name\ndescription: >-\n  useful skill\n  for writing\n---\nInstructions\n';

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

ResponseBody _giteeResponse(
  RequestOptions options,
  Map<String, String> files, {
  String branch = 'main',
}) {
  ResponseBody json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
  if (options.uri.path.contains('/commits/')) {
    return json({
      'sha': _sha,
    }, options.uri.pathSegments.last == branch ? 200 : 404);
  }
  if (options.uri.path.contains('/git/trees/')) {
    return json({
      'truncated': false,
      'tree': [
        for (final (index, entry) in files.entries.indexed)
          {
            'path': entry.key,
            'mode': '100644',
            'type': 'blob',
            'sha': (index + 1).toString().padLeft(40, '0'),
            'size': utf8.encode(entry.value).length,
          },
      ],
    });
  }
  if (options.uri.path.contains('/git/blobs/')) {
    final index = int.parse(options.uri.pathSegments.last) - 1;
    return json({
      'encoding': 'base64',
      'content': base64.encode(utf8.encode(files.values.elementAt(index))),
    });
  }
  if (options.uri.path == '/api/v5/repos/a/b') {
    return json({'default_branch': branch});
  }
  throw StateError('Unexpected Gitee endpoint: ${options.uri}');
}

void main() {
  late Dio client;
  late List<Uri> requests;
  late CancelToken token;
  setUp(() {
    requests = [];
    token = CancelToken();
    client = Dio();
  });
  tearDown(() => client.close(force: true));

  void respond(ResponseBody Function(RequestOptions) response) {
    client.httpClientAdapter = _Adapter((options) {
      requests.add(options.uri);
      return response(options);
    });
  }

  Future<List<AgentSkillImportCandidate>> scan(
    String url, {
    Set<String> existing = const {},
    Future<Dio> Function()? openPackageClient,
  }) => AgentSkillImportOrchestrator().discover(
    source: AgentSkillImportSource.parse(url),
    existingNames: existing,
    client: client,
    cancelToken: token,
    openPackageClient: openPackageClient,
  );

  Future<Directory> materialize(AgentSkillImportCandidate candidate) async {
    final destination = await Directory.systemTemp.createTemp(
      'skill_repository_',
    );
    addTearDown(() => destination.delete(recursive: true));
    await candidate.materialize!(destination);
    return destination;
  }

  Future<String> readPackageFile(Directory package, String path) =>
      File(p.joinAll([package.path, ...path.split('/')])).readAsString();

  test(
    'repository imports nested skills and references, marks conflicts',
    () async {
      final bytes = _zip({
        'repo/skills/a/SKILL.md': _skill('a'),
        'repo/skills/a/references/中文.txt': '参考',
        'repo/skills/a/scripts/run.py': 'print(1)',
        'repo/skills/a/run.sh': 'printf ready',
        'repo/skills/a/lib/nested/schema.dat': 'schema',
        'repo/skills/a/references/table.bin': 'binary fixture',
        'repo/skills/a/lib/.private': 'ignored',
        'repo/skills/a/scripts/node_modules/ignored.js': 'ignored',
        'repo/skills/a/scripts/__pycache__/ignored.pyc': 'ignored',
        'repo/skills/a/assets/__MACOSX/ignored': 'ignored',
        'repo/skills/b/SKILL.md': _skill('b'),
        'repo/.agents/skills/c/SKILL.md': _skill('c'),
        'repo/node_modules/ignored/SKILL.md': _skill('ignored'),
        'repo/../escaped/SKILL.md': _skill('escaped'),
      });
      respond((_) => ResponseBody.fromBytes(bytes, 200));
      final result = await scan('https://github.com/a/b', existing: {'a'});
      expect(result.map((c) => c.name), ['c', 'a', 'b']);
      final a = result.singleWhere((c) => c.name == 'a');
      expect(a.nameConflict, isTrue);
      expect(a.hasScripts, isTrue);
      final package = await materialize(a);
      expect(await readPackageFile(package, 'references/中文.txt'), '参考');
      expect(await readPackageFile(package, 'scripts/run.py'), 'print(1)');
      expect(await readPackageFile(package, 'run.sh'), 'printf ready');
      expect(await readPackageFile(package, 'lib/nested/schema.dat'), 'schema');
      expect(
        await readPackageFile(package, 'references/table.bin'),
        'binary fixture',
      );
      expect(
        await File(p.join(package.path, 'lib', '.private')).exists(),
        isFalse,
      );
      for (final name in [
        'scripts/node_modules',
        'scripts/__pycache__',
        'assets/__MACOSX',
      ]) {
        expect(
          await Directory(
            p.joinAll([package.path, ...name.split('/')]),
          ).exists(),
          isFalse,
        );
      }
      expect(result.singleWhere((c) => c.name == 'b').hasScripts, isFalse);
      expect(a.description, 'useful skill for writing');
      expect(requests.single.path, '/repos/a/b/zipball');
    },
  );

  for (final host in ['github', 'gitlab', 'gitee', 'gitcode']) {
    test(
      '$host resolves slash branch and limits selection to subdirectory',
      () async {
        final bytes = _zip({
          'repo/skills/a/SKILL.md': _skill('a'),
          'repo/skills/b/SKILL.md': _skill('b'),
        });
        respond((options) {
          if (host == 'gitee') {
            return _giteeResponse(options, {
              'skills/a/SKILL.md': _skill('a'),
              'skills/b/SKILL.md': _skill('b'),
            }, branch: 'feature/topic');
          }
          if (options.uri.path.contains('/commits/')) {
            return ResponseBody.fromString(
              jsonEncode({
                host == 'github' || host == 'gitee' ? 'sha' : 'id': _sha,
              }),
              options.uri.pathSegments.last == 'feature/topic' ? 200 : 404,
              headers: {
                Headers.contentTypeHeader: ['application/json'],
              },
            );
          }
          return ResponseBody.fromBytes(bytes, 200);
        });
        final url = host == 'gitlab'
            ? 'https://gitlab.com/a/sub/b/-/tree/feature/topic/skills/a'
            : 'https://$host.com/a/b/tree/feature/topic/skills/a';
        final result = await scan(url);
        expect(result.map((c) => c.name), ['a']);
        if (host == 'github') {
          expect(requests.last.pathSegments.last, _sha);
        } else if (host == 'gitlab') {
          expect(requests.last.queryParameters['sha'], _sha);
          expect(requests.last.pathSegments[3], 'a/sub/b');
        } else if (host == 'gitee') {
          expect(
            requests.any((uri) => uri.path.contains('/git/trees/$_sha')),
            isTrue,
          );
          expect(requests.last.path, contains('/git/blobs/'));
        } else {
          expect(requests.last.pathSegments.last, '$_sha.zip');
          expect(
            requests.last.host,
            host == 'gitee' ? 'gitee.com' : 'raw.gitcode.com',
          );
        }
      },
    );
  }

  for (final path in [
    'tree/main/skills/fight-director',
    'blob/main/skills/fight-director/SKILL.md',
    'tree/feature/topic/skills/fight-director',
  ]) {
    test('GitHub resolves missing commit 422 for $path', () async {
      final branch = path.contains('feature/topic') ? 'feature/topic' : 'main';
      respond((options) {
        if (options.uri.path.contains('/commits/')) {
          final ref = options.uri.pathSegments.last;
          return ResponseBody.fromString(
            jsonEncode(
              ref == branch
                  ? {'sha': _sha}
                  : {'message': 'No commit found for SHA: $ref'},
            ),
            ref == branch ? 200 : 422,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        }
        return ResponseBody.fromBytes(
          _zip({
            'repo/skills/fight-director/SKILL.md': _skill('fight-director'),
            'repo/skills/fight-director/references/guide.md': 'guide',
            'repo/skills/other/SKILL.md': _skill('other'),
          }),
          200,
        );
      });
      final result = await scan('https://github.com/a/b/$path');
      expect(result.single.name, 'fight-director');
      expect(
        await readPackageFile(
          await materialize(result.single),
          'references/guide.md',
        ),
        'guide',
      );
      expect(requests.last.pathSegments.last, _sha);
      expect(requests[requests.length - 2].pathSegments.last, branch);
    });
  }

  test(
    'GitHub missing commit 422 never downloads the default branch',
    () async {
      respond(
        (options) => ResponseBody.fromString(
          jsonEncode({
            'message':
                'No commit found for SHA: ${options.uri.pathSegments.last}',
          }),
          422,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await expectLater(
        scan('https://github.com/a/b/tree/missing/skills'),
        throwsA(isA<AgentSkillImportUnavailableException>()),
      );
      expect(requests.map((uri) => uri.pathSegments.last), [
        'missing/skills',
        'missing',
      ]);
    },
  );

  for (final host in ['github.com', 'gitee.com']) {
    test('$host preserves unrelated 422 errors without retrying', () async {
      respond(
        (options) => ResponseBody.fromString(
          jsonEncode({
            'message': host == 'github.com'
                ? 'Validation failed'
                : 'No commit found for SHA: ${options.uri.pathSegments.last}',
          }),
          422,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await expectLater(
        scan('https://$host/a/b/tree/main/skills'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            422,
          ),
        ),
      );
      expect(requests, hasLength(1));
    });
  }

  test(
    'Gitee root fetches default branch instead of assuming main/master',
    () async {
      respond(
        (options) => _giteeResponse(options, {
          'SKILL.md': _skill('gitee'),
          'references/guide.md': 'guide',
          'scripts/run.py': 'script',
        }, branch: 'release/topic'),
      );
      final result = await scan('https://gitee.com/a/b', existing: {'gitee'});
      expect(result.single.name, 'gitee');
      expect(result.single.nameConflict, isTrue);
      expect(
        requests.where((uri) => uri.path.contains('/git/blobs/')).length,
        1,
      );
      final package = await materialize(result.single);
      expect(await readPackageFile(package, 'references/guide.md'), 'guide');
      expect(await readPackageFile(package, 'scripts/run.py'), 'script');
      expect(
        requests
            .singleWhere((uri) => uri.path.contains('/git/trees/'))
            .pathSegments
            .last,
        'release/topic',
      );
      expect(
        requests.where((uri) => uri.path.contains('/git/blobs/')).length,
        3,
      );
    },
  );

  test(
    'Gitee truncated trees fail rather than silently losing skills',
    () async {
      respond(
        (options) => options.uri.path.contains('/git/trees/')
            ? ResponseBody.fromString(
                jsonEncode({'truncated': true, 'tree': []}),
                200,
                headers: {
                  Headers.contentTypeHeader: ['application/json'],
                },
              )
            : _giteeResponse(options, {}),
      );
      await expectLater(
        scan('https://gitee.com/a/b'),
        throwsA(isA<AgentSkillImportLimitException>()),
      );
    },
  );

  test('Gitee oversized reference fails before fetching its content', () async {
    respond(
      (options) => _giteeResponse(options, {
        'SKILL.md': _skill('gitee'),
        'references/guide.md': 'a' * (64 * 1024 + 1),
      }),
    );
    await expectLater(
      materialize((await scan('https://gitee.com/a/b')).single),
      throwsA(isA<AgentSkillImportLimitException>()),
    );
    expect(requests.where((uri) => uri.path.contains('/git/blobs/')).length, 1);
  });

  test('missing default branch fails without trying another branch', () async {
    respond(
      (_) => ResponseBody.fromString(
        '{}',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    await expectLater(scan('https://gitee.com/a/b'), throwsFormatException);
    expect(requests.length, 1);
  });

  test(
    'GitCode root downloads HEAD without authenticated API or credentials',
    () async {
      respond((options) {
        expect(
          options.headers.keys.any(
            (key) =>
                key.toLowerCase() == 'authorization' ||
                key.toLowerCase() == 'cookie',
          ),
          isFalse,
        );
        expect(options.queryParameters, isEmpty);
        return ResponseBody.fromBytes(
          _zip({'repo/SKILL.md': _skill('gitcode')}),
          200,
        );
      });
      expect((await scan('https://gitcode.com/a/b')).single.name, 'gitcode');
      expect(
        requests.single.toString(),
        'https://raw.gitcode.com/a/b/archive/refs/heads/HEAD.zip',
      );
    },
  );

  for (final host in ['github', 'gitee', 'gitcode']) {
    test(
      '$host SKILL.md link includes adjacent references but no nested skills',
      () async {
        final bytes = _zip({
          'repo/a/SKILL.md': _skill('a'),
          'repo/a/references/guide.md': 'guide',
          'repo/a/nested/SKILL.md': _skill('nested'),
        });
        respond(
          (options) => host == 'gitee'
              ? _giteeResponse(options, {
                  'a/SKILL.md': _skill('a'),
                  'a/references/guide.md': 'guide',
                  'a/nested/SKILL.md': _skill('nested'),
                })
              : options.uri.path.contains('/commits/')
              ? ResponseBody.fromString(
                  jsonEncode({host == 'gitcode' ? 'id' : 'sha': _sha}),
                  options.uri.pathSegments.last == 'main' ? 200 : 404,
                  headers: {
                    Headers.contentTypeHeader: ['application/json'],
                  },
                )
              : ResponseBody.fromBytes(bytes, 200),
        );
        final result = await scan('https://$host.com/a/b/blob/main/a/SKILL.md');
        expect(result.single.name, 'a');
        expect(
          await readPackageFile(
            await materialize(result.single),
            'references/guide.md',
          ),
          'guide',
        );
      },
    );
  }

  test('empty repository remains an empty scan', () async {
    respond(
      (_) => ResponseBody.fromBytes(_zip({'repo/README.md': 'readme'}), 200),
    );
    expect(await scan('a/b'), isEmpty);
  });

  test('missing revision does not download the default branch', () async {
    respond((_) => ResponseBody.fromString('{}', 404));
    await expectLater(
      scan('https://github.com/a/b/tree/missing/skills'),
      throwsA(isA<AgentSkillImportUnavailableException>()),
    );
    expect(requests.every((uri) => uri.path.contains('/commits/')), isTrue);
  });

  test(
    'HTML download is rejected rather than shown as an empty repository',
    () async {
      respond(
        (_) => ResponseBody.fromString('<html>Login required</html>', 200),
      );
      await expectLater(scan('a/b'), throwsFormatException);
    },
  );

  test('stream without content length is still size limited', () async {
    respond(
      (_) => ResponseBody(
        Stream<Uint8List>.fromIterable([
          Uint8List(AgentSkillImportOrchestrator.maxDownloadBytes),
          Uint8List(1),
        ]),
        200,
      ),
    );
    await expectLater(
      scan('a/b'),
      throwsA(isA<AgentSkillImportLimitException>()),
    );
    expect(token.isCancelled, isTrue);
  });

  test(
    'invalid skill fails rather than silently importing incomplete data',
    () async {
      respond(
        (_) =>
            ResponseBody.fromBytes(_zip({'repo/SKILL.md': 'not a skill'}), 200),
      );
      await expectLater(scan('a/b'), throwsFormatException);
    },
  );

  test('oversized archive is rejected before reading body', () async {
    respond(
      (_) => ResponseBody.fromBytes(
        [],
        200,
        headers: {
          Headers.contentLengthHeader: [
            '${AgentSkillImportOrchestrator.maxDownloadBytes + 1}',
          ],
        },
      ),
    );
    await expectLater(
      scan('a/b'),
      throwsA(isA<AgentSkillImportLimitException>()),
    );
    expect(token.isCancelled, isTrue);
  });

  test('oversized references fail visibly instead of being dropped', () async {
    respond(
      (_) => ResponseBody.fromBytes(
        _zip({
          'repo/SKILL.md': _skill('a'),
          'repo/references/large.md': 'a' * (64 * 1024 + 1),
        }),
        200,
      ),
    );
    await expectLater(
      materialize((await scan('a/b')).single),
      throwsA(isA<AgentSkillImportLimitException>()),
    );
  });

  test('Gitee detects scripts without importing or executing them', () async {
    respond(
      (options) => _giteeResponse(options, {
        'skills/a/SKILL.md': _skill('a'),
        'skills/a/scripts/run.py': 'raise RuntimeError()',
        'skills/a/references/guide.md': 'guide',
      }),
    );
    final candidates = await scan('https://gitee.com/a/b/tree/main/skills/a');
    expect(candidates.single.hasScripts, isTrue);
    expect(requests.where((uri) => uri.path.contains('/git/blobs/')).length, 1);
  });

  test(
    'Gitee selected packages can be read after the scan client closes',
    () async {
      final resources = {
        'SKILL.md': _skill('gitee'),
        'lib/nested/fixture.bin': 'abc' * (60 * 1024),
      };
      respond((options) => _giteeResponse(options, resources));
      final openedClients = <Dio>[];
      final candidates = await scan(
        'https://gitee.com/a/b',
        openPackageClient: () async {
          final reopened = Dio()
            ..httpClientAdapter = _Adapter(
              (options) => _giteeResponse(options, resources),
            );
          openedClients.add(reopened);
          return reopened;
        },
      );
      expect(openedClients, isEmpty);
      client.close(force: true);
      final package = await materialize(candidates.single);
      expect(openedClients, hasLength(1));
      expect(
        await readPackageFile(package, 'lib/nested/fixture.bin'),
        resources['lib/nested/fixture.bin'],
      );
    },
  );

  test('HTTP failure preserves status for the caller', () async {
    respond((_) => ResponseBody.fromString('not found', 404));
    await expectLater(
      scan('a/b'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          404,
        ),
      ),
    );
  });

  test('cancelled operation never starts a download', () async {
    respond((_) => throw StateError('must not request'));
    token.cancel('closed');
    await expectLater(
      scan('a/b'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(requests, isEmpty);
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.response);
  final ResponseBody Function(RequestOptions) response;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => response(options);

  @override
  void close({bool force = false}) {}
}
