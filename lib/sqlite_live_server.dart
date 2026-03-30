library sqlite_web_server;

import 'sqlite_service.dart';
import 'web_server.dart';

class SqliteLiveServer {
  static SQLiteService? _dbService;
  static WebServer? _webServer;

  static Future<void> start({required String dbName, int port = 8080}) async {
    await stop(); // Ensure previous is stopped
    _dbService = SQLiteService();
    await _dbService!.initDatabase(dbName);
    _webServer = WebServer(_dbService!, port: port);
    await _webServer!.startServer();
  }

  static Future<void> stop() async {
    await _webServer?.stopServer();
    _webServer = null;
  }
}
