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

      // Check if port is available
      if (await _isPortInUse(port)) {
        print('🚨 Port $port is already in use. Trying port ${port + 1}');
        return await startServerWithPort(port + 1);
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

      // WebSocket for real-time updates
      if (enableWebSocket) {
        router.get('/ws', webSocketHandler((WebSocketChannel webSocket) {
          webSocket.stream.listen(
            (message) => _handleWebSocketMessage(webSocket, message),
            onError: (error) => print('WebSocket error: $error'),
            onDone: () => print('WebSocket disconnected'),
          );
        }));
      }

      // Serve the main application
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
      } else {
        print('\x1B[33m⚠️  Could not detect network IP address\x1B[0m');
      }
      print('\x1B[33m⚡ Press Ctrl+C to stop the server\x11B[0m');
      
      return true;
    } catch (e, stackTrace) {
      print('\x1B[31m🚨 Failed to start server: $e\x1B[0m');
      print('\x1B[31mStack trace: $stackTrace\x1B[0m');
      
      // Try alternative port
      if (e.toString().contains('bind') || e.toString().contains('port')) {
        print('\x1B[33m🔄 Trying alternative port...\x1B[0m');
        return await startServerWithPort(port + 1);
      }
      
      return false;
    }
  }

  Future<bool> startServerWithPort(int newPort) async {
    try {
      await stopServer();
      var newServer = WebServer(dbService, port: newPort, enableWebSocket: enableWebSocket);
      return await newServer.startServer();
    } catch (e) {
      print('\x1B[31m🚨 Failed to start server on port $newPort: $e\x1B[0m');
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
  // CORS middleware
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
      return Response.badRequest(body: jsonEncode({'error': 'SQL query is required'}));
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
    try {
      final tables = await dbService.getTables();
      webSocket.sink.add(jsonEncode({
        'type': 'tables_updated',
        'tables': tables,
        'timestamp': DateTime.now().toIso8601String()
      }));
    } catch (e) {
      webSocket.sink.add(jsonEncode({'error': e.toString()}));
    }
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
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _isRunning = false;
      print('\x1B[31m🛑 Server stopped\x1B[0m');
    }
  }

  Future<String?> _getLocalIPAddress() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback && interface.name == 'wlan0') {
            // Return the first non-loopback IPv4 address
            return addr.address;
          }
        }
      }
    } catch (e) {
      print('Warning: Could not get local IP address: $e');
    }
    return null;
  }

  bool get isRunning => _isRunning;

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

        /* Sidebar */
        .sidebar {
            width: var(--sidebar-width);
            background: var(--dark);
            color: white;
            padding: 20px 0;
            display: flex;
            flex-direction: column;
        }

        .sidebar-header {
            padding: 0 20px 20px;
            border-bottom: 1px solid #334155;
            text-align: center;
        }

        .powered-by {
            font-size: 0.7rem;
            color: #94a3b8;
            margin-top: 5px;
            font-style: italic;
        }

        .sidebar-header h2 {
            display: flex;
            align-items: center;
            gap: 10px;
            font-size: 1.3rem;
            justify-content: center;
        }

        .database-info {
            background: rgba(255, 255, 255, 0.1);
            padding: 15px;
            border-radius: 8px;
            margin: 15px 20px;
            font-size: 0.9rem;
        }

        .tables-list {
            padding: 0 20px;
            flex: 1;
            display: flex;
            flex-direction: column;
        }

        .tables-list h3 {
            margin: 0 0 10px 0;
            font-size: 1rem;
            color: #94a3b8;
        }

        /* Search styles */
        .search-container {
            position: relative;
            margin-bottom: 10px;
        }

        .search-input {
            width: 100%;
            padding: 8px 30px 8px 10px;
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid #475569;
            border-radius: 4px;
            color: white;
            font-size: 0.9rem;
        }

        .search-input::placeholder {
            color: #94a3b8;
        }

        .search-input:focus {
            outline: none;
            border-color: var(--primary);
            background: rgba(255, 255, 255, 0.15);
        }

        .search-icon {
            position: absolute;
            right: 10px;
            top: 50%;
            transform: translateY(-50%);
            color: #94a3b8;
            font-size: 0.9rem;
        }

        .tables-container {
            flex: 1;
            overflow-y: auto;
            border: 1px solid #334155;
            border-radius: 6px;
            margin-bottom: 10px;
            max-height: 400px;
        }

        /* Scrollbar styling */
        .tables-container::-webkit-scrollbar {
            width: 6px;
        }

        .tables-container::-webkit-scrollbar-track {
            background: rgba(255, 255, 255, 0.1);
            border-radius: 3px;
        }

        .tables-container::-webkit-scrollbar-thumb {
            background: var(--primary);
            border-radius: 3px;
        }

        .tables-container::-webkit-scrollbar-thumb:hover {
            background: var(--primary-dark);
        }

        .table-item {
            padding: 12px 15px;
            margin: 0;
            background: rgba(255, 255, 255, 0.05);
            cursor: pointer;
            transition: all 0.2s;
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid #334155;
        }

        .table-item:last-child {
            border-bottom: none;
        }

        .table-item:hover {
            background: rgba(255, 255, 255, 0.1);
        }

        .table-item.active {
            background: var(--primary);
        }

        .table-stats {
            font-size: 0.8rem;
            color: #94a3b8;
        }

        .table-count {
            padding: 5px 0;
            font-size: 0.8rem;
            color: #94a3b8;
            text-align: center;
            border-top: 1px solid #334155;
        }

        /* Main Content */
        .main-content {
            flex: 1;
            background: var(--light);
            display: flex;
            flex-direction: column;
            overflow: hidden; /* Prevent main content from expanding */
        }

        .header {
            height: var(--header-height);
            background: white;
            padding: 0 30px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            box-shadow: 0 2px 10px rgba(0, 0, 0, 0.1);
            flex-shrink: 0; /* Prevent header from expanding */
        }

        .header-actions {
            display: flex;
            gap: 15px;
        }

        .btn {
            padding: 8px 16px;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-weight: 500;
            transition: all 0.2s;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .btn-primary {
            background: var(--primary);
            color: white;
        }

        .btn-primary:hover {
            background: var(--primary-dark);
        }

        .btn-outline {
            background: transparent;
            border: 1px solid var(--secondary);
            color: var(--secondary);
        }

        .btn-outline:hover {
            background: var(--secondary);
            color: white;
        }

        /* Query Section */
        .query-section {
            padding: 25px 30px;
            background: white;
            border-bottom: 1px solid #e2e8f0;
            flex-shrink: 0; /* Prevent query section from expanding */
        }

        .query-toolbar {
            display: flex;
            gap: 10px;
            margin-bottom: 15px;
            flex-wrap: wrap;
        }

        .query-input {
            width: 100%;
            padding: 15px;
            border: 1px solid #cbd5e1;
            border-radius: 8px;
            font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
            font-size: 14px;
            resize: vertical;
            min-height: 100px;
            background: #f8fafc;
        }

        .query-input:focus {
            outline: none;
            border-color: var(--primary);
            box-shadow: 0 0 0 3px rgba(37, 99, 235, 0.1);
        }

        .query-actions {
            display: flex;
            gap: 10px;
            margin-top: 15px;
            flex-wrap: wrap;
        }

        /* Results Section */
        .results-section {
            flex: 1;
            padding: 25px 30px;
            overflow: auto;
            display: flex;
            flex-direction: column;
        }

        .results-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
            flex-wrap: wrap;
            gap: 15px;
            flex-shrink: 0; /* Prevent results header from expanding */
        }

        .results-stats {
            display: flex;
            gap: 20px;
            color: var(--secondary);
            flex-wrap: wrap;
        }

        .stat-item {
            display: flex;
            align-items: center;
            gap: 5px;
            white-space: nowrap; /* Prevent stats from wrapping */
        }

        /* Table Container - FIXED FOR HORIZONTAL SCROLLING */
        .table-wrapper {
            flex: 1;
            display: flex;
            flex-direction: column;
            min-height: 0; /* Important for flex child scrolling */
        }

        .table-container {
            background: white;
            border-radius: 8px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.05);
            margin-bottom: 20px;
            overflow: hidden; /* Contain the table and scrollbar */
            display: flex;
            flex-direction: column;
            flex: 1;
            min-height: 0; /* Important for flex child scrolling */
        }

        .table-scroll-container {
            overflow-x: auto;
            overflow-y: auto;
            flex: 1;
            min-height: 0; /* Important for flex child scrolling */
        }

        table {
            width: 100%;
            border-collapse: collapse;
            min-width: 100%; /* Ensure table takes full width of container */
        }

        th {
            background: #f1f5f9;
            padding: 15px 12px;
            text-align: left;
            font-weight: 600;
            color: var(--dark);
            border-bottom: 1px solid #e2e8f0;
            position: sticky;
            top: 0;
            white-space: nowrap; /* Prevent header text from wrapping */
        }

        td {
            padding: 12px;
            border-bottom: 1px solid #f1f5f9;
            max-width: 300px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        tr:hover {
            background: #f8fafc;
        }

        .null-value {
            color: #94a3b8;
            font-style: italic;
        }

        .number-cell {
            text-align: right;
            font-family: 'Monaco', 'Menlo', monospace;
        }

        .boolean-cell {
            text-align: center;
        }

        .boolean-true {
            color: var(--success);
        }

        .boolean-false {
            color: var(--danger);
        }

        /* Pagination Styles - FIXED WIDTH */
        .pagination {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 15px 20px;
            background: #f8fafc;
            border-top: 1px solid #e2e8f0;
            flex-wrap: wrap;
            gap: 10px;
            flex-shrink: 0; /* Prevent pagination from expanding */
            width: 100%; /* Ensure pagination stays within container */
            box-sizing: border-box;
        }

        .pagination-info {
            font-size: 0.9rem;
            color: var(--secondary);
            white-space: nowrap; /* Prevent pagination info from wrapping */
        }

        .pagination-controls {
            display: flex;
            align-items: center;
            gap: 10px;
            flex-wrap: wrap;
        }

        .pagination-btn {
            padding: 8px 12px;
            border: 1px solid #cbd5e1;
            background: white;
            border-radius: 4px;
            cursor: pointer;
            transition: all 0.2s;
            font-size: 0.9rem;
            flex-shrink: 0; /* Prevent buttons from shrinking */
        }

        .pagination-btn:hover:not(:disabled) {
            background: var(--primary);
            color: white;
            border-color: var(--primary);
        }

        .pagination-btn:disabled {
            background: #f1f5f9;
            color: #94a3b8;
            cursor: not-allowed;
        }

        .pagination-pages {
            display: flex;
            gap: 5px;
            align-items: center;
            flex-wrap: wrap;
        }

        .page-btn {
            padding: 6px 10px;
            border: 1px solid #cbd5e1;
            background: white;
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.8rem;
            min-width: 35px;
            text-align: center;
            flex-shrink: 0; /* Prevent page buttons from shrinking */
        }

        .page-btn.active {
            background: var(--primary);
            color: white;
            border-color: var(--primary);
        }

        .page-btn:hover:not(.active) {
            background: #f1f5f9;
        }

        .page-input {
            width: 60px;
            padding: 6px 8px;
            border: 1px solid #cbd5e1;
            border-radius: 4px;
            text-align: center;
            font-size: 0.9rem;
            flex-shrink: 0;
        }

        .page-size-select {
            padding: 6px 8px;
            border: 1px solid #cbd5e1;
            border-radius: 4px;
            background: white;
            font-size: 0.9rem;
            flex-shrink: 0;
        }

        .pagination-settings {
            display: flex;
            align-items: center;
            gap: 10px;
            flex-wrap: wrap;
        }

        /* JSON Viewer */
        .json-viewer {
            background: #1e293b;
            color: #e2e8f0;
            padding: 15px;
            border-radius: 6px;
            font-family: 'Monaco', 'Menlo', monospace;
            font-size: 13px;
            overflow-x: auto;
            white-space: pre-wrap;
        }

        /* Tabs */
        .tabs {
            display: flex;
            border-bottom: 1px solid #e2e8f0;
            margin-bottom: 20px;
            flex-wrap: wrap;
            flex-shrink: 0; /* Prevent tabs from expanding */
        }

        .tab {
            padding: 12px 24px;
            cursor: pointer;
            border-bottom: 2px solid transparent;
            transition: all 0.2s;
            flex-shrink: 0; /* Prevent tabs from shrinking */
        }

        .tab.active {
            border-bottom-color: var(--primary);
            color: var(--primary);
            font-weight: 500;
        }

        .tab-content {
            display: none;
            flex: 1;
            min-height: 0; /* Important for flex child scrolling */
        }

        .tab-content.active {
            display: flex;
            flex-direction: column;
        }

        /* Loading and Error States */
        .loading {
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            padding: 40px;
            color: var(--secondary);
            flex-shrink: 0;
        }

        .spinner {
            width: 40px;
            height: 40px;
            border: 4px solid #e2e8f0;
            border-left: 4px solid var(--primary);
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin-bottom: 15px;
        }

        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }

        .error-message {
            background: #fef2f2;
            border: 1px solid #fecaca;
            color: var(--danger);
            padding: 15px;
            border-radius: 6px;
            margin: 15px 0;
            flex-shrink: 0;
        }

        .success-message {
            background: #f0fdf4;
            border: 1px solid #bbf7d0;
            color: var(--success);
            padding: 15px;
            border-radius: 6px;
            margin: 15px 0;
            flex-shrink: 0;
        }

        /* Modal */
        .modal {
            display: none;
            position: fixed;
            z-index: 1000;
            left: 0;
            top: 0;
            width: 100%;
            height: 100%;
            background-color: rgba(0,0,0,0.5);
        }

        .modal-content {
            background-color: white;
            margin: 5% auto;
            padding: 20px;
            border-radius: 8px;
            width: 80%;
            max-width: 800px;
            max-height: 80vh;
            overflow-y: auto;
        }

        .close {
            color: #aaa;
            float: right;
            font-size: 28px;
            font-weight: bold;
            cursor: pointer;
        }

        .history-item {
            padding: 15px;
            border: 1px solid #e2e8f0;
            border-radius: 6px;
            margin-bottom: 10px;
            cursor: pointer;
        }

        .history-item:hover {
            background: #f8fafc;
        }

        .history-sql {
            font-family: 'Monaco', 'Menlo', monospace;
            margin-bottom: 5px;
        }

        .history-meta {
            font-size: 0.8rem;
            color: var(--secondary);
        }

        /* Responsive Design */
        @media (max-width: 768px) {
            .app-container {
                flex-direction: column;
            }
            
            .sidebar {
                width: 100%;
                height: auto;
                max-height: 40vh;
            }
            
            .tables-container {
                max-height: 200px;
            }
            
            .header {
                padding: 0 15px;
            }
            
            .query-section, .results-section {
                padding: 15px;
            }
            
            .query-toolbar, .query-actions {
                justify-content: center;
            }
            
            .results-header {
                flex-direction: column;
                align-items: flex-start;
            }
            
            .results-stats {
                justify-content: flex-start;
            }
            
            .pagination {
                flex-direction: column;
                gap: 15px;
            }
            
            .pagination-controls {
                flex-wrap: wrap;
                justify-content: center;
            }
        }

        /* No results state */
        .no-tables {
            padding: 20px;
            text-align: center;
            color: #94a3b8;
            font-style: italic;
        }

        .no-results {
            padding: 20px;
            text-align: center;
            color: var(--secondary);
            font-style: italic;
        }
    </style>
