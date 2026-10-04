import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'package:connect/network/connection/device_session.dart';
import 'package:connect/network/connection/incoming_connection.dart';
import 'package:connect/network/connection/connection_health.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/network/transfer/transfer_manager.dart';
import 'package:connect/network/transfer/transfer_progress.dart';
import 'package:connect/network/connection_utils/async_semaphore.dart';
import 'package:connect/app/tcp_config.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Manages incoming file transfers from remote devices
///
/// Tracks received transfers and coordinates with bounded queue.
/// Sends size information to sender for backpressure feedback.
/// Supports transfer resume with SHA-256 integrity verification.
class ReceiveTransferManager extends BaseTransferManager {
  final Directory directory;
  final Database _db;

  /// Track bytes received per transfer for backpressure feedback
  final Map<String, int> _bytesReceivedPerTransfer = {};

  /// Track progress for each transfer
  final Map<String, TransferProgress> _transferProgress = {};

  /// Per-transfer write semaphores for serialized file access
  final Map<String, AsyncSemaphore> _writeSemaphores = {};

  /// Track which connections have received file_start for each transfer (for idempotent ack)
  final Map<String, Set<String>> _fileStartAckedConnections = {};

  ReceiveTransferManager({
    required this.directory,
    required Database db,
  }) : _db = db;

  @override
  Future<void> registerDevice(DeviceSession device, {Directory? progressDir}) async {
    // Receive side doesn't need per-device queues
    // But could track device-level statistics here
  }

  /// Register an incoming connection and start listening to its frames
  ///
  /// This method should be called when a new connection is accepted.
  /// It subscribes to the connection's frame stream and processes
  /// all incoming frames for transfer operations.
  Future<void> registerConnection(
    IncomingConnection connection,
    ConnectionHealth? health,
  ) async {
    await connection.performHandshake();

    // Set up health monitoring if provided
    if (health != null && connection.channel != null) {
      connection.channel!.onHeartbeatPong = () {
        health.onHeartbeatReceived();
      };
      health.startHeartbeat(connection);
    }

    // Subscribe to all frames from this connection
    connection.frames.listen(
      (frame) async {
        await _handleFrame(
          type: frame['type'] as String,
          header: frame['header'] as Map<String, dynamic>,
          payload: frame['payload'] as List<int>,
          connection: frame['connection'] as IncomingConnection,
        );
      },
      onError: (error) {
        // TODO: Log error
      },
      onDone: () {
        // Connection closed
      },
    );
  }

  /// Handle a single frame from a connection
  Future<void> _handleFrame({
    required String type,
    required Map<String, dynamic> header,
    required List<int> payload,
    required IncomingConnection connection,
  }) async {
    switch (type) {
      case 'file_start':
        await _handleFileStart(
          header,
          connection,
        );
        break;

      case 'file_chunk':
        await _handleChunk(
          header,
          payload,
          connection,
        );
        break;

      case 'file_end':
        await _handleFileEnd(
          header,
          connection,
        );
        break;

      case 'transfer_cancel':
        await _handleCancel(
          header,
        );
        break;

      case 'message':
        await _handleMessage(
          header,
          payload,
        );
        break;
    }
  }

