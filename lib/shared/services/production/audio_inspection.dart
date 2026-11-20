// 职责: 统计局部立体声 PCM 的分窗电平与低电平区间。
// 关联文件:
//   lib/shared/services/editing/render_service.dart
//   lib/shared/services/ai/ffmpeg/command.dart
import 'dart:math' as math;
import 'dart:typed_data';

const audioInspectionMaxSeconds = 10;

/// Input is interleaved stereo float32 little-endian, as emitted by the mixer.
class InspectionAudio {
  InspectionAudio(Uint8List pcm) : data = ByteData.sublistView(pcm) {
    if (pcm.isEmpty || pcm.length % 8 != 0) {
      throw const FormatException('Incomplete stereo audio.');
    }
  }
  final ByteData data;
  int get samples => data.lengthInBytes ~/ 8;

  Map<String, dynamic> levels({
    required int origin,
    required int samplesPerUnit,
    required int window,
    required String unit,
  }) {
    final windows = <Map<String, dynamic>>[];
    final quiet = <Map<String, dynamic>>[];
    for (var start = 0; start < samples; start += window * samplesPerUnit) {
      final end = math.min(start + window * samplesPerUnit, samples);
      double peak = 0, squares = 0;
      for (var channel = start * 2; channel < end * 2; channel++) {
        final value = data.getFloat32(channel * 4, Endian.little);
        if (!value.isFinite) {
          throw const FormatException('Non-finite audio sample.');
        }
        peak = math.max(peak, value.abs());
        squares += value * value;
      }
      final first = origin + start ~/ samplesPerUnit;
      final last = origin + (end / samplesPerUnit).ceil();
      windows.add({
        'start_$unit': first,
        'end_$unit': last,
        'peak_dbfs': _db(peak),
        'rms_dbfs': _db(math.sqrt(squares / ((end - start) * 2))),
      });
      if (peak <= .001) {
        if (quiet.isNotEmpty && quiet.last['end_$unit'] == first) {
          quiet.last['end_$unit'] = last;
        } else {
          quiet.add({'start_$unit': first, 'end_$unit': last});
        }
      }
    }
    return {
      'windows': windows,
      'silence_peak_dbfs': -60,
      'silence_ranges': quiet,
    };
  }

  static double? _db(double amplitude) => amplitude == 0
      ? null
      : (200 * math.log(amplitude) / math.ln10).round() / 10;
}
