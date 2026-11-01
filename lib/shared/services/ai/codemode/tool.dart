// 职责: 定义 Codemode 静态工具契约及数据操作、Run 命令的能力范围。
// 关联文件:
//   lib/shared/services/ai/codemode/orchestrator.dart
//   lib/shared/services/ai/chat_agent_tool_dispatcher.dart
import 'dart:convert';

import '../../../agent/agent_tool_dispatcher.dart';

const codemodeToolName = 'Codemode';
const codemodeToolNames = {
  'Read',
  'Glob',
  'Grep',
  'GraphSearch',
  'Run',
  'Create',
  'Write',
  'Edit',
  'Replace',
  'Remove',
};
const codemodeWriteToolNames = {'Create', 'Write', 'Edit', 'Replace', 'Remove'};

const codemodeToolDef = ToolDef(
  name: codemodeToolName,
  // 128 KiB 与 CodemodeRuntimeLimits.outputBytes 默认值一致，调整时同步修改。
  description:
      '运行 JavaScript，组合调用内置工具和已启用的 MCP 工具。脚本不能直接访问网络、文件或加载模块。\n'
      '- 发现工具：await listMcpServers() 查看 MCP 服务；await listTools({mcpServer: "服务名称"}) 列出服务工具；'
      'await searchTool(query, options) 搜索；await describeTool(name) 查看定义。\n'
      '- 调用：await tools[name](参数)，name 使用发现结果，参数与同名工具相同。成功返回结果对象；'
      '失败抛出 Error，带 error_code，可能带 error、hint、recovery。'
      'error_code 取值：invalid_argument、not_found、already_exists、conflict、'
      'failed_precondition、locked、unauthenticated、permission_denied、'
      'unsupported、resource_exhausted、unavailable、internal；具体原因看 error。'
      '未捕获的错误保留在 tool_error 中。\n'
      '- 可用工具及成功返回的关键字段（? 表示可能缺失）：\n'
      '  Read → 列表 entries[]，字段 value，资源详情为资源字段；has_more?，next_offset?\n'
      '  Glob → matches[]，truncated\n'
      '  Grep → text，truncated\n'
      '  GraphSearch → layers[].relations[]\n'
      '  Run → 返回值随子命令而定；通过 Run help 查询可在脚本中调用的命令。后台操作返回 run_id，可通过 Run operations 查询、等待或取消。\n'
      '  Create → path，id?\n'
      '  Write → ok；updated?、created?、ignored_fields?。updated=true 表示发生更新，false 或缺省表示未更新。\n'
      '  Edit → edited，match_count\n'
      '  Replace → dry_run=true 时 matched_fields、total_matches；否则 applied_fields、total_replacements、failed?\n'
      '  Remove → removed，missing?\n'
      '- 资源详情的字段因集合而异，需要时在脚本内 Read /_schema/{collection} 查看 output_schema；'
      '列表条目缺字段时，按条目 path 读取详情。依赖的字段缺失时停止相关操作并报告，不要猜默认值。\n'
      '- text(value) 和 return 添加输出，对象直接传入，合计上限 128 KiB；其余中间结果不进入对话。'
      '捕获或跳过的失败要在输出中列出。',
  outputSchema: {
    'type': 'object',
    'properties': {
      'ok': {'type': 'boolean'},
      'output': {'type': 'array', 'items': {}},
      'return_value': {},
      'call_count': {'type': 'integer'},
      'completed_count': {'type': 'integer'},
      'failed_count': {'type': 'integer'},
      'diagnostics': {'type': 'object'},
      'completed_operations': {
        'type': 'array',
        'items': {'type': 'object'},
      },
      'uncertain_operations': {
        'type': 'array',
        'items': {'type': 'object'},
      },
      'pending_operations': {
        'type': 'array',
        'items': {'type': 'object'},
      },
      'error_code': {'type': 'string'},
      'error': {'type': 'string'},
      'tool_error': {'type': 'object'},
      'js_error_message': {'type': 'string'},
      'cancelled': {'type': 'boolean'},
    },
    'required': ['ok'],
    'additionalProperties': true,
  },
  inputSchema: {
    'type': 'object',
    'properties': {
      'code': {
        'type': 'string',
        'description': 'JavaScript 代码，可直接使用 await 和 return，无需声明外层函数。',
      },
    },
    'required': ['code'],
    'additionalProperties': false,
  },
);

final _codeFence = RegExp(r'^```[\w-]*[ \t]*\r?\n([\s\S]*?)\r?\n?```$');

/// 模型常把源码包进 Markdown 围栏或再编码一层 JSON；两者都不是合法 JS，
/// 解包后再执行。围栏与 JSON 可能互相嵌套，逐层剥到不再变化为止。
String normalizeCodemodeSource(String code) {
  var source = code.trim();
  for (var depth = 0; depth < 4; depth++) {
    final unwrapped = _unwrapCodemodeSource(source);
    if (unwrapped == null) {
      break;
    }
    source = unwrapped.trim();
  }
  return source;
}

String? _unwrapCodemodeSource(String source) {
  final fence = _codeFence.firstMatch(source);
  if (fence != null) {
    return fence.group(1)!;
  }
  if (!source.startsWith('{') && !source.startsWith('"')) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    return null;
  }
  if (decoded is String) {
    return decoded;
  }
  if (decoded is Map && decoded.length == 1 && decoded['code'] is String) {
    return decoded['code'] as String;
  }
  return null;
}