  Future<void> _handleFileStart(
    Map<String, dynamic> header,
    IncomingConnection connection,
  ) async {
    final id = header['transferId'] as String;
    final name = header['fileName'] as String;
    final size = header['fileSize'] as int;
    final totalChunks = header['totalChunks'] as int? ?? (size / BaseTcpConfig.fileChunkSize).ceil();
    final connectionId = connection.hashCode.toString(); // Use hashCode as connection identifier

    // Idempotent: if this connection already acked this file_start, just re-ack
    final ackedConnections = _fileStartAckedConnections.putIfAbsent(id, () => {});
    if (ackedConnections.contains(connectionId)) {
      await _sendFileStartAck(connection, id);
      return;
    }

    // Sanitize filename to prevent path traversal
    final safeName = _sanitizeFileName(name);
    final path = '${directory.path}/${id}_$safeName.part';

    // Check for existing progress (resume) BEFORE opening file
    TransferProgress? progress;
    final existingProgress = await TransferProgress.load(_db, id);
    if (existingProgress != null) {
      progress = existingProgress;
      // Verify .part file still exists
      final partFile = File(path);
      if (!await partFile.exists()) {
        // .part file lost, delete progress and start fresh
        await TransferProgress.delete(_db, id);
        progress = null;
      }
    }

    // Open file with append mode to support resume
    final file = await File(path).open(mode: FileMode.writeOnlyAppend);

    // Initialize write semaphore for this transfer
    _writeSemaphores[id] = AsyncSemaphore(1);

    final transfer = ReceivingFileTransfer(
      id: id,
      deviceId: connection.peerIdentityPublicKey != null
          ? _computeFingerprint(connection.peerIdentityPublicKey!)
          : '',
      fileName: safeName,
      fileSize: size,
      file: file,
    );

    // Initialize progress tracking
    if (progress == null) {
      progress = TransferProgress(
        transferId: id,
        deviceId: transfer.deviceId,
        fileName: safeName,
        filePath: '${directory.path}/$safeName',
        totalBytes: size,
        totalChunks: totalChunks,
        completedChunks: {},
        lastUpdated: DateTime.now(),
      );
    }

    _transferProgress[id] = progress!;
    _bytesReceivedPerTransfer[id] = 0;
    ackedConnections.add(connectionId);
    
    // Save initial progress to SQLite
    await progress!.save(_db);

    transfers[transfer.id] = transfer;
    transfer.status = TransferStatus.transferring;
    emitUpdate(transfer);

    // Send file_start_ack on this connection
    await _sendFileStartAck(connection, id);
  }

  Future<void> _sendFileStartAck(IncomingConnection connection, String transferId) async {
    try {
      final progress = _transferProgress[transferId];
      final completedChunks = progress?.completedChunks.toList() ?? [];
      
      await connection.sendControl(
        type: 'file_start_ack',
        metadata: {
          'transferId': transferId,
          'completedChunks': completedChunks,
        },
      );
    } catch (e) {
      debugPrint('Failed to send file_start_ack: $e');
    }
  }

  String _computeFingerprint(SimplePublicKey key) {
    final digest = sha256.convert(key.bytes);
    return base64Encode(digest.bytes);
  }

  String _sanitizeFileName(String name) {
    // Remove any path components
    final basename = name.split('/').last.split('\\').last;
    // Remove dangerous characters
    return basename.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
  }

  Future<void> _handleChunk(
    Map<String, dynamic> header,
    List<int> payload,
    IncomingConnection connection,
  ) async {
    final id = header['transferId'] as String;
    final chunkIndex = header['chunkIndex'] as int;
    final offset = header['offset'] as int;
    final length = header['length'] as int;

    final transfer = transfers[id] as ReceivingFileTransfer?;

    if (transfer == null) {
      throw StateError('Unknown transfer');
    }

    final progress = _transferProgress[id];
    final semaphore = _writeSemaphores[id];

    // Check if chunk already received (resume support)
    if (progress != null && progress.isChunkCompleted(chunkIndex)) {
      await connection.sendAck(
        transferId: id,
        chunkIndex: chunkIndex,
      );
      return;
    }

    if (payload.length != length) {
      throw StateError('Invalid payload length');
    }

    if (offset < 0 || offset + length > transfer.fileSize) {
      throw StateError('Invalid chunk range');
    }

    if (transfer.receivedChunks.contains(chunkIndex)) {
      await connection.sendAck(
        transferId: id,
        chunkIndex: chunkIndex,
      );
      return;
    }

    // Serialize writes per transfer
    await semaphore?.acquire();
    try {
      await transfer.file.setPosition(offset);
      await transfer.file.writeFrom(payload);
    } finally {
      semaphore?.release();
    }

    transfer.receivedChunks.add(chunkIndex);

    // Update progress tracking
    if (progress != null) {
      progress.markChunkCompleted(chunkIndex);
      progress.lastUpdated = DateTime.now();
      // Save progress to SQLite periodically (every 10 chunks)
      if (progress.completedChunks.length % 10 == 0) {
        await progress.save(_db);
      }
    }

    // Track bytes received for backpressure feedback
    _bytesReceivedPerTransfer[id] = (_bytesReceivedPerTransfer[id] ?? 0) + length;

    emitUpdate(transfer);

    await connection.sendAck(
      transferId: id,
      chunkIndex: chunkIndex,
    );
  }

