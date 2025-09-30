import 'dart:io';
import 'dart:convert';
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

  WebServer(this.dbService, {this.port = 8080, this.enableWebSocket = true});

  Future<void> startServer() async {
    String? ipAddress = await _getLocalIPAddress();

    var router = Router();

    // Serve static files (for assets)
    var staticHandler = createStaticHandler('web_assets', defaultDocument: 'index.html');

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

    // WebSocket for real-time updates
    if (enableWebSocket) {
      router.get('/ws', webSocketHandler((WebSocketChannel webSocket) {
        webSocket.stream.listen((message) {
          _handleWebSocketMessage(webSocket, message);
        });
      }));
    }

    // Serve the main application
    router.get('/', (Request request) {
      return Response.ok(_htmlPage, headers: {'Content-Type': 'text/html'});
    });

    // Fallback to static handler
    router.all('/<ignored|.*>', (Request request) => staticHandler(request));

    var handler = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_corsMiddleware())
        .addMiddleware(_authMiddleware())
        .addHandler(router);

    _server = await io.serve(handler, InternetAddress.anyIPv4, port);
    
    print('\x1B[32m🚀 SQLite Pro Server started!\x1B[0m');
    print('\x1B[36m📍 Local: http://localhost:$port\x1B[0m');
    if (ipAddress != null) {
      print('\x1B[36m🌐 Network: http://$ipAddress:$port\x1B[0m');
    }
    print('\x1B[33m⚡ Press Ctrl+C to stop the server\x1B[0m');
  }

  // CORS middleware
  Middleware _corsMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        final response = await handler(request);
        return response.change(headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
        });
      };
    };
  }

  // Basic auth middleware (optional)
  Middleware _authMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        // Add authentication logic here if needed
        return handler(request);
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
        tablesWithInfo.add({
          'name': table,
          'rowCount': count,
          'type': 'table'
        });
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
      return Response.badRequest(body: 'SQL query is required');
    }

    try {
      final stopwatch = Stopwatch()..start();
      var data = await dbService.query(sql);
      stopwatch.stop();

      // Log query for history
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
      var body = await request.readAsString();
      var data = jsonDecode(body) as Map<String, dynamic>;
      
      var result = await dbService.insert(table, data);
      return _jsonResponse({'success': true, 'insertedId': result});
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _updateData(Request request) async {
    try {
      var table = request.params['table']!;
      var body = await request.readAsString();
      var data = jsonDecode(body) as Map<String, dynamic>;
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
      
      switch (format) {
        case 'csv':
          return _csvResponse(_convertToCsv(data), table);
        case 'json':
        default:
          return _jsonResponse(data);
      }
    } catch (e) {
      return _errorResponse(e.toString());
    }
  }

  Future<Response> _getQueryHistory(Request request) async {
    return _jsonResponse(_queryHistory.reversed.toList());
  }

  // WebSocket handling
  void _handleWebSocketMessage(WebSocketChannel webSocket, dynamic message) {
    try {
      var json = jsonDecode(message);
      var action = json['action'];
      
      switch (action) {
        case 'subscribe_tables':
          // Send table updates periodically
          _sendTableUpdates(webSocket);
          break;
        case 'execute_query':
          var sql = json['sql'];
          _executeQueryAndSend(webSocket, sql);
          break;
      }
    } catch (e) {
      webSocket.sink.add(jsonEncode({'error': e.toString()}));
    }
  }

  void _sendTableUpdates(WebSocketChannel webSocket) async {
    // Implementation for real-time table updates
  }

  void _executeQueryAndSend(WebSocketChannel webSocket, String sql) async {
    try {
      var data = await dbService.query(sql);
      webSocket.sink.add(jsonEncode({
        'type': 'query_result',
        'data': data,
        'rowCount': data.length
      }));
    } catch (e) {
      webSocket.sink.add(jsonEncode({'error': e.toString()}));
    }
  }

  // Utility methods
  Response _jsonResponse(dynamic data) {
    return Response.ok(
      jsonEncode(data),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Response _errorResponse(String error) {
    return Response.internalServerError(
      body: jsonEncode({'error': error, 'success': false}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Response _csvResponse(String csvData, String tableName) {
    return Response.ok(
      csvData,
      headers: {
        'Content-Type': 'text/csv',
        'Content-Disposition': 'attachment; filename="$tableName.csv"'
      },
    );
  }

  String _convertToCsv(List<Map<String, dynamic>> data) {
    if (data.isEmpty) return '';
    
    var headers = data[0].keys;
    var csv = StringBuffer();
    
    // Write headers
    csv.writeln(headers.join(','));
    
    // Write data
    for (var row in data) {
      var values = headers.map((header) {
        var value = row[header];
        if (value == null) return '';
        var stringValue = value.toString();
        // Escape commas and quotes
        if (stringValue.contains(',') || stringValue.contains('"')) {
          stringValue = '"${stringValue.replaceAll('"', '""')}"';
        }
        return stringValue;
      });
      csv.writeln(values.join(','));
    }
    
    return csv.toString();
  }

  // Query history management
  final List<Map<String, dynamic>> _queryHistory = [];
  static const int _maxHistorySize = 100;

  void _addToQueryHistory(String sql, int rowCount, int executionTime) {
    _queryHistory.add({
      'sql': sql,
      'rowCount': rowCount,
      'executionTime': executionTime,
      'timestamp': DateTime.now().toIso8601String(),
    });
    
    if (_queryHistory.length > _maxHistorySize) {
      _queryHistory.removeAt(0);
    }
  }

  Future<void> stopServer() async {
    await _server?.close();
    print('\x1B[31m🛑 Server stopped\x1B[0m');
  }

  Future<String?> _getLocalIPAddress() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            // Prefer wlan0 for WiFi, but fall back to any non-loopback
            if (interface.name == 'wlan0') {
              return addr.address;
            }
          }
        }
      }
      // Fallback: get any non-loopback IPv4
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      print('Error getting IP address: $e');
    }
    return null;
  }

  // Enhanced HTML page with modern features
  static const String _htmlPage = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SQLite Pro - Advanced Database Manager</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        /* Add the enhanced CSS from the previous beautiful version here */
        :root {
            --primary: #2563eb;
            --primary-dark: #1d4ed8;
            --secondary: #64748b;
            --success: #10b981;
            --warning: #f59e0b;
            --danger: #ef4444;
            --dark: #1e293b;
            --light: #f8fafc;
            --sidebar-width: 280px;
            --header-height: 60px;
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            color: var(--dark);
        }

        .app-container {
            display: flex;
            min-height: 100vh;
        }
    h1 { color: #2c3e50; }
    .container {
      padding: 20px;
      background-color: #fff;
      border-radius: 8px;
      box-shadow: 0 0 10px rgba(0, 0, 0, 0.1);
    }
    textarea, select {
      width: 100%;
      padding: 10px;
      font-size: 16px;
      margin: 10px 0;
      border-radius: 5px;
      border: 1px solid #ccc;
    }
    textarea {
      min-height: 100px; /* Adjust this value as needed */
      resize: vertical; /* Allows user to resize the textarea */
    }
    button {
      padding: 10px;
      background-color: #3498db;
      color: white;
      border: none;
      border-radius: 5px;
      cursor: pointer;
    }
    button:hover { background-color: #2980b9; }
    .loading {
      display: none;
      color: #3498db;
      font-style: italic;
    }
    .error {
      color: #e74c3c;
      font-weight: bold;
    }
html, body {
  height: 100%;
  margin: 0;
  display: flex;
  flex-direction: column;
}

.container {
  flex: 1;
  display: flex;
  flex-direction: column;
  height: 100%;
}

#output {
  flex: 1;
  display: flex;
  flex-direction: column;
}

.table-wrapper {
  flex: 1;
  overflow-y: auto; /* Enables vertical scrolling */
  overflow-x: auto; /* Enables horizontal scrolling */
  border: 1px solid #ddd;
  max-height: calc(100vh - 250px); /* Adjust based on header size */
}

table {
  width: 100%;
  border-collapse: collapse;
  white-space: nowrap; /* Prevents text wrapping */
}

th, td {
  border: 1px solid #ddd;
  padding: 8px;
  text-align: left;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

th {
  position: sticky;
  top: 0;
  background-color: #3498db;
  color: white;
  z-index: 2;
}

tr:hover {
  background-color: #f1f1f1;
}

.selected {
  background-color: #f9eb3b !important;
}

td:hover {
  overflow: visible;
  white-space: normal;
  word-wrap: break-word;
}

td[title] {
  cursor: help;
}

  </style>
</head>
<body>
    <div class="app-container">
        <!-- Sidebar -->
        <div class="sidebar">
            <div class="sidebar-header">
                <h2><i class="fas fa-database"></i> SQLite Pro</h2>
            </div>
            
            <div class="database-info">
                <div><strong>Database:</strong> <span id="db-name">Loading...</span></div>
                <div><strong>Version:</strong> <span id="db-version">-</span></div>
                <div><strong>Size:</strong> <span id="db-size">-</span></div>
            </div>
            
            <div class="tables-list">
                <h3>Tables</h3>
                <div id="tables-container">
                    <div class="loading">Loading tables...</div>
                </div>
            </div>
        </div>

        <!-- Main Content -->
        <div class="main-content">
            <!-- Header -->
            <div class="header">
                <h1>Database Browser</h1>
                <div class="header-actions">
                    <button class="btn btn-outline" onclick="exportData()">
                        <i class="fas fa-download"></i> Export
                    </button>
                    <button class="btn btn-primary" onclick="runQuery()">
                        <i class="fas fa-play"></i> Run Query
                    </button>
                </div>
            </div>

            <!-- Query Section -->
            <div class="query-section">
                <div class="query-toolbar">
                    <button class="btn btn-outline" onclick="insertTemplate('SELECT')">
                        SELECT
                    </button>
                    <button class="btn btn-outline" onclick="insertTemplate('INSERT')">
                        INSERT
                    </button>
                    <button class="btn btn-outline" onclick="insertTemplate('UPDATE')">
                        UPDATE
                    </button>
                    <button class="btn btn-outline" onclick="insertTemplate('DELETE')">
                        DELETE
                    </button>
                    <button class="btn btn-outline" onclick="showQueryHistory()">
                        <i class="fas fa-history"></i> History
                    </button>
                </div>
                
                <div class="query-input-container">
                    <textarea id="query" class="query-input" placeholder="Write your SQL query here... 
Example: SELECT * FROM users WHERE age > 25 ORDER BY name"></textarea>
                </div>
                
                <div class="query-actions">
                    <button class="btn btn-success" onclick="runQuery()">
                        <i class="fas fa-play"></i> Execute Query
                    </button>
                    <button class="btn btn-outline" onclick="clearQuery()">
                        <i class="fas fa-eraser"></i> Clear
                    </button>
                    <button class="btn btn-outline" onclick="formatQuery()">
                        <i class="fas fa-indent"></i> Format
                    </button>
                    <button class="btn btn-outline" onclick="explainQuery()">
                        <i class="fas fa-search"></i> Explain
                    </button>
                </div>
            </div>

            <!-- Results Section -->
            <div class="results-section">
                <div class="tabs">
                    <div class="tab active" onclick="switchTab('results')">Results</div>
                    <div class="tab" onclick="switchTab('schema')">Schema</div>
                    <div class="tab" onclick="switchTab('json')">JSON View</div>
                    <div class="tab" onclick="switchTab('charts')">Charts</div>
                </div>

                <div id="loading" class="loading" style="display: none;">
                    <div class="spinner"></div>
                    <p>Executing query...</p>
                </div>

                <div id="error" class="error-message" style="display: none;"></div>

                <div class="tab-content active" id="results-tab">
                    <div class="results-header">
                        <h3>Query Results</h3>
                        <div class="results-stats">
                            <div class="stat-item">
                                <i class="fas fa-table"></i>
                                <span id="rowCount">0</span> rows
                            </div>
                            <div class="stat-item">
                                <i class="fas fa-clock"></i>
                                <span id="queryTime">0</span> ms
                            </div>
                            <div class="stat-item">
                                <i class="fas fa-columns"></i>
                                <span id="columnCount">0</span> columns
                            </div>
                        </div>
                    </div>
                    <div id="output"></div>
                </div>

                <div class="tab-content" id="schema-tab">
                    <h3>Table Schema</h3>
                    <div id="schema-output"></div>
                </div>

                <div class="tab-content" id="json-tab">
                    <h3>JSON Data</h3>
                    <div id="json-output"></div>
                </div>

                <div class="tab-content" id="charts-tab">
                    <h3>Data Visualization</h3>
                    <div id="charts-output">
                        <p>Select numeric columns to visualize data</p>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Query History Modal -->
    <div id="historyModal" class="modal" style="display: none;">
        <div class="modal-content">
            <span class="close" onclick="closeHistoryModal()">&times;</span>
            <h3>Query History</h3>
            <div id="history-list"></div>
        </div>
    </div>

    <script>
        // Enhanced JavaScript with all the features from the beautiful version
        // Plus additional API integrations
        
        let currentTable = null;
        let queryHistory = [];

        // Initialize the application
        document.addEventListener('DOMContentLoaded', function() {
            loadDatabaseInfo();
            loadTables();
            loadQueryHistory();
            document.getElementById('query').focus();
            
            // Connect to WebSocket if enabled
            connectWebSocket();
        });

        async function loadDatabaseInfo() {
            try {
                const response = await fetch('/api/database/info');
                const info = await response.json();
                
                document.getElementById('db-name').textContent = info.name || 'app.db';
                document.getElementById('db-version').textContent = info.version || '3.37.0';
                document.getElementById('db-size').textContent = info.size || 'Calculating...';
            } catch (error) {
                console.error('Failed to load database info:', error);
            }
        }

        async function loadTables() {
            try {
                const response = await fetch('/api/tables');
                const tables = await response.json();
                const tablesContainer = document.getElementById('tables-container');
                
                tablesContainer.innerHTML = '';
                tables.forEach(table => {
                    const tableItem = document.createElement('div');
                    tableItem.className = 'table-item';
                    tableItem.innerHTML = `
                        <div>
                            <strong>${table.name}</strong>
                            <div class="table-stats">${table.rowCount} rows</div>
                        </div>
                    `;
                    tableItem.onclick = () => selectTable(table.name);
                    tablesContainer.appendChild(tableItem);
                });
            } catch (error) {
                console.error('Failed to load tables:', error);
                document.getElementById('tables-container').innerHTML = 
                    '<div class="error-message">Failed to load tables</div>';
            }
        }

        async function selectTable(tableName) {
            currentTable = tableName;
            document.getElementById('query').value = `SELECT * FROM ${tableName} LIMIT 100`;
            runQuery();
            
            // Update active table in sidebar
            document.querySelectorAll('.table-item').forEach(item => {
                item.classList.remove('active');
            });
            event.currentTarget.classList.add('active');
            
            // Load schema
            loadSchema(tableName);
        }

        async function loadSchema(tableName) {
            try {
                const response = await fetch(`/api/tables/${tableName}/schema`);
                const schema = await response.json();
                displaySchema(schema);
            } catch (error) {
                console.error('Failed to load schema:', error);
            }
        }

        function displaySchema(schema) {
            let schemaHtml = '<div class="table-container"><table><thead><tr><th>Column</th><th>Type</th><th>Nullable</th><th>Primary Key</th></tr></thead><tbody>';
            
            schema.forEach(column => {
                schemaHtml += `<tr>
                    <td><strong>${column.name}</strong></td>
                    <td>${column.type}</td>
                    <td>${column.nullable ? 'YES' : 'NO'}</td>
                    <td>${column.primaryKey ? 'YES' : 'NO'}</td>
                </tr>`;
            });
            
            schemaHtml += '</tbody></table></div>';
            document.getElementById('schema-output').innerHTML = schemaHtml;
        }

        async function runQuery() {
            const query = document.getElementById('query').value.trim();
            if (!query) return;

            const startTime = performance.now();
            
            // Show loading
            document.getElementById('loading').style.display = 'flex';
            document.getElementById('error').style.display = 'none';
            document.getElementById('output').innerHTML = '';

            try {
                const response = await fetch('/api/query', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                    },
                    body: JSON.stringify({ sql: query })
                });

                const result = await response.json();
                const endTime = performance.now();
                const executionTime = Math.round(endTime - startTime);

                document.getElementById('loading').style.display = 'none';

                if (result.error) {
                    document.getElementById('error').style.display = 'block';
                    document.getElementById('error').textContent = `Error: ${result.error}`;
                    return;
                }

                document.getElementById('rowCount').textContent = result.rowCount;
                document.getElementById('queryTime').textContent = result.executionTime || executionTime;
                document.getElementById('columnCount').textContent = result.columns ? result.columns.length : 0;
                
                displayTable(result.data);
                displayJson(result.data);
                updateQueryHistory(query, result.rowCount, executionTime);
                
                switchTab('results');
            } catch (error) {
                document.getElementById('loading').style.display = 'none';
                document.getElementById('error').style.display = 'block';
                document.getElementById('error').textContent = `Network Error: ${error.message}`;
            }
        }

        // Include all the other JavaScript functions from the beautiful version
        // displayTable, displayJson, switchTab, insertTemplate, clearQuery, formatQuery, etc.

        async function loadQueryHistory() {
            try {
                const response = await fetch('/api/history');
                queryHistory = await response.json();
            } catch (error) {
                console.error('Failed to load query history:', error);
            }
        }

        function updateQueryHistory(sql, rowCount, executionTime) {
            queryHistory.unshift({
                sql: sql,
                rowCount: rowCount,
                executionTime: executionTime,
                timestamp: new Date().toISOString()
            });
            
            // Keep only last 50 queries in memory
            if (queryHistory.length > 50) {
                queryHistory.pop();
            }
        }

        function showQueryHistory() {
            const modal = document.getElementById('historyModal');
            const historyList = document.getElementById('history-list');
            
            historyList.innerHTML = queryHistory.map((query, index) => `
                <div class="history-item" onclick="useHistoryQuery('${query.sql.replace(/'/g, "\\'")}')">
                    <div class="history-sql">${query.sql}</div>
                    <div class="history-meta">
                        ${query.rowCount} rows • ${query.executionTime}ms • 
                        ${new Date(query.timestamp).toLocaleString()}
                    </div>
                </div>
            `).join('');
            
            modal.style.display = 'block';
        }

        function closeHistoryModal() {
            document.getElementById('historyModal').style.display = 'none';
        }

        function useHistoryQuery(sql) {
            document.getElementById('query').value = sql;
            closeHistoryModal();
        }

        function connectWebSocket() {
            try {
                const ws = new WebSocket('ws://' + window.location.host + '/ws');
                
                ws.onopen = function() {
                    console.log('WebSocket connected');
                    // Subscribe to table updates
                    ws.send(JSON.stringify({ action: 'subscribe_tables' }));
                };
                
                ws.onmessage = function(event) {
                    const data = JSON.parse(event.data);
                    // Handle real-time updates
                    if (data.type === 'table_update') {
                        // Refresh current table if it matches
                        if (currentTable && data.table === currentTable) {
                            loadTables(); // Refresh table list
                            if (document.getElementById('query').value.includes(`FROM ${currentTable}`)) {
                                runQuery(); // Refresh current query
                            }
                        }
                    }
                };
                
                ws.onclose = function() {
                    console.log('WebSocket disconnected');
                    // Attempt to reconnect after 5 seconds
                    setTimeout(connectWebSocket, 5000);
                };
            } catch (error) {
                console.log('WebSocket not available');
            }
        }

        async function explainQuery() {
            const query = document.getElementById('query').value.trim();
            if (!query.toLowerCase().startsWith('select')) {
                alert('EXPLAIN only works with SELECT queries');
                return;
            }
            
            const explainQuery = 'EXPLAIN QUERY PLAN ' + query;
            document.getElementById('query').value = explainQuery;
            runQuery();
        }

        async function exportData() {
            if (!currentTable) {
                alert('Please select a table first');
                return;
            }
            
            const format = prompt('Export format (json/csv):', 'json');
            if (!format) return;
            
            window.open(`/api/export/${currentTable}?format=${format}`, '_blank');
        }

        // Add all other utility functions from the beautiful version...
    </script>
</body>
</html>
''';
}
