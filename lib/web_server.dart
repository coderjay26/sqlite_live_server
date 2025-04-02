import 'dart:io';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:network_info_plus/network_info_plus.dart'; // Import this
import 'sqlite_service.dart';

class WebServer {
  final SQLiteService dbService;
  HttpServer? _server;

  WebServer(this.dbService);

  Future<void> startServer() async {
    // Get the IP address of the device
    String? ipAddress = await _getDeviceIP();

    var router = Router();

    // Endpoint to get the list of tables
    router.get('/tables', (Request request) async {
      var tables = await dbService.getTables();
      return Response.ok(jsonEncode(tables),
          headers: {'Content-Type': 'application/json'});
    });

    // Endpoint to run SQL queries
    router.get('/query', (Request request) async {
      final sql = request.url.queryParameters['sql'];
      if (sql == null)
        return Response.badRequest(body: 'SQL query is required');
      var data = await dbService.query(sql);
      return Response.ok(jsonEncode(data),
          headers: {'Content-Type': 'application/json'});
    });

    // Root endpoint to serve the HTML page
    router.get('/', (Request request) {
      return Response.ok(_htmlPage, headers: {'Content-Type': 'text/html'});
    });

    var handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(router.handler);

    // Listen on all network interfaces (0.0.0.0 means all available interfaces)
    var server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
    print(
        'Server running at http://$ipAddress:8080'); // Print the device IP address
  }

  Future<void> stopServer() async {
    await _server?.close();
    print('Server stopped.');
  }

  // Function to get the IP address of the device
  Future<String?> _getDeviceIP() async {
    final info = NetworkInfo();
    String? ip = await info.getIpAddress();
    return ip ?? 'Unable to get IP'; // Return the IP or a fallback message
  }

  static const String _htmlPage = '''
  <html>
  <head>
    <title>SQLite Browser</title>
    <script>
      async function loadTables() {
        let response = await fetch('/tables');
        let tables = await response.json();
        document.getElementById("tables").innerHTML = tables.map(t => '<option>' + t + '</option>').join('');
      }

      async function runQuery() {
        let sql = document.getElementById("query").value;
        let response = await fetch('/query?sql=' + encodeURIComponent(sql));
        let data = await response.json();
        document.getElementById("output").innerText = JSON.stringify(data, null, 2);
      }
    </script>
  </head>
  <body onload="loadTables()">
    <h1>SQLite Browser</h1>
    <label>Tables:</label>
    <select id="tables"></select>
    <br><br>
    <textarea id="query" rows="4" cols="50">SELECT * FROM table_name;</textarea>
    <br><br>
    <button onclick="runQuery()">Run Query</button>
    <pre id="output"></pre>
  </body>
  </html>
  ''';
}
