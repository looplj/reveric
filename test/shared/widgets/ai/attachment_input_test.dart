// 职责: 验证聊天文件选择、桌面拖放和剪贴板的输入行为。
// 关联文件:
//   lib/shared/widgets/ai/chat/attachment_input.dart
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// Use file_selector's locked platform test interface.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/widgets/ai/chat/attachment_input.dart';
import 'package:reveric/shared/widgets/ai/chat/composer_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_clipboard/super_clipboard.dart' as clip;

class _PlainTextReader implements clip.DataReader {
  @override
  bool canProvide(clip.DataFormat format) =>
      format == clip.Formats.plainText || format == clip.Formats.plainTextFile;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Ordinary text must not be requested as a file');
}

class _FileUriReader implements clip.DataReader {
  _FileUriReader(this.uri);
  final Uri uri;

  @override
  bool canProvide(clip.DataFormat format) => format == clip.Formats.fileUri;

  @override
  clip.ReadProgress getValue<T extends Object>(
    clip.ValueFormat<T> format,
    clip.AsyncValueChanged<T?> onValue, {
    ValueChanged<Object>? onError,
  }) {
    expect(format, clip.Formats.fileUri);
    onValue(uri as T);
    return _Progress();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('A file reference must not request file contents');
}

class _Progress implements clip.ReadProgress {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FileSelector extends FileSelectorPlatform {
  List<XTypeGroup>? filters;
  final videoPath = p.absolute('素材 01.mp4');

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    filters = acceptedTypeGroups;
    return [
      if (acceptedTypeGroups!.isEmpty) XFile(videoPath),
      XFile(p.absolute('reference.png')),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  test('shared text/plain format remains text when pasting', () async {
    expect(
      await readChatAttachmentData(_PlainTextReader(), allowTextFile: false),
      isNull,
    );
  });

  test(
    'desktop drop keeps the original file URI path without reading bytes',
    () async {
      final dir = await Directory.systemTemp.createTemp('chat-drop-');
      addTearDown(() => dir.delete(recursive: true));
      final video = await File(p.join(dir.path, '素材 01#.mp4')).create();

      final file = await readChatAttachmentData(
        _FileUriReader(video.uri),
        useLocalFilePath: true,
      );
      final controller = ChatComposerController();
      addTearDown(controller.dispose);
      controller.insertFiles([file!], allowPathReferences: true);

      controller.insertText('Extract the first frame');
      expect(controller.text, '${video.path}\nExtract the first frame');
      expect(controller.snapshot().attachments, isEmpty);
    },
  );

  testWidgets(
    'only desktop pickers offer file paths alongside attachments',
    (tester) async {
      final controller = ChatComposerController();
      addTearDown(controller.dispose);
      final original = FileSelectorPlatform.instance;
      final picker = _FileSelector();
      FileSelectorPlatform.instance = picker;
      addTearDown(() => FileSelectorPlatform.instance = original);
      final desktop = defaultTargetPlatform != TargetPlatform.android;
      final action = GlobalKey();
      await tester.pumpWidget(
        EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Scaffold(body: SizedBox(key: action)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await pickChatAttachments(action.currentContext!, controller);

      final draft = controller.snapshot();
      expect(draft.attachments.values.single.name, 'reference.png');
      expect(
        controller.readableText(draft),
        desktop ? '${picker.videoPath}\nImage #1\n' : 'Image #1',
      );
      if (desktop) {
        expect(picker.filters, isEmpty);
      } else {
        expect(picker.filters!.single.extensions, containsAll(['png', 'txt']));
        expect(picker.filters!.single.extensions, isNot(contains('mp4')));
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
