import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'sqlite_service.dart';
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';

class WebServer {
  final SQLiteService _dbService = SQLiteService();
  HttpServer? _server;

  Future<void> startServer() async {
    var handler = Pipeline().addMiddleware(logRequests()).addHandler(_router);

    _server = await io.serve(handler, 'localhost', 8080);
    print('Server running on http://${_server!.address.host}:${_server!.port}');

    // Open browser when the server starts
    final url = 'http://${_server!.address.host}:${_server!.port}';
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url));
    } else {
      print('Could not launch $url');
    }
  }

  Future<Response> _router(Request request) async {
    if (request.url.path == 'data') {
      var data = await _dbService.getData();
      return Response.ok(jsonEncode(data),
          headers: {'Content-Type': 'application/json'});
    }

    // Simple HTML page for testing
    if (request.url.path == '') {
      return Response.ok(
        '''
        <html>
        <head>
          <title>SQLite Live Data</title>
          <script>
            async function fetchData() {
              let response = await fetch('/data');
              let data = await response.json();
              document.getElementById("output").innerHTML = JSON.stringify(data, null, 2);
            }
          </script>
        </head>
        <body>
          <h1>Live SQLite Data</h1>
          <button onclick="fetchData()">Fetch Data</button>
          <pre id="output"></pre>
        </body>
        </html>
        ''',
        headers: {'Content-Type': 'text/html'},
      );
    }

    return Response.notFound('Not Found');
  }

  Future<void> stopServer() async {
    await _server?.close();
    print('Server stopped.');
  }
}
