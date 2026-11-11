// 职责: 无损解析片段提示词中的独立资源标签并校验引用身份是否有效。
// 关联文件:
//   lib/shared/services/ai/xml_utils.dart
//   lib/shared/services/storyboard/service.dart
import '../../services/ai/xml_utils.dart';

class PromptPart {
  const PromptPart.text(this.text) : inputId = null, label = null;
  const PromptPart.reference(this.text, this.inputId, this.label);
  final String text;
  final String? inputId;
  String get identity => inputId!;
  final String? label;
  bool get isReference => inputId != null;
}

class StoryboardPrompt {
  StoryboardPrompt._(this.parts);
  final List<PromptPart> parts;
  String get source => parts.map((p) => p.text).join();
  String get plainText => parts.map((p) => p.label ?? p.text).join();
  Iterable<PromptPart> get references => parts.where((p) => p.isReference);

  static final _start = RegExp(r'<\s*/?\s*ref\b', caseSensitive: false);
  static final _tag = RegExp(r'''<ref\s+((?:[^<>"']|"[^"]*"|'[^']*')*)/\s*>''');
  static final _attribute = RegExp(
    r'''\s*([a-z_]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
  );

  factory StoryboardPrompt.parse(String text) {
    final parts = <PromptPart>[];
    var cursor = 0;
    for (final start in _start.allMatches(text)) {
      if (start.start < cursor) {
        continue;
      }
      if (start.start > cursor) {
        parts.add(PromptPart.text(text.substring(cursor, start.start)));
      }
      final tag = _tag.matchAsPrefix(text, start.start);
      if (tag == null) {
        throw const FormatException(
          'Invalid ref tag; use a self-closing ref with input_id, and label.',
        );
      }
      final attributes = <String, String>{};
      final body = tag.group(1)!;
      var position = 0;
      while (position < body.length &&
          body.substring(position).trim().isNotEmpty) {
        final attribute = _attribute.matchAsPrefix(body, position);
        if (attribute == null || attributes.containsKey(attribute.group(1))) {
          throw const FormatException('Invalid or duplicate ref attribute.');
        }
        attributes[attribute.group(1)!] = _decode(
          attribute.group(2) ?? attribute.group(3)!,
        );
        position = attribute.end;
      }
      if (attributes.length != 2 ||
          (attributes['input_id']?.trim().isEmpty ?? true) ||
          (attributes['label']?.trim().isEmpty ?? true)) {
        throw const FormatException(
          'A ref requires exactly one input_id, and label.',
        );
      }
      parts.add(
        PromptPart.reference(
          tag.group(0)!,
          attributes['input_id'],
          attributes['label'],
        ),
      );
      cursor = tag.end;
    }
    if (cursor < text.length) {
      parts.add(PromptPart.text(text.substring(cursor)));
    }
    return StoryboardPrompt._(List.unmodifiable(parts));
  }

  /// 文本按标签位置展开；没有标签引用的文本依输入顺序前置，不再解析插入的文本。
  String render({
    Map<String, String> textInputs = const {},
    required String Function(PromptPart part) reference,
  }) {
    final used = <String>{};
    final body = parts.map((part) {
      if (!part.isReference) {
        return part.text;
      }
      if (textInputs.containsKey(part.inputId)) {
        used.add(part.inputId!);
        return textInputs[part.inputId]!;
      }
      return reference(part);
    }).join();
    final prefix = textInputs.entries
        .where((entry) => !used.contains(entry.key) && entry.value.isNotEmpty)
        .map((entry) => entry.value)
        .join('\n');
    return prefix.isEmpty
        ? body
        : body.isEmpty
        ? prefix
        : '$prefix\n$body';
  }

  static String reference(String inputId, String label) =>
      '<ref input_id="${escapeXmlAttribute(inputId)}" label="${escapeXmlAttribute(label)}" />';

  static String appendShot(String source) {
    final headers = RegExp(
      r'^Shot\s+(\d+)',
      multiLine: true,
    ).allMatches(source);
    var number = 1;
    for (final match in headers) {
      final next = int.parse(match.group(1)!) + 1;
      if (next > number) {
        number = next;
      }
    }
    var start = 0.0;
    for (final match in RegExp(
      r'【\s*\d+(?:\.\d+)?\s*[-–]\s*(\d+(?:\.\d+)?)s\s*】',
    ).allMatches(source)) {
      start = double.parse(match.group(1)!);
    }
    String seconds(double value) => value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
    final from = seconds(start);
    final to = seconds(start + 2);
    final template =
        'Shot $number（景别·角度·运镜·2s）\n【$from-${to}s】\n首帧：\n[$from-${to}s] 节拍：\n结束状态：';
    return source.isEmpty ? template : '$source\n\n$template';
  }

  static String _decode(String value) {
    if (RegExp(r'&(?!amp;|apos;|quot;|lt;|gt;)').hasMatch(value) ||
        value.contains('<')) {
      throw const FormatException('Invalid XML attribute escape.');
    }
    return value
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
  }

  void requireValidReferences(Iterable<String> inputIds) {
    final validIds = inputIds.toSet();
    for (final ref in references) {
      if (!validIds.contains(ref.inputId)) {
        throw FormatException(
          'Unknown prompt reference input_id: ${ref.inputId}.',
        );
      }
    }
  }
}
