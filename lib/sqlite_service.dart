import 'dart:math';

import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'dart:io';

class SQLiteService {
  Database? _database;
  String? _databasePath;

  Future<void> initDatabase(String dbName) async {
    Directory appDir = await getApplicationDocumentsDirectory();
    _databasePath = join(await getDatabasesPath(), dbName);
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

  // Get row count for a specific table
  Future<int> getTableRowCount(String tableName) async {
    final db = await database;
    try {
      final result = await db.rawQuery('SELECT COUNT(*) as count FROM $tableName');
      return result.first['count'] as int;
    } catch (e) {
      print('Error getting row count for $tableName: $e');
      return 0;
    }
  }

  // Get table schema information
  Future<List<Map<String, dynamic>>> getTableSchema(String tableName) async {
    final db = await database;
    try {
      final schema = await db.rawQuery('PRAGMA table_info($tableName)');
      
      return schema.map((column) {
        return {
          'name': column['name'],
          'type': column['type'],
          'nullable': column['notnull'] == 0,
          'primaryKey': column['pk'] == 1,
          'defaultValue': column['dflt_value'],
        };
      }).toList();
    } catch (e) {
      print('Error getting schema for $tableName: $e');
      return [];
    }
  }

  // Get detailed table information
  Future<Map<String, dynamic>> getTableInfo(String tableName) async {
    try {
      // Get row count
      final rowCount = await getTableRowCount(tableName);
      
      // Get schema
      final schema = await getTableSchema(tableName);
      
      // Get index information
      final db = await database;
      final indexes = await db.rawQuery('PRAGMA index_list($tableName)');
      
      // Get sample data (first 5 rows)
      final sampleData = await db.query(tableName, limit: 5);
      
      return {
        'name': tableName,
        'rowCount': rowCount,
        'columns': schema.length,
        'schema': schema,
        'indexes': indexes,
        'sampleData': sampleData,
      };
    } catch (e) {
      print('Error getting table info for $tableName: $e');
      return {
        'name': tableName,
        'rowCount': 0,
        'columns': 0,
        'schema': [],
        'indexes': [],
        'sampleData': [],
        'error': e.toString(),
      };
    }
  }

  // Insert data into table
  Future<int> insert(String table, Map<String, dynamic> data) async {
    final db = await database;
    try {
      return await db.insert(table, data);
    } catch (e) {
      print('Error inserting into $table: $e');
      rethrow;
    }
  }

  // Update data in table
  Future<int> update(String table, Map<String, dynamic> data, {String? where}) async {
    final db = await database;
    try {
      // Extract the WHERE clause and parameters
      String? actualWhere;
      List<dynamic>? whereArgs;
      
      if (where != null && where.contains('=')) {
        final parts = where.split('=');
        if (parts.length == 2) {
          actualWhere = '${parts[0].trim()} = ?';
          whereArgs = [parts[1].trim().replaceAll("'", "").replaceAll('"', '')];
        }
      }
      
      // Remove id from data if it exists (usually auto-increment)
      final dataCopy = Map<String, dynamic>.from(data);
      dataCopy.remove('id');
      
      return await db.update(
        table,
        dataCopy,
        where: actualWhere,
        whereArgs: whereArgs,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      print('Error updating $table: $e');
      rethrow;
    }
  }

  // Delete data from table
  Future<int> delete(String table, {String? where}) async {
    final db = await database;
    try {
      // Extract the WHERE clause and parameters
      String? actualWhere;
      List<dynamic>? whereArgs;
      
      if (where != null && where.contains('=')) {
        final parts = where.split('=');
        if (parts.length == 2) {
          actualWhere = '${parts[0].trim()} = ?';
          whereArgs = [parts[1].trim().replaceAll("'", "").replaceAll('"', '')];
        }
      }
      
      return await db.delete(
        table,
        where: actualWhere,
        whereArgs: whereArgs,
      );
    } catch (e) {
      print('Error deleting from $table: $e');
      rethrow;
    }
  }

  // Get database information
  Future<Map<String, dynamic>> getDatabaseInfo() async {
    try {
      final db = await database;
      
      // Get all tables
      final tables = await getTables();
      
      // Get database file size
      final file = File(_databasePath!);
      final exists = await file.exists();
      final size = exists ? await file.length() : 0;
      
      // Get SQLite version
      final version = await db.rawQuery('SELECT sqlite_version() as version');
      final sqliteVersion = version.first['version'] as String;
      
      // Get table statistics
      final tableStats = <Map<String, dynamic>>[];
      for (final table in tables) {
        final count = await getTableRowCount(table);
        final schema = await getTableSchema(table);
        tableStats.add({
          'name': table,
          'rowCount': count,
          'columnCount': schema.length,
        });
      }
      
      return {
        'name': _databasePath?.split('/').last ?? 'unknown.db',
        'path': _databasePath,
        'size': size,
        'sizeFormatted': _formatBytes(size),
        'tables': tables.length,
        'sqliteVersion': sqliteVersion,
        'tableStats': tableStats,
      };
    } catch (e) {
      print('Error getting database info: $e');
      return {
        'name': 'unknown.db',
        'path': _databasePath,
        'size': 0,
        'sizeFormatted': '0 B',
        'tables': 0,
        'sqliteVersion': 'unknown',
        'tableStats': [],
        'error': e.toString(),
      };
    }
  }

  // Get query execution plan
  Future<List<Map<String, dynamic>>> explainQuery(String sql) async {
    final db = await database;
    try {
      return await db.rawQuery('EXPLAIN QUERY PLAN $sql');
    } catch (e) {
      print('Error explaining query: $e');
      return [{'error': e.toString()}];
    }
  }

  // Get database size information
  Future<Map<String, dynamic>> getDatabaseSize() async {
    try {
      final file = File(_databasePath!);
      final exists = await file.exists();
      if (!exists) {
        return {'size': 0, 'sizeFormatted': '0 B'};
      }
      
      final size = await file.length();
      return {
        'size': size,
        'sizeFormatted': _formatBytes(size),
      };
    } catch (e) {
      print('Error getting database size: $e');
      return {'size': 0, 'sizeFormatted': '0 B', 'error': e.toString()};
    }
  }

  // Optimize database (VACUUM)
  Future<void> optimizeDatabase() async {
    final db = await database;
    try {
      await db.execute('VACUUM');
    } catch (e) {
      print('Error optimizing database: $e');
      rethrow;
    }
  }

  // Close database connection
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  // Utility method to format bytes
  static String _formatBytes(int bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}';
  }
}