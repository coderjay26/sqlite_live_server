import 'dart:io';
import 'dart:convert';
import 'package:get_ip_address/get_ip_address.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart'; // Import this
import 'sqlite_service.dart';

class WebServer {
  final SQLiteService dbService;
  HttpServer? _server;

  WebServer(this.dbService);

  Future<void> startServer() async {
    // Get the IP address of the device
    // String? ipAddress = await _getLocalIPAddress();
    var ip = IpAddress(type: RequestType.json);
    String? ipAddress = await ip.getIpAddress();
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

    var handler =
        const Pipeline().addMiddleware(logRequests()).addHandler(router);

    // Listen on all network interfaces (0.0.0.0 means all available interfaces)
    var server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
    print(
        'Server running at http://$ipAddress:8080'); // Print the device IP address
  }

  Future<void> stopServer() async {
    await _server?.close();
    print('Server stopped.');
  }

  Future<String?> _getLocalIPAddress() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.address.contains(".")) {
            // Get IPv4 address

            return addr.address;
          }
        }
      }
    } catch (e) {
      // ipAddress = "Failed to get IP";
      print('Server stopped.');
    }
  }

  static const String _htmlPage = '''
<html>
  <head>
    <title>SQLite Browser</title>
    <style>
      body {
        font-family: Arial, sans-serif;
        margin: 0;
        background-color: #f4f6f9;
        height: 100vh;
        overflow: hidden;
      }
      h1 {
        color: #2c3e50;
      }
      .container {
        max-width: 100%;
        max-height: 100%;
        margin: 0;
        padding: 20px;
        background-color: #ffffff;
        border-radius: 8px;
        box-shadow: 0 0 10px rgba(0, 0, 0, 0.1);
        overflow: hidden;
      }
      .output-container {
        max-height: 400px;
        overflow: auto;
      }

      textarea {
        width: 100%;
        padding: 10px;
        font-size: 16px;
        margin: 10px 0;
        border-radius: 5px;
        border: 1px solid #ccc;
        resize: vertical;
      }
      button {
        padding: 10px 15px;
        font-size: 16px;
        background-color: #3498db;
        color: white;
        border: none;
        border-radius: 5px;
        cursor: pointer;
      }
      button:hover {
        background-color: #2980b9;
      }
      select {
        width: 100%;
        padding: 10px;
        font-size: 16px;
        margin: 10px 0;
        border-radius: 5px;
        border: 1px solid #ccc;
      }
      pre {
        background-color: #ecf0f1;
        padding: 15px;
        border-radius: 5px;
        white-space: pre-wrap;
        word-wrap: break-word;
        font-family: monospace;
      }
      table {
        width: 100%;
        height: 100%;
        border-collapse: collapse;
        margin-top: 20px;
        overflow-y: auto;
        display: block;
        table-layout: fixed;
      }
      thead {
        position: sticky;
        top: 0;
        background-color: #3498db;
        z-index: 10;
      }
      table, th, td {
        border: 1px solid #ddd;
      }
      th, td {
        padding: 10px;
        text-align: left;
        max-width: 200px;  /* Limit column width */
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      th {
       position: sticky;
       top: 0;
       background-color: #3498db;
       z-index: 10;
       color: white;
      }
      td {
        background-color: #f9f9f9;
        cursor: pointer;
      }
      td:hover {
        background-color: #e1e1e1;
      }
      .tooltip {
        display: none;
        position: absolute;
        background-color: #333;
        color: white;
        padding: 5px;
        border-radius: 3px;
        font-size: 14px;
        max-width: 300px;
        white-space: normal;
        word-wrap: break-word;
        z-index: 9999;
      }
      .no-data {
        color: #e74c3c;
        font-style: italic;
      }
    </style>
  </head>
  <body>
    <div class="container">
      <h1>SQLite Browser</h1>

      <label for="tables">Select a Table:</label>
      <select id="tables" onchange="selectTable()">
        <option value="">-- Select a table --</option>
      </select>

      <br><br>

      <label for="query">SQL Query:</label>
      <textarea id="query" rows="6" placeholder="Write your SQL query here..."></textarea>

      <br><br>

      <button onclick="runQuery()">Run Query</button>

      <br><br>

      <div class="output-container">
        <h3>Query Result:</h3>
        <div id="output"></div> <!-- Results will be shown as a table here -->
      </div>

      <!-- Tooltip container -->
      <div id="tooltip" class="tooltip"></div>
    </div>
  <script>
      // Fetch and display available tables from the database
      async function loadTables() {
        let response = await fetch('/tables');
        let tables = await response.json();
        const tablesSelect = document.getElementById("tables");
        let optionsHtml = '';
        for (let i = 0; i < tables.length; i++) {
          optionsHtml += '<option value="' + tables[i] + '">' + tables[i] + '</option>';
        }
        tablesSelect.innerHTML = optionsHtml;
      }

      // Run a SQL query entered in the textarea and display the result
      async function runQuery() {
        let sql = document.getElementById("query").value;
        let response = await fetch('/query?sql=' + encodeURIComponent(sql));
        let data = await response.json();
        
        // Display the result as a table
        displayTable(data);
      }
      // Display the result as a table  
      function displayTable(data) {
        let tableHtml = '';
        if (data.length > 0) {
          let headers = Object.keys(data[0]);
          tableHtml += '<table><thead><tr>';
          for (let i = 0; i < headers.length; i++) {
            tableHtml += '<th>' + headers[i] + '</th>';
          }
          tableHtml += '</tr></thead><tbody>';

          // Create table rows
          for (let i = 0; i < data.length; i++) {
            tableHtml += '<tr>';
            for (let j = 0; j < headers.length; j++) {
              tableHtml += '<td onmouseover="showTooltip(event, this.innerText)" onmouseout="hideTooltip()">' + data[i][headers[j]] + '</td>';
            }
            tableHtml += '</tr>';
          }
          tableHtml += '</tbody></table>';
        } else {
          tableHtml = '<p class="no-data">No data found</p>';
        }

        document.getElementById("output").innerHTML = tableHtml;
      }

      function showTooltip(event, text) {
        let tooltip = document.getElementById("tooltip");
        tooltip.innerHTML = text;
        tooltip.style.display = "block";
        tooltip.style.left = event.pageX + 10 + "px";
        tooltip.style.top = event.pageY + 10 + "px";
      }

      function hideTooltip() {
        let tooltip = document.getElementById("tooltip");
        tooltip.style.display = "none";
      }

      // Display the selected table data in the textarea
      function selectTable() {
        let table = document.getElementById("tables").value;
        document.getElementById("query").value = 'SELECT * FROM ' + table;
      }

      // Ensure the loadTables function is called once the page is fully loaded
      window.onload = loadTables;
    </script>
  </body>
</html>
''';
}
