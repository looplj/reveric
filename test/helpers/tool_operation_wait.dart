// 职责: 测试中等待后台工具操作结束；wait 遇到待审批会立即返回，这里继续等到审批结束。
// 关联文件:
//   lib/shared/services/ai/tool_operations.dart

import 'dart:async';

import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';

Future<Map<String, dynamic>> waitPastApproval(
  ToolOperationManager operations,
  String runId,
  ToolExecutionContext context,
) async {
  var result = await operations.wait(runId, context);
  while (result['status'] == ToolOperationStatus.waiting_approval.name) {
    final left = Completer<void>();
    final subscription = operations.registry.changes
        .where(
          (r) =>
              r.runId == runId &&
              r.status != ToolOperationStatus.waiting_approval,
        )
        .listen((_) {
          if (!left.isCompleted) left.complete();
        });
    try {
      if (operations.read(runId, context)['status'] ==
          ToolOperationStatus.waiting_approval.name) {
        await left.future;
      }
    } finally {
      await subscription.cancel();
    }
    result = await operations.wait(runId, context);
  }
  return result;
}
