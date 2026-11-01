// 职责: 验证管控文件的 glob 匹配、路径边界、冻结删除范围及失败后保留现场。
// 关联文件:
//   lib/shared/services/ai/files/management.dart
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/models/tool_permission.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:glob/glob.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/ai/files/management.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';

void main() {
  test(
    'absolute Windows selectors retain drive and UNC roots across platforms',
    () {
      for (final entry in {
        r'C:\media\*.txt': r'C:\media\visible.txt',
        r'\\server\share\media\*.txt': r'\\server\share\media\visible.txt',
      }.entries) {
        final pattern = ManagedFiles.portableAbsolute(entry.key);
        final candidate = ManagedFiles.portableAbsolute(entry.value);
        expect(pattern, isNot(contains(r'\')));
        expect(p.windows.isAbsolute(pattern), isTrue);
        expect(
          Glob(
            pattern,
            context: p.windows,
            caseSensitive: false,
          ).matches(ManagedFiles.nativeAbsolute(candidate)),
          isTrue,
        );
        expect(
          ManagedFiles.nativeAbsolute(candidate),
          p.windows.normalize(entry.value),
        );
      }
    },
  );

  late Directory support;
  late Directory root;
  late ManagedFiles files;
  Future<File> write(String path, [String text = 'data']) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    return file.writeAsString(text);
  }

  setUp(() async {
    support = await Directory.systemTemp.createTemp('managed-files-');
    support = Directory(await support.resolveSymbolicLinks());
    root = await Directory(
      '${support.path}/file_workspaces/work',
    ).create(recursive: true);
    files = ManagedFiles(
      SessionFiles(root: support.path, novelId: 'work'),
      'current',
    );
  });
  tearDown(() => support.delete(recursive: true));

  test(
    'stored references select the current-work attachment and protect the root',
    () async {
      await write('sessions/current/image.png');
      for (final path in [
        'file_workspaces/work/sessions/current/image.png',
        'file_workspaces/work/sessions/current/*.png',
      ]) {
        final selection = await files.select(path, remove: false);
        expect(selection.paths, ['sessions/current/image.png']);
      }
      final removal = await files.select(
        'file_workspaces/work/sessions/current/image.png',
        remove: true,
      );
      expect(removal.paths, ['sessions/current/image.png']);
      await removal.verify();
      await expectLater(
        files.select('file_workspaces/work', remove: true, recursive: true),
        throwsA(isA<ToolOperationException>()),
      );
      await expectLater(
        files.select(
          'file_workspaces/other/sessions/current/image.png',
          remove: false,
        ),
      throwsFormatException,
      );
      expect(
        await File('${root.path}/sessions/current/image.png').exists(),
        isTrue,
      );
    },
  );

  test(
    'lists direct children with stable pagination and file metadata',
    () async {
      await write('media/a.mp4', '123');
      await write('media/b.png');
      await write('media/nested/c.mp4');
      final selection = await files.select('media/', remove: false);
      final page = selection.listing(limit: 2);
      expect(page['total'], 3);
      expect(page['next_offset'], 2);
      expect((page['entries'] as List).map((e) => e['path']), [
        'media/a.mp4',
        'media/b.png',
      ]);
      expect(page['entries'][0]['bytes'], 3);
      final last = selection.listing(offset: 2);
      expect(last['entries'][0]['type'], 'directory');
      expect(last.containsKey('next_offset'), false);
    },
  );

  for (final entry in {
    'media/*.mp4': ['media/frame-01.mp4', 'media/frame-02.mp4'],
    'media/frame-0?.mp4': ['media/frame-01.mp4', 'media/frame-02.mp4'],
    'media/frame-0[12].mp4': ['media/frame-01.mp4', 'media/frame-02.mp4'],
    'media/*.{mp4,png}': [
      'media/frame-01.mp4',
      'media/frame-02.mp4',
      'media/still.png',
    ],
    'media/**/*.mp4': [
      'media/frame-01.mp4',
      'media/frame-02.mp4',
      'media/nested/deep.mp4',
    ],
  }.entries) {
    test('matches glob ${entry.key}', () async {
      for (final path in [
        'media/frame-01.mp4',
        'media/frame-02.mp4',
        'media/still.png',
        'media/nested/deep.mp4',
      ]) {
        await write(path);
      }
      expect((await files.select(entry.key, remove: false)).paths, entry.value);
    });
  }

  for (final path in [
    '',
    '../media/a.mp4',
    '/media/a.mp4',
    'media/../a.mp4',
    'media/{..,safe}/a.mp4',
    'media/./a.mp4',
    'media//a.mp4',
    r'C:\media\a.mp4',
    'C:/media/a.mp4',
    r'media\..\a.mp4',
    'media/a.mp4:stream',
    'file:///media/a.mp4',
    'media/\u0000',
  ]) {
    test('rejects unsafe selector $path before deleting anything', () async {
      final kept = await write('media/a.mp4');
      await expectLater(
        files.select(path, remove: true, recursive: true),
        throwsFormatException,
      );
      expect(await kept.exists(), true);
    });
  }

  test(
    'work globs include all local sessions but cannot select another work',
    () async {
      await write('sessions/current/own.mp4');
      await write('sessions/other/other.mp4');
      final outside = File('${support.path}/file_workspaces/other/keep.mp4');
      await outside.parent.create(recursive: true);
      await outside.writeAsString('keep');
      final listing = await files.select('.', remove: false, recursive: true);
      expect(
        listing.paths,
        containsAll(['sessions/current/own.mp4', 'sessions/other/other.mp4']),
      );
      expect(listing.paths, isNot(contains('keep.mp4')));
      final selection = await files.select('sessions/**/*.mp4', remove: true);
      expect(
        (await selection.remove(cancelled: () => false))['removed'],
        hasLength(2),
      );
      expect(await outside.readAsString(), 'keep');
      await expectLater(
        files.select('.', remove: true, recursive: true),
        throwsA(isA<ToolOperationException>()),
      );
    },
  );

  test(
    'absolute listing returns absolute paths, while removal rejects them',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'managed-external-',
      );
      addTearDown(() => outside.delete(recursive: true));
      final file = await File(
        '${outside.path}/visible.txt',
      ).writeAsString('data');
      final listing = await files.select(outside.path, remove: false);
      expect(listing.paths, [file.path]);
      expect((listing.listing()['entries'] as List).single['path'], file.path);
      await expectLater(
        files.select(outside.path, remove: true, recursive: true),
        throwsFormatException,
      );
      expect(await file.exists(), true);
    },
  );

  test(
    'absolute listings of the current work return reusable relative entries',
    () async {
      await write('files/local.txt');
      final listing = await files.select('${root.path}/files', remove: false);
      expect(
        (listing.listing()['entries'] as List).single['path'],
        'files/local.txt',
      );
      final again = await files.select('files/local.txt', remove: false);
      expect(again.listing()['entries'], listing.listing()['entries']);
    },
  );

  test('external-mode selectors cannot be reused for deletion', () async {
    final kept = await write('files/keep.txt');
    final external = ManagedFiles(
      SessionFiles(root: support.path, novelId: 'work'),
      'current',
      external: true,
    );
    for (final path in [kept.path, 'files/keep.txt']) {
      await expectLater(
        external.select(path, remove: true),
        throwsFormatException,
      );
    }
    expect(await kept.readAsString(), 'data');
  });

  test(
    'recursive glob listing and removal include a matched directory once',
    () async {
      await write('media/failed/sub/a.mp4');
      await write('media/failed/sub/b.mp4');
      final listed = await files.select(
        'media/fail*',
        remove: false,
        recursive: true,
      );
      expect(listed.paths, [
        'media/failed',
        'media/failed/sub',
        'media/failed/sub/a.mp4',
        'media/failed/sub/b.mp4',
      ]);
      final selection = await files.select(
        'media/**',
        remove: true,
        recursive: true,
      );
      expect((await selection.remove(cancelled: () => false))['ok'], true);
      expect(await Directory('${root.path}/media').exists(), true);
      expect(await Directory('${root.path}/media').list().isEmpty, true);
    },
  );

  test(
    'removes matched files only and reports a repeat as an empty match',
    () async {
      await write('videos/part-1.mp4');
      await write('videos/part-2.mp4');
      final kept = await write('videos/other.mp4');
      final selection = await files.select('videos/part-?.mp4', remove: true);
      final result = await selection.remove(cancelled: () => false);
      expect(result['ok'], true);
      expect(result['removed'], ['videos/part-1.mp4', 'videos/part-2.mp4']);
      expect(await kept.exists(), true);
      final repeat = await files.select('videos/part-?.mp4', remove: true);
      expect((await repeat.remove(cancelled: () => false))['removed'], isEmpty);
    },
  );

  test(
    'validates the whole match before refusing a directory without recursive',
    () async {
      final kept = await write('media/a.mp4');
      await write('media/folder/b.mp4');
      await expectLater(
        files.select('media/*', remove: true),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'failed_precondition',
          ),
        ),
      );
      expect(await kept.exists(), true);
    },
  );

  test(
    'recursive removal clears the selected directory but preserves siblings',
    () async {
      await write('media/failed/a.mp4');
      await write('media/failed/sub/b.mp4');
      final kept = await write('media/success/a.mp4');
      final selection = await files.select(
        'media/failed',
        remove: true,
        recursive: true,
      );
      final result = await selection.remove(cancelled: () => false);
      expect(result['ok'], true);
      expect(await Directory('${root.path}/media/failed').exists(), false);
      expect(await kept.exists(), true);
    },
  );

  test(
    'double-star removes matching files while retaining directories and other file types',
    () async {
      await write('media/a.mp4');
      await write('media/sub/b.mp4');
      final kept = await write('media/sub/c.txt');
      final selection = await files.select('media/**/*.mp4', remove: true);
      expect((await selection.remove(cancelled: () => false))['ok'], true);
      expect(await kept.exists(), true);
    },
  );

  for (final change in ['new match', 'changed file', 'missing file']) {
    test(
      'refuses a $change after approval without deleting other files',
      () async {
        final first = await write('media/a.mp4');
        final kept = await write('media/b.mp4');
        final selection = await files.select('media/*.mp4', remove: true);
        switch (change) {
          case 'new match':
            await write('media/c.mp4');
          case 'changed file':
            await first.writeAsString('changed content');
          case 'missing file':
            await first.delete();
        }
        await expectLater(
          selection.remove(cancelled: () => false),
          throwsA(
            isA<ToolOperationException>().having(
              (e) => e.code,
              'code',
              'conflict',
            ),
          ),
        );
        expect(await kept.exists(), true);
      },
    );
  }

  test(
    'folder counts group removal entries under the topmost selected folder',
    () async {
      await write('media/frames/s2/a.png');
      await write('media/frames/s2/deep/b.png');
      await write('media/frames/s3/c.png');
      await write('media/loose.png');
      await write('media/other/d.png');
      final folders = await files.select(
        'media/frames/s*',
        remove: true,
        recursive: true,
      );
      expect(folders.folderCounts, {
        'media/frames/s2': 4,
        'media/frames/s3': 2,
      });
      final loose = await files.select('media/**/*.png', remove: true);
      expect(loose.folderCounts, {
        'media': 1,
        'media/frames/s2': 1,
        'media/frames/s2/deep': 1,
        'media/frames/s3': 1,
        'media/other': 1,
      });
    },
  );

  test('cancellation reports precisely which files were removed', () async {
    await write('media/a.mp4');
    final kept = await write('media/b.mp4');
    final selection = await files.select('media/*.mp4', remove: true);
    var checks = 0;
    final result = await selection.remove(cancelled: () => ++checks > 1);
    expect(result['ok'], false);
    expect(result['cancelled'], true);
    expect(result['removed'], ['media/a.mp4']);
    expect(result['remaining'], ['media/b.mp4']);
    expect(await kept.exists(), true);
  });

  test(
    'new files created during removal are never recursively deleted',
    () async {
      await write('media/failed/a.mp4');
      final selection = await files.select(
        'media/failed',
        remove: true,
        recursive: true,
      );
      var checks = 0;
      final newFile = File('${root.path}/media/failed/new.mp4');
      final result = await selection.remove(
        cancelled: () {
          if (++checks == 2) {
            newFile.writeAsStringSync('created after approval');
          }
          return false;
        },
      );
      expect(result['ok'], false);
      expect(result['removed'], ['media/failed/a.mp4']);
      expect(await newFile.exists(), true);
    },
  );

  test(
    'symbolic link targets and their parents cannot escape managed storage',
    () async {
      final outside = await Directory.systemTemp.createTemp('managed-outside-');
      addTearDown(() => outside.delete(recursive: true));
      final protected = await File(
        '${outside.path}/keep.txt',
      ).writeAsString('outside');
      await write('media/kept.txt');
      await Link('${root.path}/media/link').create(outside.path);
      for (final path in [
        'media/link',
        'media/link/keep.txt',
        'media/link/*',
        'media/*',
      ]) {
        await expectLater(
          files.select(path, remove: true, recursive: true),
          throwsA(isA<ToolOperationException>()),
        );
      }
      expect(await protected.readAsString(), 'outside');
      expect(await File('${root.path}/media/kept.txt').exists(), true);
    },
    skip: Platform.isWindows
        ? 'Creating Windows symlinks requires host privileges.'
        : false,
  );
  test(
    'external listing freezes the resolved target before approval',
    () async {
      final first = await Directory('${support.path}/first').create();
      final second = await Directory('${support.path}/second').create();
      await File('${first.path}/visible.txt').writeAsString('first');
      await File('${second.path}/private.txt').writeAsString('second');
      final link = await Link('${support.path}/alias').create(first.path);
      final verify = await files.freezeExternal(link.path);
      await link.delete();
      await link.create(second.path);
      await expectLater(
        verify(),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );
    },
    skip: Platform.isWindows ? 'Windows links require host privileges.' : false,
  );
}
