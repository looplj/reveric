// 职责: 为界面与 Agent 复用剪辑会话，并有界保留进程内撤销历史。
// 关联文件:
//   lib/shared/services/editing/session.dart
//   lib/shared/providers/editing.dart
import '../../database/novel_content_database.dart';
import 'service.dart';
import 'session.dart';

class EditingSessions {
  final _sessions = <(NovelContentDatabase, String?, String), EditingSession>{};
  EditingSession get(EditingService service, String id) {
    final key = (service.database, service.novelId, id);
    final session = _sessions.remove(key) ?? EditingSession(service, id);
    _sessions[key] = session;
    prune(except: session);
    return session;
  }

  void prune({EditingSession? except}) {
    for (final entry in _sessions.entries.toList()) {
      if (_sessions.length <= 32) {
        break;
      }
      if (entry.value != except && entry.value.evictable) {
        _sessions.remove(entry.key);
        entry.value.dispose();
      }
    }
  }

  void dispose() {
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
  }
}
