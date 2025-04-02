import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'sqlite_service.dart';
import 'package:url_launcher/url_launcher.dart';

class WebServer {
  final SQLiteService dbService;
  HttpServer? _server;

  WebServer(this.dbService);

  Future<void> startServer() async {
    var router = Router();

    router.get('/tables', (Request request) async {
      var tables = await dbService.getTables();
      return Response.ok(jsonEncode(tables),
          headers: {'Content-Type': 'application/json'});
    });

    router.get('/query', (Request request) async {
      final sql = request.url.queryParameters['sql'];
      if (sql == null)
        return Response.badRequest(body: 'SQL query is required');
      var data = await dbService.query(sql);
      return Response.ok(jsonEncode(data),
          headers: {'Content-Type': 'application/json'});
    });

    router.get('/', (Request request) {
      return Response.ok(_htmlPage, headers: {'Content-Type': 'text/html'});
    });

    _server = await io.serve(router, 'localhost', 8080);
    print('Server running at http://localhost:8080');

    final url = 'http://localhost:8080';
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url));
    }
  }

  Future<void> stopServer() async {
    await _server?.close();
    print('Server stopped.');
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
