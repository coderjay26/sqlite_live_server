import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'sqlite_service.dart';

class WebServer {
  final SQLiteService dbService;
  HttpServer? _server;
  final int port;
  final bool enableWebSocket;
  bool _isRunning = false;

  WebServer(this.dbService, {this.port = 8080, this.enableWebSocket = true});

  Future<bool> startServer() async {
    try {
      if (_isRunning) {
        print('🚨 Server is already running');
        return true;
      }

      String? ipAddress = await _getLocalIPAddress();
      var router = Router();

      // API Routes
      router.get('/api/tables', _getTables);
      router.get('/api/tables/<table>/schema', _getTableSchema);
      router.get('/api/tables/<table>/info', _getTableInfo);
      router.get('/api/query', _executeQuery);
      router.post('/api/query', _executeQueryPost);
      router.post('/api/tables/<table>/data', _insertData);
      router.put('/api/tables/<table>/data', _updateData);
      router.delete('/api/tables/<table>/data', _deleteData);
      router.get('/api/database/info', _getDatabaseInfo);
      router.get('/api/export/<table>', _exportTable);
      router.get('/api/history', _getQueryHistory);
      router.get('/api/metadata', _getMetadata);

      // WebSocket
      if (enableWebSocket) {
        router.get('/ws', webSocketHandler((WebSocketChannel webSocket) {
          webSocket.stream.listen(
            (message) => _handleWebSocketMessage(webSocket, message),
            onError: (error) => print('WebSocket error: $error'),
            onDone: () => print('WebSocket disconnected'),
          );
        }));
      }

      // Serve UI
      router.get('/', (Request request) {
        return Response.ok(_htmlPage, headers: {'Content-Type': 'text/html'});
      });

      var handler = Pipeline()
          .addMiddleware(logRequests())
          .addMiddleware(_corsMiddleware())
          .addHandler(router);

      _server = await io.serve(handler, InternetAddress.anyIPv4, port);
      _isRunning = true;
      
      print('\x1B[32m🚀 SQLite Pro Server started successfully!\x1B[0m');
      print('\x1B[36m📍 Local: http://localhost:$port\x1B[0m');
      if (ipAddress != null) {
        print('\x1B[36m🌐 Network: http://$ipAddress:$port\x1B[0m');
      }
      return true;
    } catch (e) {
      print('\x1B[31m🚨 Failed to start server: $e\x1B[0m');
      return false;
    }
  }

  Future<bool> _isPortInUse(int port) async {
    try {
      var server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await server.close();
      return false;
    } catch (e) {
      return true;
    }
  }

