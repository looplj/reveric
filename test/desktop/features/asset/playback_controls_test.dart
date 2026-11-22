// 职责: 验证媒体播放结束时的进度显示及重新定位后的状态恢复。
// 关联文件:
//   lib/desktop/features/asset/playback_controls.dart
//   test/desktop/director/harness.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:reveric/desktop/features/asset/playback_controls.dart';

import '../../director/harness.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(initializeDirectorTest);

  testWidgets('completion fills progress without rounding an ordinary pause', (
    tester,
  ) async {
    final player = _Player();
    await tester.pumpWidget(directorTestApp(PlaybackControls(player: player)));
    await tester.pumpAndSettle();
    expect(find.text('0:04 / 0:05'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 4958);

    player.complete();
    await tester.pumpAndSettle();
    expect(find.text('0:05 / 0:05'), findsOneWidget);
    final end = tester.widget<Slider>(find.byType(Slider));
    expect(end.value, end.max);

    await tester.tap(find.byType(Slider));
    await tester.pumpAndSettle();
    expect(find.text('0:02 / 0:05'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, closeTo(2500, 1));
    expect(player.value.isPlaying, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await player.dispose();
  });
}

class _Player extends VideoPlayerController {
  _Player() : super.file(File('unused.mp4')) {
    value = const VideoPlayerValue(
      duration: Duration(seconds: 5),
      position: Duration(milliseconds: 4958),
      isInitialized: true,
    );
  }

  void complete() {
    value = value.copyWith(isCompleted: true);
  }

  @override
  Future<void> seekTo(Duration position) async {
    value = value.copyWith(isCompleted: false, position: position);
  }
}
