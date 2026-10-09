import 'package:sqflite/sqflite.dart';

abstract class DatabaseHelperInterface {
  Future<Database> init();
  Future<void> close();
}

class DatabaseHelper {
  static DatabaseHelperInterface? _instance;
  
  static DatabaseHelperInterface get instance {
    if (_instance == null) {
      throw StateError('DatabaseHelper not initialized. Call DatabaseHelper.initialize() first.');
    }
    return _instance!;
  }
  
  static void initialize(DatabaseHelperInterface impl) {
    _instance = impl;
  }
}