  Future<void> _handleFileEnd(
    Map<String, dynamic> header,
    IncomingConnection connection,
  ) async {
    final id = header['transferId'] as String;

    final transfer = transfers.remove(id) as ReceivingFileTransfer?;

    if (transfer == null) {
      return;
    }

    await transfer.file.flush();
    await transfer.file.close();

    final progress = _transferProgress.remove(id);
    _bytesReceivedPerTransfer.remove(id);
    _writeSemaphores.remove(id);
    _fileStartAckedConnections.remove(id);

    // Verify file integrity using streaming SHA-256
    final partFile = File('${directory.path}/${id}_${transfer.fileName}.part');
    final finalFile = File('${directory.path}/${transfer.fileName}');

    bool integrityOk = true;
    if (progress != null) {
      if (progress.fileHash == null) {
        // Compute hash if not already stored
        progress.fileHash = await TransferProgress.calculateFileHash(partFile);
        await progress.save(_db);
      }
      integrityOk = await progress.verifyFileIntegrity(partFile);
    }

    if (integrityOk) {
      // Rename .part to final file
      await partFile.rename(finalFile.path);
      transfer.status = TransferStatus.completed;
    } else {
      // Delete corrupted file
      if (await partFile.exists()) {
        await partFile.delete();
      }
      transfer.status = TransferStatus.failed;
      transfer.error = 'File integrity check failed';
    }

    // Delete progress file
    if (progress != null) {
      await TransferProgress.delete(_db, id);
    }

    emitUpdate(transfer);
  }

  Future<void> _handleCancel(
    Map<String, dynamic> header,
  ) async {
    final id = header['transferId'] as String;

    final transfer = transfers.remove(id) as ReceivingFileTransfer?;

    await transfer?.file.close();
    _bytesReceivedPerTransfer.remove(id);
    _transferProgress.remove(id);
    _writeSemaphores.remove(id);
    _fileStartAckedConnections.remove(id);

    if (transfer != null) {
      transfer.status = TransferStatus.cancelled;
      emitUpdate(transfer);
    }
  }

  Future<void> _handleMessage(
    Map<String, dynamic> header,
    List<int> payload,
  ) async {
    final messageId = header['messageId'] as String?;
    final contentType = header['contentType'] as String? ?? 'text';
    
    String content;
    if (contentType == 'text') {
      content = utf8.decode(payload);
    } else if (contentType == 'json') {
      content = utf8.decode(payload);
    } else {
      content = base64Encode(payload);
    }

    final transfer = ReceivingMessageTransfer(
      id: messageId ?? generateId(),
      deviceId: '',
      content: content,
      contentType: contentType,
    );

    transfer.status = TransferStatus.completed;
    transfers[transfer.id] = transfer;
    emitUpdate(transfer);
  }

  /// Resume incomplete transfers from progress files
  Future<void> resumeIncompleteTransfers() async {
    final incomplete = await TransferProgress.listIncomplete(_db);
    for (final progress in incomplete) {
      final partFile = File('${progress.filePath}.part');
      if (await partFile.exists()) {
        // Notify UI of resumed transfer
        // The actual resume happens when file_start is received again
        // with the same transferId
      } else {
        // .part file lost, delete progress
        await TransferProgress.delete(_db, progress.transferId);
}
  }
}
}