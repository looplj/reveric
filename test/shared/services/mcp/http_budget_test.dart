// 职责: 实测独立 HTTP 服务大响应的宿主内存峰值，并验证预算不改写成功状态。
// 关联文件:
//   lib/shared/services/mcp/client_adapter.dart
//   lib/shared/services/mcp/result_adapter.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import 'package:reveric/shared/models/mcp/config.dart';
import 'package:reveric/shared/services/mcp/client_adapter.dart';
import 'package:reveric/shared/services/mcp/result_adapter.dart';

void main() {
  test(
    'MCP-E06: HTTP mixed result keeps images beside bounded model text',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mcp-http-budget-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final script = File('${directory.path}/server.py');
      await script.writeAsString(r'''
import http.server,json,sys
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  self.send_response(405);self.end_headers()
 def do_POST(self):
  req=json.loads(self.rfile.read(int(self.headers['content-length'])))
  if 'id' not in req:
   self.send_response(202);self.end_headers();return
  method=req['method']
  if method=='initialize': result={'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'large-fixture','version':'1'}}
  elif method=='tools/list': result={'tools':[{'name':'large','inputSchema':{'type':'object','properties':{}}}]}
  elif method=='tools/call': result={'content':[{'type':'text','text':'界😀'*1048576},{'type':'image','mimeType':'image/png','data':sys.argv[1]}]}
  else: result=None
  out={'jsonrpc':'2.0','id':req['id']}
  if result is None: out['error']={'code':-32601,'message':'Method not found'}
  else: out['result']=result
  body=json.dumps(out,ensure_ascii=False).encode('utf-8')
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True)
server.serve_forever()
''');
      final imageData = base64Encode(
        img.encodePng(img.Image(width: 2, height: 2)),
      );
      final process = await Process.start('python3', [
        '-u',
        script.path,
        imageData,
      ]);
      final errors = process.stderr.drain<void>();
      addTearDown(() async {
        process.kill();
        await process.exitCode;
        await errors;
      });
      final port = int.parse(
        await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
      );
      final adapter = await McpClientAdapter.connect(
        McpServerConfig(
          name: 'large',
          enabled: true,
          connection: McpHttpConfig(url: 'http://127.0.0.1:$port/mcp'),
        ),
      );
      addTearDown(adapter.close);
      await adapter.listTools();
      final before = ProcessInfo.currentRss;
      final beforePeak = ProcessInfo.maxRss;
      final result = McpResultAdapter.normalize(
        await adapter.callTool('large', {}),
      );
      final after = ProcessInfo.currentRss;
      final peak = ProcessInfo.maxRss;
      expect(result.ok, true);
      expect(result.text.single, '界😀' * 1048576);
      final preview = McpResultAdapter.limit(
        result,
        McpResultAdapter.modelBudget,
      );
      expect(preview.ok, true);
      expect(preview.text.join('\n'), contains('[truncated]'));
      final image = preview.content.whereType<sdk.ImageContent>().single;
      expect(image.data, imageData);
      expect(image.mimeType, 'image/png');
      expect(
        preview.textJsonBytes,
        lessThanOrEqualTo(McpResultAdapter.modelBudget),
      );
      // Numeric-only evidence. This is an observed process peak, not a hard parser memory limit.
      stdout.writeln(
        jsonEncode({
          'fixture': 'MCP-E06',
          'response_text_utf8_bytes': 7 * 1024 * 1024,
          'rss_before': before,
          'rss_after': after,
          'max_rss_before': beforePeak,
          'max_rss_after': peak,
          'delivered_json_bytes': result.jsonBytes,
        }),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
    skip: Platform.isWindows ? 'Requires python3 fixture runtime' : false,
  );
}
