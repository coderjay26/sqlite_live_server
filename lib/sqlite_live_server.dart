library sqlite_web_server;

import 'sqlite_service.dart';
import 'web_server.dart';

class SqliteLiveServer {
  static late SQLiteService _dbService;
  static late WebServer _webServer;

  static Future<void> start({required String dbName}) async {
    _dbService = SQLiteService();
    await _dbService.initDatabase(dbName);
    _webServer = WebServer(_dbService);
    await _webServer.startServer();
  }

  static Future<void> stop() async {
    await _webServer.stopServer();
  }
}
