import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'dart:io';

class SQLiteService {
  Database? _database;
  String? _databasePath;

  Future<void> initDatabase(String dbName) async {
    Directory appDir = await getApplicationDocumentsDirectory();
    _databasePath = join(appDir.path, dbName);
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    if (_databasePath == null) {
      throw Exception(
          "Database path not set. Call `initDatabase(dbName)` first.");
    }
    return _database = await openDatabase(_databasePath!);
  }

  Future<List<Map<String, dynamic>>> query(String sql) async {
    final db = await database;
    return await db.rawQuery(sql);
  }

  Future<List<String>> getTables() async {
    final db = await database;
    final tables =
        await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table';");
    return tables.map((e) => e['name'] as String).toList();
  }
}
