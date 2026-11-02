// 职责: 验证未设置头像图片时，默认头像按昵称显示首字。
// 关联文件:
//   lib/shared/widgets/user_avatar.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/user_avatar.dart';

Widget _wrap(String username) {
  return MaterialApp(
    theme: RevericThemeData.reveric.toThemeData(),
    home: RevericTheme(
      data: RevericThemeData.reveric,
      child: Scaffold(
        body: UserAvatar(username: username, imagePath: null, size: 32),
      ),
    ),
  );
}

void main() {
  testWidgets('shows the first character of a Chinese nickname', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap('远山行者'));
    expect(find.text('远'), findsOneWidget);
  });

  testWidgets('uppercases a Latin initial and ignores leading spaces', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap('  luna'));
    expect(find.text('L'), findsOneWidget);
  });

  testWidgets('falls back to the app name initial when nickname is blank', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(''));
    expect(find.text('R'), findsOneWidget);
  });
}
