import 'dart:io';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'sqlite_service.dart';

class WebServer {
  final SQLiteService dbService;
  HttpServer? _server;

  WebServer(this.dbService);

  Future<void> startServer() async {
    String? ipAddress = await _getLocalIPAddress();

    var router = Router();

    // Get the list of tables
    router.get('/tables', (Request request) async {
      var tables = await dbService.getTables();
      return Response.ok(jsonEncode(tables),
          headers: {'Content-Type': 'application/json'});
    });

    // Run SQL queries
    router.get('/query', (Request request) async {
      final sql = request.url.queryParameters['sql'];
      if (sql == null) {
        return Response.badRequest(
            body: jsonEncode({'error': 'SQL query is required'}),
            headers: {'Content-Type': 'application/json'});
      }

      try {
        var data = await dbService.query(sql);
        return Response.ok(jsonEncode({'data': data, 'rowCount': data.length}),
            headers: {'Content-Type': 'application/json'});
      } catch (e) {
        return Response.internalServerError(
            body: jsonEncode({'error': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    // Serve HTML
    router.get('/', (Request request) {
      return Response.ok(_htmlPage, headers: {'Content-Type': 'text/html'});
    });

    var handler =
        const Pipeline().addMiddleware(logRequests()).addHandler(router);

    var server = await io.serve(handler, InternetAddress.anyIPv4, 8080);
    print('\x1B[32mServer running at http://$ipAddress:8080\x1B[0m');
  }

  Future<void> stopServer() async {
    await _server?.close();
    print('Server stopped.');
  }

  Future<String?> _getLocalIPAddress() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              interface.name == 'wlan0') {
            return addr.address;
          }
        }
      }
    } catch (e) {
      print('Error getting IP address: $e');
    }
  }

  static const String _htmlPage = '''
<html>
<head>
  <title>SQLite Browser</title>
  <style>
    body {
      font-family: Arial, sans-serif;
      background-color: #f4f6f9;
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
  <div class="container">
    <h1>SQLite Browser</h1>
    <label for="tables">Select a Table:</label>
    <select id="tables" onchange="selectTable()">
      <option value="">-- Select a table --</option>
    </select>
    <textarea id="query" rows="4" placeholder="Write your SQL query here..."></textarea>
    <button onclick="runQuery()">Run Query</button>
    <p class="loading" id="loading">Loading...</p>
    <p class="error" id="error"></p>
    <p><strong>Rows Found:</strong> <span id="rowCount">0</span></p>
    <div id="output"></div>
  </div>

  <script>
    async function loadTables() {
      let response = await fetch('/tables');
      let tables = await response.json();
      let tablesSelect = document.getElementById("tables");
      tablesSelect.innerHTML = '<option value="">-- Select a table --</option>';
      tables.forEach(table => {
        tablesSelect.innerHTML += '<option value="' + table + '">' + table + '</option>';
      });
    }

    async function runQuery() {
      let sql = document.getElementById("query").value;
      document.getElementById("loading").style.display = "block";
      document.getElementById("error").textContent = "";
      document.getElementById("output").innerHTML = "";

      try {
        let response = await fetch('/query?sql=' + encodeURIComponent(sql));
        let result = await response.json();

        document.getElementById("loading").style.display = "none";

        if (result.error) {
          document.getElementById("error").textContent = "Error: " + result.error;
          return;
        }

        document.getElementById("rowCount").textContent = result.rowCount;
        displayTable(result.data);
      } catch (error) {
        document.getElementById("error").textContent = "Error fetching data.";
        document.getElementById("loading").style.display = "none";
      }
    }

function displayTable(data) {
  if (data.length === 0) {
    document.getElementById("output").innerHTML = "<p>No data found.</p>";
    return;
  }

  let headers = Object.keys(data[0]);
  let tableHtml = '<div class="table-wrapper"><table><thead><tr>';
  
  headers.forEach(header => {
    tableHtml += '<th>' + header + '</th>';
  });
  tableHtml += '</tr></thead><tbody>';

  data.forEach(row => {
    tableHtml += '<tr onclick="highlightRow(this)">';
    headers.forEach(header => {
      let value = row[header] ?? '<i>NULL</i>'; // add this in the package
      let displayValue = value.toString().length > 20 ? value.toString().substring(0, 20) + '...' : value;
      
      let tooltip = value.toString().length > 20 ? ' title="' + value.toString().replace(/"/g, '&quot;') + '"' : '';

      tableHtml += '<td data-full-value="' + value + '" data-field="' + header + '" data-id="' + row.id + '" ondblclick="makeEditable(event)"' + tooltip + '>' + displayValue + '</td>';
    });
    tableHtml += '</tr>';
  });

  tableHtml += '</tbody></table></div>';
  document.getElementById("output").innerHTML = tableHtml;
}
    function highlightRow(row) {
      let rows = document.querySelectorAll("tr");
      rows.forEach(r => r.classList.remove("selected"));
      row.classList.add("selected");
    }

    function selectTable() {
      let table = document.getElementById("tables").value;
      document.getElementById("query").value = 'SELECT * FROM ' + table;
      runQuery();
    }
/// Add this in the package
        function makeEditable(event) {
            let td = event.target;
            let oldValue = td.getAttribute("data-full-value") || td.textContent;
            let input = document.createElement("input");
            input.type = "text";
            input.value = oldValue;
            input.onblur = function () {
                closeInput(td, input);  // Close input when blur event occurs
            };
            input.onkeydown = function (e) {
                if (e.key === "Enter") {
                    closeInput(td, input);  // Close input when Enter key is pressed
                }
            };
            td.textContent = "";
            td.appendChild(input);
            input.focus();
        }

        /// Add this in the package
        function closeInput(td, input) {
            // Just revert back to the previous value and remove the input field
            td.textContent = td.getAttribute("data-full-value") || td.textContent;
        }
    window.onload = loadTables;
  </script>
</body>
</html>
''';
}