  Middleware _corsMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        if (request.method == 'OPTIONS') {
          return Response.ok('', headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
            'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
          });
        }
        final response = await handler(request);
        return response.change(headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
        });
      };
    };
  }

  // API Handlers
  Future<Response> _getTables(Request request) async {
    try {
      var tables = await dbService.getTables();
      var tablesWithInfo = <Map<String, dynamic>>[];
      for (var table in tables) {
        var count = await dbService.getTableRowCount(table);
        tablesWithInfo.add({'name': table, 'rowCount': count, 'type': 'table'});
      }
      return _jsonResponse(tablesWithInfo);
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _getTableSchema(Request request) async {
    try {
      var table = request.params['table']!;
      var schema = await dbService.getTableSchema(table);
      return _jsonResponse(schema);
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _getTableInfo(Request request) async {
    try {
      var table = request.params['table']!;
      var info = await dbService.getTableInfo(table);
      return _jsonResponse(info);
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _executeQuery(Request request) async {
    final sql = request.url.queryParameters['sql'];
    return await _executeSqlQuery(sql);
  }

  Future<Response> _executeQueryPost(Request request) async {
    final body = await request.readAsString();
    final json = jsonDecode(body);
    final sql = json['sql'] as String?;
    return await _executeSqlQuery(sql);
  }

  Future<Response> _executeSqlQuery(String? sql) async {
    if (sql == null || sql.isEmpty) {
      return Response.badRequest(body: jsonEncode({'error': 'SQL query is required'}));
    }
    try {
      final stopwatch = Stopwatch()..start();
      var data = await dbService.query(sql);
      stopwatch.stop();
      _addToQueryHistory(sql, data.length, stopwatch.elapsedMilliseconds);
      return _jsonResponse({
        'data': data,
        'rowCount': data.length,
        'executionTime': stopwatch.elapsedMilliseconds,
        'columns': data.isNotEmpty ? data[0].keys.toList() : [],
        'success': true
      });
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _insertData(Request request) async {
    try {
      var table = request.params['table']!;
      var data = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var result = await dbService.insert(table, data);
      return _jsonResponse({'success': true, 'insertedId': result});
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _updateData(Request request) async {
    try {
      var table = request.params['table']!;
      var data = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      var where = request.url.queryParameters['where'];
      var affectedRows = await dbService.update(table, data, where: where);
      return _jsonResponse({'success': true, 'affectedRows': affectedRows});
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _deleteData(Request request) async {
    try {
      var table = request.params['table']!;
      var where = request.url.queryParameters['where'];
      var affectedRows = await dbService.delete(table, where: where);
      return _jsonResponse({'success': true, 'affectedRows': affectedRows});
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _getDatabaseInfo(Request request) async {
    try {
      var info = await dbService.getDatabaseInfo();
      return _jsonResponse(info);
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _exportTable(Request request) async {
    try {
      var table = request.params['table']!;
      var format = request.url.queryParameters['format'] ?? 'json';
      var data = await dbService.query('SELECT * FROM $table');
      if (format == 'csv') return _csvResponse(_convertToCsv(data), table);
      return _jsonResponse(data);
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _getMetadata(Request request) async {
    try {
      var metadata = await dbService.getAllDatabaseMetadata();
      return _jsonResponse(metadata);
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _getQueryHistory(Request request) async {
    return _jsonResponse(_queryHistory.reversed.toList());
  }

  void _handleWebSocketMessage(WebSocketChannel webSocket, dynamic message) {
    try {
      var json = jsonDecode(message);
      if (json['action'] == 'execute_query') {
        _executeQueryAndSend(webSocket, json['sql']);
      }
    } catch (e) {
      webSocket.sink.add(jsonEncode({'error': e.toString()}));
    }
  }

  void _executeQueryAndSend(WebSocketChannel webSocket, String sql) async {
    try {
      var data = await dbService.query(sql);
      webSocket.sink.add(jsonEncode({'type': 'query_result', 'data': data, 'rowCount': data.length}));
    } catch (e) {
      webSocket.sink.add(jsonEncode({'error': e.toString()}));
    }
  }

  Response _jsonResponse(dynamic data) => Response.ok(jsonEncode(data), headers: {'Content-Type': 'application/json'});
  Response _errorResponse(String error) => Response.internalServerError(body: jsonEncode({'error': error, 'success': false}), headers: {'Content-Type': 'application/json'});
  Response _csvResponse(String csvData, String tableName) => Response.ok(csvData, headers: {'Content-Type': 'text/csv', 'Content-Disposition': 'attachment; filename="$tableName.csv"'});

  String _convertToCsv(List<Map<String, dynamic>> data) {
    if (data.isEmpty) return '';
    var headers = data[0].keys;
    var csv = StringBuffer()..writeln(headers.join(','));
    for (var row in data) {
      csv.writeln(headers.map((h) {
        var v = row[h]?.toString() ?? '';
        return v.contains(',') || v.contains('"') ? '"${v.replaceAll('"', '""')}"' : v;
      }).join(','));
    }
    return csv.toString();
  }

  final List<Map<String, dynamic>> _queryHistory = [];
  void _addToQueryHistory(String sql, int rowCount, int executionTime) {
    _queryHistory.add({'sql': sql, 'rowCount': rowCount, 'executionTime': executionTime, 'timestamp': DateTime.now().toIso8601String()});
    if (_queryHistory.length > 100) _queryHistory.removeAt(0);
  }

  Future<void> stopServer() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _isRunning = false;
    }
  }

  Future<String?> _getLocalIPAddress() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  static const String _htmlPage = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SQLite Pro | Premium Database Manager</title>
    
    <!-- Fonts & Icons -->
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    
    <!-- CodeMirror -->
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/codemirror.min.css">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/theme/dracula.min.css">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/addon/hint/show-hint.min.css">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/codemirror.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/mode/sql/sql.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/addon/hint/show-hint.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/addon/hint/sql-hint.min.js"></script>

    <style>
        :root {
            --bg: #0f172a;
            --sidebar-bg: #1e293b;
            --accent: #3b82f6;
            --accent-glow: rgba(59, 130, 246, 0.5);
            --text: #f1f5f9;
            --text-dim: #94a3b8;
            --glass: rgba(30, 41, 59, 0.7);
            --border: rgba(255, 255, 255, 0.1);
            --success: #10b981;
            --error: #ef4444;
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Outfit', sans-serif;
            background: var(--bg);
            color: var(--text);
            height: 100vh;
            display: flex;
            overflow: hidden;
        }

        /* Sidebar */
        .sidebar {
            width: 300px;
            background: var(--sidebar-bg);
            border-right: 1px solid var(--border);
            display: flex;
            flex-direction: column;
            backdrop-filter: blur(10px);
        }

        .sidebar-header {
            padding: 24px;
            border-bottom: 1px solid var(--border);
            background: linear-gradient(to bottom right, rgba(59, 130, 246, 0.1), transparent);
        }

        .logo {
            font-size: 24px;
            font-weight: 700;
            display: flex;
            align-items: center;
            gap: 12px;
            color: var(--accent);
            text-shadow: 0 0 20px var(--accent-glow);
        }

        .db-badge {
            background: rgba(59, 130, 246, 0.2);
            color: var(--accent);
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            margin-top: 12px;
            display: inline-block;
            border: 1px solid var(--accent);
        }

        .tables-list {
            flex: 1;
            overflow-y: auto;
            padding: 16px;
        }

        .table-item {
            padding: 12px 16px;
            border-radius: 12px;
            cursor: pointer;
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            gap: 12px;
            border: 1px solid transparent;
        }

        .table-item:hover {
            background: rgba(255, 255, 255, 0.05);
            border-color: var(--border);
            transform: translateX(4px);
        }

        .table-item.active {
            background: var(--accent);
            color: white;
            box-shadow: 0 0 20px rgba(59, 130, 246, 0.4);
        }

        /* Main Content */
        .main {
            flex: 1;
            display: flex;
            flex-direction: column;
            background: radial-gradient(circle at top right, rgba(59, 130, 246, 0.05), transparent);
        }

        .header {
            padding: 20px 40px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid var(--border);
        }

        .btn {
            padding: 10px 20px;
            border-radius: 12px;
            border: none;
            cursor: pointer;
            font-weight: 600;
            transition: all 0.2s;
            display: flex;
            align-items: center;
            gap: 8px;
            font-family: inherit;
        }

        .btn-primary { background: var(--accent); color: white; }
        .btn-primary:hover { transform: translateY(-2px); box-shadow: 0 4px 15px var(--accent-glow); }
        
        /* Editor Section */
        .editor-container {
            padding: 24px 40px;
            display: flex;
            flex-direction: column;
            gap: 16px;
        }

        .CodeMirror {
            height: 380px;
            border-radius: 16px;
            font-family: 'JetBrains Mono', monospace;
            font-size: 14px;
            padding: 10px;
            border: 1px solid var(--border);
            background: var(--glass) !important;
            backdrop-filter: blur(8px);
        }

        .toolbar {
            display: flex;
            gap: 12px;
            align-items: center;
        }

        /* Results Section */
        .results-container {
            flex: 1;
            padding: 0 40px 24px;
            overflow: hidden;
            display: flex;
            flex-direction: column;
        }

        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }

        .stat-card {
            background: var(--glass);
            border: 1px solid var(--border);
            padding: 16px;
            border-radius: 16px;
            backdrop-filter: blur(8px);
        }

        .stat-label { font-size: 12px; color: var(--text-dim); text-transform: uppercase; letter-spacing: 1px; }
        .stat-value { font-size: 20px; font-weight: 600; margin-top: 4px; }

        .table-wrapper {
            flex: 1;
            background: var(--glass);
            border-radius: 20px;
            border: 1px solid var(--border);
            overflow: auto;
            backdrop-filter: blur(12px);
        }

        table { width: 100%; border-collapse: collapse; }
        th { 
            position: sticky; top: 0; background: var(--sidebar-bg); 
            padding: 16px; text-align: left; font-weight: 600; 
            border-bottom: 1px solid var(--border); z-index: 10;
        }
        td { padding: 12px 16px; border-bottom: 1px solid var(--border); font-size: 14px; color: var(--text-dim); }
        tr:hover td { color: var(--text); background: rgba(255, 255, 255, 0.02); }

        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 10px; }
        ::-webkit-scrollbar-thumb:hover { background: var(--text-dim); }

        .hint-text { font-size: 12px; color: var(--text-dim); margin-top: 4px; }
    </style>
</head>
<body>
    <div class="sidebar">
        <div class="sidebar-header">
            <div class="logo"><i class="fas fa-bolt"></i> SQLite Pro</div>
            <div class="db-badge" id="db-name-badge">Loading...</div>
        </div>
        <div class="tables-list" id="tables-list">
            <!-- Tables will be loaded here -->
        </div>
    </div>

    <div class="main">
        <div class="header">
            <h1>Query Explorer</h1>
            <div class="toolbar">
                <button class="btn btn-primary" onclick="runQuery()">
                    <i class="fas fa-play"></i> Run Selection
                </button>
            </div>
        </div>

        <div class="editor-container">
            <textarea id="sql-editor"></textarea>
            <div class="hint-text">
                <i class="fas fa-info-circle"></i> Shortcut: <strong>Ctrl + Enter</strong> to run selection.
            </div>
        </div>

        <div class="results-container">
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="stat-label">Rows Affected</div>
                    <div class="stat-value" id="stat-rows">0</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">Execution Time</div>
                    <div class="stat-value" id="stat-time">0 ms</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">Columns</div>
                    <div class="stat-value" id="stat-cols">0</div>
                </div>
            </div>

            <div class="table-wrapper" id="results-table-wrapper">
                <table id="results-table">
                    <!-- Results will be loaded here -->
                </table>
            </div>
        </div>
    </div>

    <script>
        let editor;
        let metadata = {};

        document.addEventListener('DOMContentLoaded', async () => {
            initEditor();
            await loadMetadata();
            await loadDatabaseInfo();
            await loadTables();
        });

        function initEditor() {
            editor = CodeMirror.fromTextArea(document.getElementById('sql-editor'), {
                mode: 'text/x-sql',
                theme: 'dracula',
                lineNumbers: true,
                indentWithTabs: true,
                smartIndent: true,
                matchBrackets: true,
                autofocus: true,
                extraKeys: {
                    "Ctrl-Space": "autocomplete",
                    "Ctrl-Enter": () => runQuery()
                },
                hintOptions: {
                    tables: metadata
                }
            });

            editor.setValue("SELECT * FROM sqlite_master;");
        }

        async function loadMetadata() {
            try {
                const res = await fetch('/api/metadata');
                metadata = await res.json();
                if (editor) editor.setOption('hintOptions', { tables: metadata });
            } catch (e) { console.error("Metadata load failed", e); }
        }

        async function loadDatabaseInfo() {
            try {
                const res = await fetch('/api/database/info');
                const info = await res.json();
                document.getElementById('db-name-badge').textContent = info.name;
            } catch (e) {}
        }

        async function loadTables() {
            try {
                const res = await fetch('/api/tables');
                const tables = await res.json();
                const list = document.getElementById('tables-list');
                list.innerHTML = tables.map(t => `
                    <div class="table-item" onclick="selectTable('\${t.name}')">
                        <i class="fas fa-table"></i>
                        <span>\${t.name}</span>
                        <span style="margin-left: auto; font-size: 10px; opacity: 0.5">\${t.rowCount}</span>
                    </div>
                `).join('');
            } catch (e) {}
        }

        function selectTable(name) {
            editor.setValue(\`SELECT * FROM \${name} LIMIT 100;\`);
            runQuery();
            document.querySelectorAll('.table-item').forEach(el => {
                el.classList.toggle('active', el.textContent.includes(name));
            });
        }

        async function runQuery() {
            const selection = editor.getSelection().trim();
            const query = selection || editor.getValue().trim();
            
            if (!query) return;

            const startTime = performance.now();
            try {
                const res = await fetch('/api/query', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ sql: query })
                });
                const result = await res.json();
                const endTime = performance.now();

                displayResults(result, Math.round(endTime - startTime));
            } catch (e) {
                alert("Query failed: " + e.message);
            }
        }

        function displayResults(result, time) {
            document.getElementById('stat-rows').textContent = result.rowCount || 0;
            document.getElementById('stat-time').textContent = (result.executionTime || time) + " ms";
            document.getElementById('stat-cols').textContent = result.columns ? result.columns.length : 0;

            if (result.error) {
                document.getElementById('results-table-wrapper').innerHTML = \`<div style="padding: 40px; color: var(--error)">
                    <i class="fas fa-exclamation-triangle"></i> \${result.error}
                </div>\`;
                return;
            }

            if (!result.data || result.data.length === 0) {
                document.getElementById('results-table-wrapper').innerHTML = \`<div style="padding: 40px; text-align: center; color: var(--text-dim)">
                    No data returned.
                </div>\`;
                return;
            }

            const cols = result.columns;
            let html = '<table><thead><tr>' + cols.map(c => \`<th>\${c}</th>\`).join('') + '</tr></thead><tbody>';
            
            result.data.forEach(row => {
                html += '<tr>' + cols.map(c => \`<td>\${row[c] !== null ? row[c] : '<span style="opacity: 0.3">NULL</span>'}</td>\`).join('') + '</tr>';
            });
            html += '</tbody></table>';

            document.getElementById('results-table-wrapper').innerHTML = html;
        }
    </script>
</body>
</html>
''';
}