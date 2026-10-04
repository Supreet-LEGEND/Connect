import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:connect/network/transfer/transfer_progress.dart';
import 'package:connect/network/transfer/transfer_manager.dart';
import 'package:connect/network/crypto/device_identity.dart';

class DatabaseHelper {
  static const _dbName = 'connect.db';
  static const _version = 1;
  static Database? _database;

  static Future<Database> init() async {
    if (_database != null) return _database!;
    
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/connect.db';
    
    _database = await openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode = WAL;');
        await db.execute('PRAGMA busy_timeout = 5000;');
        await db.execute('PRAGMA synchronous = NORMAL;');
      },
    );
    
    return _database!;
  }

  static Future<void> _onCreate(Database db, int version) async {
    // Transfers table
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

    // Chunks table (normalized for resume efficiency)
    await db.execute('''
      CREATE TABLE chunks (
        id TEXT PRIMARY KEY,
        transfer_id TEXT NOT NULL REFERENCES transfers(id) ON DELETE CASCADE,
        chunk_index INTEGER NOT NULL,
        offset INTEGER NOT NULL,
        length INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        retry_count INTEGER DEFAULT 0,
        sent_at TEXT,
        acked_at TEXT,
        last_error TEXT,
        FOREIGN KEY (transfer_id) REFERENCES transfers(id)
      )
    ''');

    // Indexes for common queries
    await db.execute('CREATE INDEX idx_chunks_transfer_status ON chunks(transfer_id, status)');
    await db.execute('CREATE INDEX idx_transfers_device_status ON transfers(device_id, status)');
    await db.execute('CREATE INDEX idx_transfers_updated ON transfers(updated_at)');

    // Trust store
    await db.execute('''
      CREATE TABLE trust_store (
        fingerprint TEXT PRIMARY KEY,
        alias TEXT,
        trusted_at TEXT NOT NULL,
        policy TEXT NOT NULL DEFAULT 'tofu',
        verified_at TEXT
      )
    ''');

    // Devices / Peers
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

    // Transfer cache (outgoing progress)
    await db.execute('''
      CREATE TABLE outgoing_progress (
        transfer_id TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        file_name TEXT,
        file_path TEXT,
        total_bytes INTEGER,
        acknowledged_chunks TEXT,
        last_updated TEXT NOT NULL
      )
    ''');
  }

  static Future<Database> get database async => init();

  static Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}

/// Migration from JSON files to SQLite
class DatabaseMigration {
  static Future<void> migrateFromJson() async {
    final db = await DatabaseHelper.init();
    final directory = await getApplicationDocumentsDirectory();
    
    // 1. Migrate trust store
    final trustStoreFile = File('${directory.path}/trust_store.json');
    if (await trustStoreFile.exists()) {
      try {
        final jsonStr = await trustStoreFile.readAsString();
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        
        final batch = DatabaseHelper._database!.batch();
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
        
        // Backup and delete
        await trustStoreFile.rename('${trustStoreFile.path}.bak');
      } catch (e) {
        // Ignore migration errors
      }
    }

    // 2. Migrate incoming progress files
    final progressDir = Directory('${directory.path}/connect_transfers/progress');
    if (await progressDir.exists()) {
      final files = progressDir.listSync().whereType<File>().where((f) => f.path.endsWith('.progress'));
      final batch = DatabaseHelper._database!.batch();
      
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
          
          // Migrate chunks
          final completedChunks = (data['completedChunks'] as List?)?.map((e) => e as int).toSet() ?? {};
          final totalChunks = data['totalChunks'] as int? ?? 0;
          for (int i = 0; i < totalChunks; i++) {
            final status = completedChunks.contains(i) ? 'acked' : 'pending';
            batch.insert('chunks', {
              'id': '${data['transferId']}_$i',
              'transfer_id': data['transferId'],
              'chunk_index': i,
              'offset': i * (data['totalBytes'] ~/ data['totalChunks']),
              'length': 0, // Unknown from old format
              'status': status,
              'retry_count': 0,
            });
          }
        } catch (e) {
          // Skip corrupted files
        }
      }
      await batch.commit(noResult: true);
    }

    // 3. Migrate outgoing progress files
    final outgoingDir = Directory('${directory.path}/connect_transfers/outgoing');
    if (await outgoingDir.exists()) {
      final files = outgoingDir.listSync().whereType<File>().where((f) => f.path.endsWith('.progress'));
      final batch = DatabaseHelper._database!.batch();
      
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
          // Skip corrupted files
        }
      }
      await batch.commit(noResult: true);
    }
  }
}