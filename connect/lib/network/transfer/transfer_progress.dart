import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

class TransferProgress {
  final String transferId;
  final String deviceId;
  final String fileName;
  final String filePath;
  final int totalBytes;
  final int totalChunks;
  final Set<int> completedChunks;
  String? _fileHash;
  DateTime lastUpdated;

  TransferProgress({
    required this.transferId,
    required this.deviceId,
    required this.fileName,
    required this.filePath,
    required this.totalBytes,
    required this.totalChunks,
    required this.completedChunks,
    String? fileHash,
    required this.lastUpdated,
  }) : _fileHash = fileHash;

  String? get fileHash => _fileHash;

  set fileHash(String? value) {
    _fileHash = value;
  }

  factory TransferProgress.fromJson(Map<String, dynamic> json) {
    return TransferProgress(
      transferId: json['transferId'] as String,
      deviceId: json['deviceId'] as String,
      fileName: json['fileName'] as String,
      filePath: json['filePath'] as String,
      totalBytes: json['totalBytes'] as int,
      totalChunks: json['totalChunks'] as int,
      completedChunks: (json['completedChunks'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toSet() ??
          {},
      fileHash: json['fileHash'] as String?,
      lastUpdated: DateTime.parse(json['lastUpdated'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'transferId': transferId,
      'deviceId': deviceId,
      'fileName': fileName,
      'filePath': filePath,
      'totalBytes': totalBytes,
      'totalChunks': totalChunks,
      'completedChunks': completedChunks.toList(),
      'fileHash': fileHash,
      'lastUpdated': lastUpdated.toIso8601String(),
    };
  }

  // Save to SQLite
  Future<void> save(Database db) async {
    await db.insert('transfers', {
      'id': transferId,
      'device_id': deviceId,
      'type': 'file',
      'status': 'transferring',
      'file_name': fileName,
      'file_path': filePath,
      'total_bytes': totalBytes,
      'transferred_bytes': completedChunks.length * (totalBytes ~/ totalChunks),
      'total_chunks': totalChunks,
      'completed_chunks': completedChunks.length,
      'file_hash': fileHash,
      'created_at': lastUpdated.toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'direction': 'incoming',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // Load from SQLite
  static Future<TransferProgress?> load(Database db, String transferId) async {
    final maps = await db.query('transfers', where: 'id = ?', whereArgs: [transferId], limit: 1);
    if (maps.isEmpty) return null;
    return _mapToProgress(maps.first);
  }

  // Delete progress file (on completion)
  static Future<void> delete(Database db, String transferId) async {
    await db.delete('transfers', where: 'id = ?', whereArgs: [transferId]);
    await db.delete('chunks', where: 'transfer_id = ?', whereArgs: [transferId]);
  }

  // List all incomplete transfers
  static Future<List<TransferProgress>> listIncomplete(Database db) async {
    final maps = await db.query('transfers', where: "status IN ('transferring', 'queued')");
    return maps.map(_mapToProgress).toList();
  }

  // Check if chunk is already completed
  bool isChunkCompleted(int chunkIndex) => completedChunks.contains(chunkIndex);

  // Mark chunk as completed
  void markChunkCompleted(int chunkIndex) {
    completedChunks.add(chunkIndex);
  }

  // Calculate progress as percentage
  double get progress {
    if (totalChunks == 0) return 1.0;
    return completedChunks.length / totalChunks;
  }

  /// Calculate SHA-256 hash of the received file
  static Future<String> calculateFileHash(File file) async {
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // Verify file integrity
  Future<bool> verifyFileIntegrity(File file) async {
    if (fileHash == null) return true;
    final calculatedHash = await calculateFileHash(file);
    return calculatedHash == fileHash;
  }

  static TransferProgress _mapToProgress(Map<String, dynamic> map) {
    final totalChunks = map['total_chunks'] as int;
    final completedCount = (map['completed_chunks'] as int?) ?? 0;
    final completedChunks = <int>{};
    for (int i = 0; i < completedCount && i < totalChunks; i++) {
      completedChunks.add(i);
    }
    
    return TransferProgress(
      transferId: map['id'] as String,
      deviceId: map['device_id'] as String,
      fileName: map['file_name'] as String,
      filePath: map['file_path'] as String,
      totalBytes: map['total_bytes'] as int,
      totalChunks: totalChunks,
      completedChunks: completedChunks,
      fileHash: map['file_hash'] as String?,
      lastUpdated: DateTime.parse(map['updated_at'] as String),
    );
  }

  }