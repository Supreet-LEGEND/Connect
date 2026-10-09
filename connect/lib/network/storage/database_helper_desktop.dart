import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:connect/network/storage/database_helper.dart';

class DatabaseHelperDesktop implements DatabaseHelperInterface {
  static const _dbName = 'connect.db';
  static const _version = 4;
  static Database? _database;
  static final DatabaseHelperDesktop _instance = DatabaseHelperDesktop._internal();

  static DatabaseHelperDesktop get instance => _instance;

  DatabaseHelperDesktop._internal();

  Future<Database> init() async {
    if (_database != null) return _database!;
    
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}/connect.db';
    
    _database = await openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        try {
          await db.execute('PRAGMA journal_mode = WAL;');
        } catch (e) {
          debugPrint('Could not set WAL mode: $e');
        }
        await db.execute('PRAGMA busy_timeout = 5000;');
        await db.execute('PRAGMA synchronous = NORMAL;');
      },
      singleInstance: true,
    );
    
    return _database!;
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE outgoing_progress ADD COLUMN status TEXT DEFAULT "in_progress"');
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE outgoing_progress_new (
          transfer_id TEXT PRIMARY KEY,
          device_id TEXT NOT NULL,
          file_name TEXT,
          file_path TEXT,
          total_bytes INTEGER,
          completed_chunks TEXT,
          status TEXT DEFAULT 'in_progress',
          last_updated TEXT NOT NULL
        )
      ''');
      await db.execute('''
        INSERT INTO outgoing_progress_new (transfer_id, device_id, file_name, file_path, total_bytes, completed_chunks, status, last_updated)
        SELECT transfer_id, device_id, file_name, file_path, total_bytes, acknowledged_chunks, status, last_updated
        FROM outgoing_progress
      ''');
      await db.execute('DROP TABLE outgoing_progress');
      await db.execute('ALTER TABLE outgoing_progress_new RENAME TO outgoing_progress');

      await db.execute('ALTER TABLE incoming_progress ADD COLUMN expected_hash TEXT');
      await db.execute('ALTER TABLE incoming_progress ADD COLUMN status TEXT DEFAULT "in_progress"');
    }
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE incoming_progress ADD COLUMN fingerprint TEXT');
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE transfers (
        id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        file_name TEXT,
        file_path TEXT,
        total_bytes INTEGER DEFAULT 0,
        transferred_bytes INTEGER DEFAULT 0,
        total_chunks INTEGER DEFAULT 0,
        completed_chunks INTEGER DEFAULT 0,
        file_hash TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT,
        error TEXT,
        priority INTEGER DEFAULT 0,
        direction TEXT NOT NULL
      )
    ''');

    await db.execute('CREATE INDEX idx_transfers_device_status ON transfers(device_id, status)');
    await db.execute('CREATE INDEX idx_transfers_updated ON transfers(updated_at)');

    await db.execute('''
      CREATE TABLE trust_store (
        fingerprint TEXT PRIMARY KEY,
        alias TEXT,
        trusted_at TEXT NOT NULL,
        policy TEXT NOT NULL DEFAULT 'tofu',
        verified_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE peers (
        fingerprint TEXT PRIMARY KEY,
        alias TEXT,
        last_seen_ip TEXT,
        last_seen_port INTEGER,
        last_seen_at TEXT,
        last_connected_at TEXT,
        connection_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE outgoing_progress (
        transfer_id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        file_name TEXT,
        file_path TEXT,
        total_bytes INTEGER,
        completed_chunks TEXT,
        status TEXT DEFAULT 'in_progress',
        last_updated TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE incoming_progress (
        transfer_id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        file_name TEXT,
        file_path TEXT,
        total_bytes INTEGER,
        completed_chunks TEXT,
        expected_hash TEXT,
        fingerprint TEXT,
        status TEXT DEFAULT 'in_progress',
        last_updated TEXT NOT NULL
      )
    ''');
  }
}

/// Migration from JSON files to SQLite
class DatabaseMigration {
  static Future<void> migrateFromJson() async {
    final db = await DatabaseHelperDesktop.instance.init();
    final directory = await getApplicationSupportDirectory();
    
    final trustStoreFile = File('${directory.path}/trust_store.json');
    if (await trustStoreFile.exists()) {
      try {
        final jsonStr = await trustStoreFile.readAsString();
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        
        final batch = db.batch();
        for (final entry in data.entries) {
          final value = entry.value as Map<String, dynamic>;
          batch.insert('trust_store', {
            'fingerprint': entry.key,
            'alias': value['alias'],
            'trustedAt': value['trustedAt'],
            'policy': value['policy'],
            'verifiedAt': value['verifiedAt'],
          });
        }
        await batch.commit(noResult: true);
        
        await trustStoreFile.rename('${trustStoreFile.path}.bak');
      } catch (e) {
      }
    }

    final progressDir = Directory('${directory.path}/connect_transfers/progress');
    if (await progressDir.exists()) {
      final files = progressDir.listSync().whereType<File>().where((f) => f.path.endsWith('.progress'));
      final batch = db.batch();
      
      for (final file in files) {
        try {
          final jsonStr = await file.readAsString();
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          
          batch.insert('transfers', {
            'id': data['transferId'],
            'device_id': data['deviceId'],
            'type': data['type'] ?? 'file',
            'status': data['status'] ?? 'completed',
            'file_name': data['fileName'],
            'file_path': data['filePath'],
            'total_bytes': data['totalBytes'],
            'transferred_bytes': data['completedChunks']?.length ?? 0,
            'total_chunks': data['totalChunks'],
            'completed_chunks': (data['completedChunks'] as List?)?.length ?? 0,
            'file_hash': data['fileHash'],
            'created_at': data['lastUpdated'] ?? DateTime.now().toIso8601String(),
            'updated_at': data['lastUpdated'] ?? DateTime.now().toIso8601String(),
            'direction': 'incoming',
          });
          
          final completedChunks = (data['completedChunks'] as List?)?.map((e) => e as int).toSet() ?? {};
          final totalChunks = data['totalChunks'] as int? ?? 0;
          for (int i = 0; i < totalChunks; i++) {
            final status = completedChunks.contains(i) ? 'acked' : 'pending';
            batch.insert('chunks', {
              'id': '${data['transferId']}_$i',
              'transfer_id': data['transferId'],
              'chunk_index': i,
              'offset': i * (data['totalBytes'] ~/ data['totalChunks']),
              'length': 0,
              'status': status,
              'retry_count': 0,
            });
          }
        } catch (e) {
        }
      }
      await batch.commit(noResult: true);
    }

    final outgoingDir = Directory('${directory.path}/connect_transfers/outgoing');
    if (await outgoingDir.exists()) {
      final files = outgoingDir.listSync().whereType<File>().where((f) => f.path.endsWith('.progress'));
      final batch = db.batch();
      
      for (final file in files) {
        try {
          final jsonStr = await file.readAsString();
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          
          batch.insert('outgoing_progress', {
            'transfer_id': data['transferId'],
            'device_id': data['deviceId'],
            'file_name': data['fileName'],
            'file_path': data['filePath'],
            'total_bytes': data['totalBytes'],
            'acknowledged_chunks': jsonEncode(data['acknowledgedChunks'] ?? []),
            'last_updated': data['lastUpdated'],
          });
        } catch (e) {
        }
      }
      await batch.commit(noResult: true);
    }
  }
}