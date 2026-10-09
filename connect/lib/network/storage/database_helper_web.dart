import 'package:sqflite/sqflite.dart';
import 'package:connect/network/storage/database_helper.dart';

/// Web stub - IndexedDB implementation would go here if needed
class DatabaseHelperWeb implements DatabaseHelperInterface {
  static Database? _database;
  static final DatabaseHelperWeb _instance = DatabaseHelperWeb._internal();

  static DatabaseHelperWeb get instance => _instance;

  DatabaseHelperWeb._internal();

  @override
  Future<Database> init() async {
    throw UnsupportedError('Web database not implemented. Use IndexedDB via web plugins.');
  }

  @override
  Future<void> close() async {
    // No-op for web stub
  }
}