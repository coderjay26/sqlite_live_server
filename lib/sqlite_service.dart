import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class SQLiteService {
  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    return _database = await _initDatabase();
  }

  Future<Database> _initDatabase() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, 'live_data.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE data (id INTEGER PRIMARY KEY, value TEXT)',
        );
      },
    );
  }

  Future<void> insertData(String value) async {
    final db = await database;
    await db.insert('data', {'value': value});
  }

  Future<List<Map<String, dynamic>>> getData() async {
    final db = await database;
    return await db.query('data');
  }
}