</head>
<body>
    <div class="app-container">
        <!-- Sidebar -->
        <div class="sidebar">
            <div class="sidebar-header">
                <h2><i class="fas fa-database"></i> SQLite Pro</h2>
                <div class="powered-by">Powered by JJ Automation Solutions (Jay Fuego)</div>
            </div>
            
            <div class="database-info">
                <div><strong>Database:</strong> <span id="db-name">Loading...</span></div>
                <div><strong>Version:</strong> <span id="db-version">-</span></div>
                <div><strong>Size:</strong> <span id="db-size">-</span></div>
            </div>
            
            <div class="tables-list">
                <h3>Tables</h3>
                
                <!-- Search input -->
                <div class="search-container">
                    <input type="text" id="tableSearch" placeholder="Search tables..." 
                           class="search-input" oninput="filterTables()">
                    <i class="fas fa-search search-icon"></i>
                </div>
                
                <div class="tables-container" id="tables-container">
                    <div class="loading">Loading tables...</div>
                </div>
                
                <!-- Table count -->
                <div class="table-count" id="tableCount">
                    <span>0 tables</span>
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
                    <div class="tab active" onclick="switchTab('results', this)">Results</div>
                    <div class="tab" onclick="switchTab('schema', this)">Schema</div>
                    <div class="tab" onclick="switchTab('json', this)">JSON View</div>
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
                    <div class="table-wrapper">
                        <div class="table-container">
                            <div class="table-scroll-container" id="output">
                                <!-- Table content will be inserted here by JavaScript -->
                            </div>
                        </div>
                    </div>
                    <!-- Pagination will be inserted here by JavaScript -->
                </div>

                <div class="tab-content" id="schema-tab">
                    <h3>Table Schema</h3>
                    <div class="table-wrapper">
                        <div class="table-container">
                            <div class="table-scroll-container" id="schema-output">
                                <!-- Schema content will be inserted here by JavaScript -->
                            </div>
                        </div>
                    </div>
                </div>

                <div class="tab-content" id="json-tab">
                    <h3>JSON Data</h3>
                    <div id="json-output"></div>
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
        let currentTable = null;
        let queryHistory = [];
        let allTables = [];
        
        // Pagination state
        let currentPage = 1;
        let pageSize = 50;
        let totalRows = 0;
        let currentData = [];

        // Initialize the application
        document.addEventListener('DOMContentLoaded', function() {
            loadDatabaseInfo();
            loadTables();
            loadQueryHistory();
            document.getElementById('query').focus();
        });

        async function loadDatabaseInfo() {
            try {
                const response = await fetch('/api/database/info');
                const info = await response.json();
                
                document.getElementById('db-name').textContent = info.name || 'app.db';
                document.getElementById('db-version').textContent = info.sqliteVersion || '3.37.0';
                document.getElementById('db-size').textContent = info.sizeFormatted || 'Calculating...';
            } catch (error) {
                console.error('Failed to load database info:', error);
            }
        }

        async function loadTables() {
            try {
                const response = await fetch('/api/tables');
                allTables = await response.json();
                renderTables(allTables);
                updateTableCount(allTables.length);
            } catch (error) {
                console.error('Failed to load tables:', error);
                document.getElementById('tables-container').innerHTML = 
                    '<div class="error-message">Failed to load tables</div>';
            }
        }

        function renderTables(tables) {
            const tablesContainer = document.getElementById('tables-container');
            
            if (tables.length === 0) {
                tablesContainer.innerHTML = '<div class="no-tables">No tables found</div>';
                return;
            }
            
            tablesContainer.innerHTML = '';
            tables.forEach(table => {
                const tableItem = document.createElement('div');
                tableItem.className = 'table-item';
                tableItem.innerHTML = \`
                    <div>
                        <strong>\${table.name}</strong>
                        <div class="table-stats">\${table.rowCount} rows</div>
                    </div>
                \`;
                tableItem.onclick = (event) => selectTable(table.name, event.currentTarget);
                tablesContainer.appendChild(tableItem);
            });
        }

        function filterTables() {
            const searchTerm = document.getElementById('tableSearch').value.toLowerCase();
            
            if (searchTerm === '') {
                renderTables(allTables);
                updateTableCount(allTables.length);
                return;
            }
            
            const filteredTables = allTables.filter(table => 
                table.name.toLowerCase().includes(searchTerm)
            );
            
            renderTables(filteredTables);
            updateTableCount(filteredTables.length, allTables.length);
        }

        function updateTableCount(visibleCount, totalCount = null) {
            const countElement = document.getElementById('tableCount');
            if (totalCount && visibleCount !== totalCount) {
                countElement.innerHTML = \`<span>\${visibleCount} of \${totalCount} tables</span>\`;
            } else {
                countElement.innerHTML = \`<span>\${visibleCount} tables</span>\`;
            }
        }

        async function selectTable(tableName, clickedElement) {
            currentTable = tableName;
            document.getElementById('query').value = \`SELECT * FROM \${tableName} LIMIT 1000\`;
            runQuery();
            
            // Update active table in sidebar
            document.querySelectorAll('.table-item').forEach(item => {
                item.classList.remove('active');
            });
            
            if (clickedElement) {
                clickedElement.classList.add('active');
            }
            
            // Load schema
            loadSchema(tableName);
        }

        async function loadSchema(tableName) {
            try {
                const response = await fetch(\`/api/tables/\${tableName}/schema\`);
                const schema = await response.json();
                displaySchema(schema);
            } catch (error) {
                console.error('Failed to load schema:', error);
            }
        }

        function displaySchema(schema) {
            let schemaHtml = '<table><thead><tr><th>Column</th><th>Type</th><th>Nullable</th><th>Primary Key</th></tr></thead><tbody>';
            
            schema.forEach(column => {
                schemaHtml += \`<tr>
                    <td><strong>\${column.name}</strong></td>
                    <td>\${column.type}</td>
                    <td>\${column.nullable ? 'YES' : 'NO'}</td>
                    <td>\${column.primaryKey ? 'YES' : 'NO'}</td>
                </tr>\`;
            });
            
            schemaHtml += '</tbody></table>';
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
                    document.getElementById('error').textContent = \`Error: \${result.error}\`;
                    return;
                }

                document.getElementById('rowCount').textContent = result.rowCount;
                document.getElementById('queryTime').textContent = result.executionTime || executionTime;
                document.getElementById('columnCount').textContent = result.columns ? result.columns.length : 0;
                
                // Store the data for pagination
                currentData = result.data;
                totalRows = result.rowCount;
                currentPage = 1;
                
                // Display first page
                displayCurrentPage();
                updateQueryHistory(query, result.rowCount, executionTime);
                
                switchTab('results', document.querySelector('.tab[onclick*="results"]'));
            } catch (error) {
                document.getElementById('loading').style.display = 'none';
                document.getElementById('error').style.display = 'block';
                document.getElementById('error').textContent = \`Network Error: \${error.message}\`;
            }
        }

        function displayCurrentPage() {
            if (currentData.length === 0) {
                document.getElementById('output').innerHTML = '<div class="no-results">No data found</div>';
                return;
            }

            // Calculate pagination
            const totalPages = Math.ceil(totalRows / pageSize);
            const startIndex = (currentPage - 1) * pageSize;
            const endIndex = Math.min(startIndex + pageSize, totalRows);
            const pageData = currentData.slice(startIndex, endIndex);

            // Display the table
            displayTable(pageData);
            
            // Add pagination controls
            addPaginationControls(totalPages, startIndex, endIndex);
        }

        function displayTable(data) {
            const headers = Object.keys(data[0]);
            let tableHtml = '<table><thead><tr>';
            
            headers.forEach(header => {
                tableHtml += \`<th>\${header}</th>\`;
            });
            tableHtml += '</tr></thead><tbody>';

            data.forEach(row => {
                tableHtml += '<tr>';
                headers.forEach(header => {
                    const value = row[header];
                    let cellContent = '';
                    let cellClass = '';

                    if (value === null || value === undefined) {
                        cellContent = '<span class="null-value">NULL</span>';
                    } else if (typeof value === 'number') {
                        cellContent = value.toLocaleString();
                        cellClass = 'number-cell';
                    } else if (typeof value === 'boolean') {
                        cellContent = value ? 
                            '<i class="fas fa-check boolean-true"></i>' : 
                            '<i class="fas fa-times boolean-false"></i>';
                        cellClass = 'boolean-cell';
                    } else {
                        cellContent = value.toString().length > 50 ? 
                            value.toString().substring(0, 47) + '...' : 
                            value.toString();
                    }

                    tableHtml += \`<td class="\${cellClass}" title="\${value}">\${cellContent}</td>\`;
                });
                tableHtml += '</tr>';
            });

            tableHtml += '</tbody></table>';
            document.getElementById('output').innerHTML = tableHtml;
        }

        function addPaginationControls(totalPages, startIndex, endIndex) {
            const paginationHtml = \`
                <div class="pagination">
                    <div class="pagination-info">
                        Showing \${startIndex + 1} to \${endIndex} of \${totalRows} entries
                    </div>
                    <div class="pagination-controls">
                        <button class="pagination-btn" onclick="goToPage(1)" \${currentPage === 1 ? 'disabled' : ''}>
                            <i class="fas fa-angle-double-left"></i>
                        </button>
                        <button class="pagination-btn" onclick="goToPage(\${currentPage - 1})" \${currentPage === 1 ? 'disabled' : ''}>
                            <i class="fas fa-angle-left"></i>
                        </button>
                        
                        <div class="pagination-pages">
                            \${generatePageButtons(totalPages)}
                        </div>
                        
                        <button class="pagination-btn" onclick="goToPage(\${currentPage + 1})" \${currentPage === totalPages ? 'disabled' : ''}>
                            <i class="fas fa-angle-right"></i>
                        </button>
                        <button class="pagination-btn" onclick="goToPage(\${totalPages})" \${currentPage === totalPages ? 'disabled' : ''}>
                            <i class="fas fa-angle-double-right"></i>
                        </button>
                    </div>
                    <div class="pagination-settings">
                        <select class="page-size-select" onchange="changePageSize(this.value)">
                            <option value="10" \${pageSize === 10 ? 'selected' : ''}>10 per page</option>
                            <option value="25" \${pageSize === 25 ? 'selected' : ''}>25 per page</option>
                            <option value="50" \${pageSize === 50 ? 'selected' : ''}>50 per page</option>
                            <option value="100" \${pageSize === 100 ? 'selected' : ''}>100 per page</option>
                            <option value="250" \${pageSize === 250 ? 'selected' : ''}>250 per page</option>
                        </select>
                        <input type="number" class="page-input" min="1" max="\${totalPages}" value="\${currentPage}" 
                               onchange="goToPage(parseInt(this.value))" onkeypress="handlePageInput(event)">
                        <span>of \${totalPages}</span>
                    </div>
                </div>
            \`;
            
            // Insert pagination after the table wrapper
            const tableWrapper = document.querySelector('.table-wrapper');
            if (tableWrapper.nextSibling) {
                tableWrapper.parentNode.insertBefore(createElementFromHTML(paginationHtml), tableWrapper.nextSibling);
            } else {
                tableWrapper.parentNode.appendChild(createElementFromHTML(paginationHtml));
            }
        }

        function createElementFromHTML(htmlString) {
            const div = document.createElement('div');
            div.innerHTML = htmlString.trim();
            return div.firstChild;
        }

        function generatePageButtons(totalPages) {
            let buttons = '';
            const maxVisiblePages = 5;
            let startPage = Math.max(1, currentPage - Math.floor(maxVisiblePages / 2));
            let endPage = Math.min(totalPages, startPage + maxVisiblePages - 1);
            
            // Adjust start page if we're near the end
            if (endPage - startPage + 1 < maxVisiblePages) {
                startPage = Math.max(1, endPage - maxVisiblePages + 1);
            }
            
            // Show first page and ellipsis if needed
            if (startPage > 1) {
                buttons += \`<button class="page-btn" onclick="goToPage(1)">1</button>\`;
                if (startPage > 2) {
                    buttons += '<span>...</span>';
                }
            }
            
            // Show page buttons
            for (let i = startPage; i <= endPage; i++) {
                buttons += \`<button class="page-btn \${i === currentPage ? 'active' : ''}" onclick="goToPage(\${i})">\${i}</button>\`;
            }
            
            // Show last page and ellipsis if needed
            if (endPage < totalPages) {
                if (endPage < totalPages - 1) {
                    buttons += '<span>...</span>';
                }
                buttons += \`<button class="page-btn" onclick="goToPage(\${totalPages})">\${totalPages}</button>\`;
            }
            
            return buttons;
        }

        function goToPage(page) {
            const totalPages = Math.ceil(totalRows / pageSize);
            if (page < 1 || page > totalPages || page === currentPage) return;
            
            currentPage = page;
            displayCurrentPage();
        }

        function changePageSize(newSize) {
            pageSize = parseInt(newSize);
            currentPage = 1;
            displayCurrentPage();
        }

        function handlePageInput(event) {
            if (event.key === 'Enter') {
                const page = parseInt(event.target.value);
                const totalPages = Math.ceil(totalRows / pageSize);
                
                if (page >= 1 && page <= totalPages) {
                    goToPage(page);
                } else {
                    event.target.value = currentPage; // Reset to current page
                }
            }
        }

        function displayJson(data) {
            const jsonOutput = document.getElementById('json-output');
            jsonOutput.innerHTML = \`<div class="json-viewer">\${JSON.stringify(data, null, 2)}</div>\`;
        }

        function switchTab(tabName, clickedElement) {
            // Hide all tabs
            document.querySelectorAll('.tab-content').forEach(tab => {
                tab.classList.remove('active');
            });
            document.querySelectorAll('.tab').forEach(tab => {
                tab.classList.remove('active');
            });

            // Show selected tab
            document.getElementById(\`\${tabName}-tab\`).classList.add('active');
            
            // Activate clicked tab
            if (clickedElement) {
                clickedElement.classList.add('active');
            }
        }

        function insertTemplate(type) {
            const templates = {
                SELECT: 'SELECT * FROM users WHERE age > 25 ORDER BY name;',
                INSERT: "INSERT INTO users (name, email, age) VALUES ('John Doe', 'john@example.com', 30);",
                UPDATE: "UPDATE users SET age = 31 WHERE name = 'John Doe';",
                DELETE: "DELETE FROM users WHERE age < 18;"
            };
            
            document.getElementById('query').value = templates[type];
        }

        function clearQuery() {
            document.getElementById('query').value = '';
            document.getElementById('output').innerHTML = '';
            document.getElementById('error').style.display = 'none';
            currentData = [];
            totalRows = 0;
            currentPage = 1;
            
            // Remove any existing pagination
            const existingPagination = document.querySelector('.pagination');
            if (existingPagination) {
                existingPagination.remove();
            }
        }

        function formatQuery() {
            const query = document.getElementById('query').value;
            // Basic formatting
            const formatted = query
                .replace(/\\bSELECT\\b/gi, '\\nSELECT')
                .replace(/\\bFROM\\b/gi, '\\nFROM')
                .replace(/\\bWHERE\\b/gi, '\\nWHERE')
                .replace(/\\bORDER BY\\b/gi, '\\nORDER BY')
                .replace(/\\bGROUP BY\\b/gi, '\\nGROUP BY');
            
            document.getElementById('query').value = formatted.trim();
        }

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
            
            historyList.innerHTML = queryHistory.map((query, index) => \`
                <div class="history-item" onclick="useHistoryQuery('\${query.sql.replace(/'/g, "\\\\'")}')">
                    <div class="history-sql">\${query.sql}</div>
                    <div class="history-meta">
                        \${query.rowCount} rows • \${query.executionTime}ms • 
                        \${new Date(query.timestamp).toLocaleString()}
                    </div>
                </div>
            \`).join('');
            
            modal.style.display = 'block';
        }

        function closeHistoryModal() {
            document.getElementById('historyModal').style.display = 'none';
        }

        function useHistoryQuery(sql) {
            document.getElementById('query').value = sql;
            closeHistoryModal();
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
            
            window.open(\`/api/export/\${currentTable}?format=\${format}\`, '_blank');
        }

        // Handle responsive behavior
        window.addEventListener('resize', function() {
            // Adjust table container height on resize
            const tablesContainer = document.getElementById('tables-container');
            const sidebar = document.querySelector('.sidebar');
            if (window.innerWidth <= 768) {
                tablesContainer.style.maxHeight = '200px';
            } else {
                tablesContainer.style.maxHeight = '400px';
            }
        });
    </script>
</body>
</html>
''';
}