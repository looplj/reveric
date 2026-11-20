// 职责: 验证移动端文档目录按当前文件夹列出子项，而不是把整棵树摊平。
// 关联文件:
//   lib/mobile/widgets/document_folder_browser.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/en/common.json
//   assets/translations/en/mobile.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/pages/entry_editor_page.dart';
import 'package:reveric/mobile/widgets/document_folder_browser.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  test('documentsInFolder lists only the current folder children', () {
    final documents = <Document>[
      _document(id: 'root', title: 'Imported folder', isFolder: true),
      _document(
        id: 'nested',
        title: 'Nested folder',
        parentId: 'root',
        isFolder: true,
      ),
      _document(id: 'root-file', title: 'Root file', parentId: 'root'),
      _document(id: 'child-file', title: 'Child file', parentId: 'nested'),
      _document(id: 'orphan', title: 'Orphan file', parentId: 'missing'),
    ];

    expect(
      documentsInFolder(
        documents: documents,
        folderId: null,
      ).map((document) => document.id),
      ['root', 'orphan'],
    );
    expect(
      documentsInFolder(
        documents: documents,
        folderId: 'root',
      ).map((document) => document.id),
      ['nested', 'root-file'],
    );
    expect(
      documentsInFolder(
        documents: documents,
        folderId: 'nested',
      ).map((document) => document.id),
      ['child-file'],
    );
  });

  test('documentFolderBreadcrumb walks from root to the current folder', () {
    final documents = <Document>[
      _document(id: 'root', title: 'Imported folder', isFolder: true),
      _document(
        id: 'nested',
        title: 'Nested folder',
        parentId: 'root',
        isFolder: true,
      ),
    ];

    expect(
      documentFolderBreadcrumb(documents: documents, folderId: null),
      isEmpty,
    );
    expect(
      documentFolderBreadcrumb(
        documents: documents,
        folderId: 'nested',
      ).map((document) => document.id),
      ['root', 'nested'],
    );
  });

  test('resolvedDocumentFolderId returns to root when the folder is gone', () {
    final documents = <Document>[
      _document(id: 'root', title: 'Imported folder', isFolder: true),
    ];

    expect(
      resolvedDocumentFolderId(documents: documents, folderId: 'root'),
      'root',
    );
    expect(
      resolvedDocumentFolderId(documents: documents, folderId: 'missing'),
      isNull,
    );
    expect(
      resolvedDocumentFolderId(documents: documents, folderId: null),
      isNull,
    );
  });

  testWidgets(
    'drills into a folder and can start a new folder in the current directory',
    (tester) async {
      final documents = <Document>[
        _document(id: 'root', title: 'Imported folder', isFolder: true),
        _document(
          id: 'nested',
          title: 'Nested folder',
          parentId: 'root',
          isFolder: true,
        ),
        _document(id: 'root-file', title: 'Root file', parentId: 'root'),
        _document(id: 'child-file', title: 'Child file', parentId: 'nested'),
        _document(id: 'orphan', title: 'Orphan file', parentId: 'missing'),
      ];

      await tester.pumpWidget(
        _wrap(
          ProviderScope(
            overrides: [
              documentsProvider(
                path: 'test.db',
                type: documentTypeLore,
              ).overrideWith((ref) => Stream.value(documents)),
            ],
            child: const MobileDocumentFolderBrowser(
              novelId: 'work',
              databasePath: 'test.db',
              section: MobileEditorSection.lore,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Imported folder'), findsOneWidget);
      expect(find.text('Orphan file'), findsOneWidget);
      expect(find.text('Root file'), findsNothing);
      expect(find.text('Child file'), findsNothing);
      expect(find.text('Root directory'), findsNothing);

      await tester.tap(find.text('Imported folder'));
      await tester.pumpAndSettle();

      expect(find.text('Root directory'), findsOneWidget);
      expect(find.text('Nested folder'), findsOneWidget);
      expect(find.text('Root file'), findsOneWidget);
      expect(find.text('Child file'), findsNothing);
      expect(find.text('Orphan file'), findsNothing);

      await tester.tap(find.text('Nested folder'));
      await tester.pumpAndSettle();

      expect(find.text('Child file'), findsOneWidget);
      expect(find.text('Root file'), findsNothing);

      await tester.tap(find.text('Root directory'));
      await tester.pumpAndSettle();

      expect(find.text('Imported folder'), findsOneWidget);
      expect(find.text('Orphan file'), findsOneWidget);
      expect(find.text('Child file'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _wrap(
          ProviderScope(
            overrides: [
              documentsProvider(
                path: 'empty.db',
                type: documentTypeLore,
              ).overrideWith((ref) => Stream.value(const <Document>[])),
            ],
            child: const MobileDocumentFolderBrowser(
              novelId: 'work',
              databasePath: 'empty.db',
              section: MobileEditorSection.lore,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.text(tr(LocaleKeys.workspaceNewWorldbuilding)),
        findsOneWidget,
      );

      await tester.tap(find.text(tr(LocaleKeys.workspaceNewWorldbuilding)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text(tr(LocaleKeys.workspaceAddDocumentOrFolder)),
        findsOneWidget,
      );
      expect(find.text(tr(LocaleKeys.workspaceNewFolder)), findsOneWidget);

      await tester.tap(find.text(tr(LocaleKeys.workspaceNewFolder)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(tr(LocaleKeys.workspaceNewFolderHint)), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

Widget _wrap(Widget child) {
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) {
        return MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          builder: (_, routeChild) =>
              RevericTheme(data: RevericThemeData.reveric, child: routeChild!),
          home: Scaffold(body: child),
        );
      },
    ),
  );
}

Document _document({
  required String id,
  required String title,
  String? parentId,
  bool isFolder = false,
}) {
  final now = DateTime(2026);
  return Document(
    id: id,
    type: 'lore',
    title: title,
    content: '',
    status: 'active',
    category: '',
    tags: '',
    parentId: parentId,
    isFolder: isFolder,
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
    deletedAt: now,
  );
}
