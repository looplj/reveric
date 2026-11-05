// 职责: 移动端底部 Tab 当前选中项的全局状态 — 供页面内跳转其它 Tab。
// 关联文件:
//   lib/mobile/app.dart
//   lib/mobile/widgets/tab_bar.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 底部 Tab 索引常量（与 [MobileApp] 的 PageView 顺序一致）。
abstract final class MobileTab {
  static const novels = 0;
  static const screenplays = 1;
  static const assistant = 2;
  static const settings = 3;
}

class _MobileTabIndexNotifier extends Notifier<int> {
  @override
  int build() => MobileTab.novels;

  void set(int index) => state = index;
}

/// 当前底部 Tab 索引。页面内可 `ref.read(mobileTabIndexProvider.notifier).set(...)` 切换。
final mobileTabIndexProvider = NotifierProvider<_MobileTabIndexNotifier, int>(
  _MobileTabIndexNotifier.new,
);
