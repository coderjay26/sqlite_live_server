import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
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
      router.get('/api/database/info', _getDatabaseInfo);
      router.get('/api/metadata', _getMetadata);

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
      print('\x1B[36m📍 Local:   http://localhost:$port\x1B[0m');
      if (ipAddress != null) {
        print('\x1B[36m📍 Network: http://$ipAddress:$port\x1B[0m');
      }
      return true;
    } catch (e) {
      print('\x1B[31m🚨 Failed to start server: $e\x1B[0m');
      return false;
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

  // API Handlers (Internal methods kept as is)
  Future<Response> _getTables(Request request) async {
    try {
      var tables = await dbService.getTables();
      var tablesWithInfo = <Map<String, dynamic>>[];
      for (var table in tables) {
        var count = await dbService.getTableRowCount(table);
        tablesWithInfo.add({'name': table, 'rowCount': count});
      }
      return _jsonResponse(tablesWithInfo);
    } catch (e) { return _errorResponse(e.toString()); }
  }

  Future<Response> _getTableSchema(Request request) async {
    try {
      var table = request.params['table']!;
      var schema = await dbService.getTableSchema(table);
      return _jsonResponse(schema);
    } catch (e) { return _errorResponse(e.toString()); }
  }

  Future<Response> _getTableInfo(Request request) async {
    try {
      var table = request.params['table']!;
      var info = await dbService.getTableInfo(table);
      return _jsonResponse(info);
    } catch (e) { return _errorResponse(e.toString()); }
  }

  Future<Response> _executeQuery(Request request) async => await _executeSqlQuery(request.url.queryParameters['sql']);
  Future<Response> _executeQueryPost(Request request) async {
    final body = await request.readAsString();
    final json = jsonDecode(body);
    return await _executeSqlQuery(json['sql']);
  }

  Future<Response> _executeSqlQuery(String? sql) async {
    if (sql == null || sql.isEmpty) return _errorResponse('SQL query required');
    try {
      final watch = Stopwatch()..start();
      var data = await dbService.query(sql);
      watch.stop();
      return _jsonResponse({
        'data': data,
        'rowCount': data.length,
        'executionTime': watch.elapsedMilliseconds,
        'columns': data.isNotEmpty ? data[0].keys.toList() : [],
        'success': true
      });
    } catch (e) { return _errorResponse(e.toString()); }
  }

  Future<Response> _getDatabaseInfo(Request request) async {
    try {
      var info = await dbService.getDatabaseInfo();
      var ip = await _getLocalIPAddress();
      return _jsonResponse({
        ...info,
        'network_ip': ip,
        'port': port
      });
    } catch (e) { return _errorResponse(e.toString()); }
  }

  Future<Response> _getMetadata(Request request) async {
    try {
      var metadata = await dbService.getAllDatabaseMetadata();
      return _jsonResponse(metadata);
    } catch (e) { return _errorResponse(e.toString()); }
  }

  Response _jsonResponse(dynamic data) => Response.ok(jsonEncode(data), headers: {'Content-Type': 'application/json'});
  Response _errorResponse(String error) => Response.ok(jsonEncode({'error': error, 'success': false}), headers: {'Content-Type': 'application/json'});

  Future<void> stopServer() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _isRunning = false;
    }
  }

  Future<String?> _getLocalIPAddress() async {
    try {
      for (var iface in await NetworkInterface.list()) {
        for (var addr in iface.addresses) {
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
    <title>Nexus SQL Pro | Glassmorphic Experience</title>
    
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/codemirror.min.css">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/theme/dracula.min.css">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/addon/hint/show-hint.min.css">
    
    <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/codemirror.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/mode/sql/sql.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/addon/hint/show-hint.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.13/addon/hint/sql-hint.min.js"></script>

    <style>
        :root {
            --bg: #030712;
            --glass: rgba(17, 25, 40, 0.6);
            --glass-border: rgba(255, 255, 255, 0.125);
            --accent: #6366f1;
            --accent-glow: rgba(99, 102, 241, 0.5);
            --text: #f8fafc;
            --text-dim: #94a3b8;
            --success: #10b981;
            --error: #ef4444;
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Outfit', sans-serif;
            background: var(--bg);
            color: var(--text);
            height: 100vh;
            overflow: hidden;
            position: relative;
            display: flex;
        }

        /* Animated Blobs */
        .blob {
            position: absolute; width: 400px; height: 400px;
            background: radial-gradient(circle, var(--accent-glow) 0%, transparent 70%);
            border-radius: 50%; filter: blur(80px); z-index: -1; animation: float 20s infinite alternate;
        }
        @keyframes float {
            0% { transform: translate(0, 0) scale(1); }
            100% { transform: translate(100px, 100px) scale(1.2); }
        }

        /* Layout */
        .nav-rail { width: 80px; background: rgba(0,0,0,0.4); border-right: 1px solid var(--glass-border); display: flex; flex-direction: column; align-items: center; padding: 30px 0; gap: 30px; backdrop-filter: blur(10px); }
        .sidebar { width: 320px; background: var(--glass); border-right: 1px solid var(--glass-border); display: flex; flex-direction: column; backdrop-filter: blur(24px); box-shadow: 10px 0 30px rgba(0,0,0,0.5); }
        .main { flex: 1; display: flex; flex-direction: column; position: relative; z-index: 1; }

        /* UI Elements */
        .avatar { width: 42px; height: 42px; border-radius: 14px; background: linear-gradient(135deg, #6366f1, #a855f7); border: 2px solid var(--glass-border); }
        .nav-icon { color: var(--text-dim); font-size: 22px; cursor: pointer; transition: 0.3s; }
        .nav-icon:hover, .nav-icon.active { color: var(--accent); text-shadow: 0 0 10px var(--accent-glow); }

        .search-area { padding: 24px; }
        .search-input { width: 100%; background: rgba(255,255,255,0.05); border: 1px solid var(--glass-border); border-radius: 12px; padding: 12px 16px; color: white; outline: none; }
        .table-list { flex: 1; overflow-y: auto; padding: 0 16px 24px; }
        .table-item { padding: 12px 16px; border-radius: 14px; cursor: pointer; transition: 0.3s; display: flex; align-items: center; gap: 12px; margin-bottom: 6px; border: 1px solid transparent; }
        .table-item:hover { background: rgba(255,255,255,0.08); border-color: var(--glass-border); }
        .table-item.active { background: rgba(99, 102, 241, 0.2); border-color: var(--accent); }

        .top-bar { padding: 24px 40px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--glass-border); }
        .btn { padding: 10px 24px; border-radius: 12px; border: 1px solid var(--glass-border); cursor: pointer; transition: 0.3s; font-weight: 600; display: flex; align-items: center; gap: 8px; font-family: inherit; }
        .btn-primary { background: var(--accent); color: white; box-shadow: 0 8px 16px-4px var(--accent-glow); }
        .btn-primary:hover { transform: translateY(-2px); box-shadow: 0 12px 20px -4px var(--accent-glow); }

        /* Glass Cards */
        .glass-card { background: var(--glass); border: 1px solid var(--glass-border); border-radius: 24px; backdrop-filter: blur(32px); padding: 24px; box-shadow: 0 15px 35px rgba(0,0,0,0.3); }
        .editor-section { padding: 32px 40px; display: grid; grid-template-columns: 1fr 300px; gap: 24px; }
        .CodeMirror { height: 350px; background: transparent !important; font-family: 'JetBrains Mono', monospace; font-size: 14px; margin-top: 16px; border-radius: 16px; border: 1px solid var(--glass-border); }

        .results-section { padding: 0 40px 32px; flex: 1; display: flex; flex-direction: column; overflow: hidden; }
        .table-wrap { flex: 1; overflow: auto; background: var(--glass); border: 1px solid var(--glass-border); border-radius: 20px; backdrop-filter: blur(40px); position: relative; }
        table { min-width: 100%; border-collapse: collapse; table-layout: auto; }
        th { background: rgba(3, 7, 18, 0.9); padding: 16px; text-align: left; font-weight: 600; color: var(--text-dim); border-bottom: 20px solid transparent; border-bottom: 1px solid var(--glass-border); position: sticky; top: 0; white-space: nowrap; z-index: 10; }
        td { padding: 14px 16px; border-bottom: 1px solid var(--glass-border); font-size: 14px; white-space: nowrap; }
        tr:hover { background: rgba(255,255,255,0.03); }

        .stat-card { display: flex; flex-direction: column; gap: 4px; padding: 20px; }
        .stat-label { font-size: 11px; text-transform: uppercase; letter-spacing: 1.5px; color: var(--text-dim); }
        .stat-val { font-size: 1.4rem; font-weight: 700; color: var(--accent); }

        ::-webkit-scrollbar { width: 6px; height: 6px; }
        ::-webkit-scrollbar-thumb { background: var(--glass-border); border-radius: 10px; }
        ::-webkit-scrollbar-thumb:hover { background: var(--text-dim); }
    </style>
</head>
<body>
    <div class="blob" style="top: -100px; left: -100px; background: radial-gradient(circle, rgba(99, 102, 241, 0.4) 0%, transparent 70%);"></div>
    <div class="blob" style="bottom: -150px; right: -150px; background: radial-gradient(circle, rgba(168, 85, 247, 0.3) 0%, transparent 70%);"></div>

    <div class="nav-rail">
        <div class="avatar"></div>
        <i class="fas fa-database nav-icon active"></i>
        <i class="fas fa-terminal nav-icon"></i>
        <i class="fas fa-history nav-icon"></i>
        <div style="flex: 1"></div>
        <i class="fas fa-cog nav-icon"></i>
    </div>

    <div class="sidebar">
        <div style="padding: 32px 24px 8px; font-weight: 800; font-size: 1.3rem; letter-spacing: -0.5px;">Nexus <span style="color:var(--accent)">SQL</span></div>
        <div class="search-area">
            <input type="text" class="search-input" id="table-search" placeholder="Search tables..." oninput="filterTables()">
        </div>
        <div class="table-list" id="tables-list"></div>
    </div>

        <div class="main">
        <div class="top-bar">
            <div style="font-size: 14px; font-weight: 500; display: flex; flex-direction: column; gap: 4px;">
                <div>Connection: <span id="db-status" style="color:var(--success)">Active</span></div>
                <div id="db-path" style="font-size: 11px; color: var(--text-dim); font-family: 'JetBrains Mono';">Unknown</div>
            </div>
            <div style="display: flex; gap: 12px;">
                <button class="btn" style="background:transparent;" onclick="exportData('csv')"><i class="fas fa-file-csv"></i> Export</button>
                <button class="btn btn-primary" onclick="runQuery()"><i class="fas fa-play"></i> Execute Query</button>
            </div>
        </div>

        <div class="editor-section">
            <div class="glass-card">
                <div style="display: flex; justify-content: space-between; align-items: center;">
                    <span style="font-weight: 600;">SQL Workbench</span>
                    <select id="row-limit" style="background:transparent; color:white; border:none; font-size: 12px; cursor:pointer;">
                        <option value="50">Limit 50</option>
                        <option value="100">Limit 100</option>
                        <option value="500">Limit 500</option>
                        <option value="999999">No Limit</option>
                    </select>
                </div>
                <textarea id="sql-editor"></textarea>
            </div>

            <div style="display: flex; flex-direction: column; gap: 16px;">
                <div class="glass-card stat-card">
                    <div class="stat-label">Execution Time</div>
                    <div class="stat-val" id="res-time">0 ms</div>
                </div>
                <div class="glass-card stat-card">
                    <div class="stat-label">Rows Loaded</div>
                    <div class="stat-val" id="res-count">0</div>
                </div>
                <div class="glass-card stat-card">
                    <div class="stat-label">Columns</div>
                    <div class="stat-val" id="res-cols">0</div>
                </div>
            </div>
        </div>

        <div class="results-section">
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
                <h2 style="font-weight: 700; font-size: 1.1rem;">Data Explorer</h2>
                <input type="text" id="result-filter" placeholder="Filter results..." style="background:rgba(255,255,255,0.05); border:1px solid var(--glass-border); border-radius: 10px; padding: 8px 16px; color: white;" oninput="filterResults()">
            </div>
            <div class="table-wrap" id="results-table-container">
                <div style="display:flex; flex-direction:column; align-items:center; justify-content:center; height:100%; opacity:0.3;">
                    <i class="fas fa-table" style="font-size: 3rem; margin-bottom: 16px;"></i>
                    <p>Execute a SQL query to see the magic</p>
                </div>
            </div>
        </div>
    </div>

    <script>
        let editor, allTables = [], currentResults = {}, metadata = {};

        document.addEventListener('DOMContentLoaded', async () => {
            initEditor();
            await loadAll();
        });

        async function loadAll() {
            const [tRes, mRes, iRes] = await Promise.all([
                fetch('/api/tables'), 
                fetch('/api/metadata'),
                fetch('/api/database/info')
            ]);
            allTables = await tRes.json();
            metadata = await mRes.json();
            const dbInfo = await iRes.json();

            document.getElementById('db-path').textContent = dbInfo.path;
            if (dbInfo.network_ip) {
                document.getElementById('db-status').innerHTML = `<i class="fas fa-network-wired"></i> http://\${dbInfo.network_ip}:\${dbInfo.port}`;
            }

            renderTables(allTables);
            if (editor) editor.setOption('hintOptions', { tables: metadata });
        }

        function initEditor() {
            editor = CodeMirror.fromTextArea(document.getElementById('sql-editor'), {
                mode: 'text/x-sql', theme: 'dracula', lineNumbers: true, matchBrackets: true,
                extraKeys: { 
                    "Ctrl-Space": "autocomplete",
                    "Ctrl-Enter": () => runQuery(),
                    "Cmd-Enter": () => runQuery()
                },
                hintOptions: { tables: metadata }
            });
            editor.setValue("SELECT * FROM sqlite_master;");

            // Auto-trigger hints on typing
            editor.on("inputRead", function(cm, change) {
                if (change.origin !== "+input") return;
                const str = change.text[0];
                if (/[a-zA-Z._]/.test(str)) {
                    cm.showHint({ completeSingle: false });
                }
            });
        }

        function renderTables(tables) {
            document.getElementById('tables-list').innerHTML = tables.map(t => `
                <div class="table-item" onclick="selectTable('\${t.name}')" id="table-\${t.name}">
                    <i class="fas fa-table" style="opacity:0.5;"></i>
                    <span style="flex:1;">\${t.name}</span>
                    <span style="font-size:10px; opacity:0.3;">\${t.rowCount}</span>
                </div>
            `).join('');
        }

        function filterTables() {
            const q = document.getElementById('table-search').value.toLowerCase();
            renderTables(allTables.filter(t => t.name.toLowerCase().includes(q)));
        }

        function selectTable(name) {
            const limit = document.getElementById('row-limit').value;
            editor.setValue(\`SELECT * FROM \${name} LIMIT \${limit};\`);
            runQuery();
            document.querySelectorAll('.table-item').forEach(i => i.classList.remove('active'));
            document.getElementById('table-' + name)?.classList.add('active');
        }

        async function runQuery() {
            const sql = editor.getSelection().trim() || editor.getValue().trim();
            if (!sql) return;

            document.getElementById('results-table-container').innerHTML = '<div style="display:flex;justify-content:center;align-items:center;height:100%;"><i class="fas fa-spinner fa-spin fa-2x"></i></div>';
            
            const start = performance.now();
            const res = await fetch('/api/query', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ sql })
            });
            currentResults = await res.json();
            const end = performance.now();

            document.getElementById('res-time').textContent = (currentResults.executionTime || Math.round(end-start)) + " ms";
            document.getElementById('res-count').textContent = currentResults.rowCount || 0;
            document.getElementById('res-cols').textContent = (currentResults.columns || []).length;
            
            renderResults();
        }

        function renderResults() {
            const container = document.getElementById('results-table-container');
            const res = currentResults;
            const filter = document.getElementById('result-filter').value.toLowerCase();

            if (res.error) { container.innerHTML = \`<div style="padding:40px; color:var(--error);"><i class="fas fa-exclamation-triangle"></i> \${res.error}</div>\`; return; }
            if (!res.data || res.data.length === 0) { container.innerHTML = '<div style="padding:40px; opacity:0.5;">No results found.</div>'; return; }

            const filteredData = res.data.filter(row => 
                Object.values(row).some(v => String(v).toLowerCase().includes(filter))
            );

            const keys = res.columns || Object.keys(res.data[0]);
            let html = '<table><thead><tr>' + keys.map(k => \`<th>\${k}</th>\`).join('') + '</tr></thead><tbody>';
            filteredData.forEach(row => {
                html += '<tr>' + keys.map(k => \`<td>\${row[k] ?? '<span style="opacity:0.2">NULL</span>'}</td>\`).join('') + '</tr>';
            });
            container.innerHTML = html + '</tbody></table>';
        }

        function filterResults() { renderResults(); }

        function exportData(type) {
            if (!currentResults.data) return;
            const keys = currentResults.columns || Object.keys(currentResults.data[0]);
            const csv = [keys.join(','), ...currentResults.data.map(r => keys.map(k => '"' + (r[k]||'').toString().replace(/"/g, '""') + '"').join(','))].join('\\n');
            const blob = new Blob([csv], { type: 'text/csv' });
            const link = document.createElement('a');
            link.href = URL.createObjectURL(blob);
            link.download = 'nexus_export.csv';
            link.click();
        }
    </script>
</body>
</html>
''';
}