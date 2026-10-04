import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:connect/network/connection/device_session.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/network/transfer/transfer_job.dart';
import 'package:connect/network/transfer/transfer_scheduler.dart';
import 'package:connect/network/protocol/frame_parser.dart';
import 'package:connect/app/tcp_config.dart';

import '../connection/connection_manager.dart';

/// Abstract base class for all transfer management
///
/// Provides common interface for both sending and receiving transfers.
/// Subclasses implement specific strategies for each direction.
abstract class BaseTransferManager {
  /// Track all active transfers
  final Map<String, Transfer> transfers = {};

  /// Stream of transfer updates for UI/monitoring
  final StreamController<Transfer> _updateController =
      StreamController<Transfer>.broadcast();

  /// Get transfer updates stream
  Stream<Transfer> get updates => _updateController.stream;

  /// Register a device/connection for this manager
  /// Implementation varies: send tracks devices, receive tracks connections
  Future<void> registerDevice(DeviceSession device, {Directory? progressDir});

  /// Emit a transfer update to listeners
  void emitUpdate(Transfer transfer) {
    transfers[transfer.id] = transfer;
    _updateController.add(transfer);
  }

  /// Generate unique transfer ID
  String generateId() {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }

  /// Clean up resources
  Future<void> dispose() async {
    await _updateController.close();
  }
}

/// Manages outgoing file transfers to remote devices
///
/// Uses TransferScheduler for priority-based scheduling, rate limiting, and retry logic.
/// Implements striped multi-socket transfers with ACK-based flow control.
class SendTransferManager extends BaseTransferManager {
  final ConnectionManager connectionManager;
  final Database _db;

  /// Map of device ID to transfer scheduler
  final Map<String, TransferScheduler> _schedulers = {};

  /// Pending file_start_ack waiters
  final Map<String, Completer<void>> _fileStartAckWaiters = {};

  /// Track completed chunks per transfer for resume
  final Map<String, Set<int>> _acknowledgedChunks = {};

  SendTransferManager({
    required this.connectionManager,
    required Database db,
  }) : _db = db;

  @override
  Future<void> registerDevice(DeviceSession device, {Directory? progressDir}) async {
    _schedulers[device.deviceId] = TransferScheduler(
      pool: device.pool,
      config: const SchedulerConfig(
        maxRetries: 3,
        chunkTimeout: Duration(seconds: 30),
        enableBandwidthThrottling: true,
      ),
      onTransferProgress: (transfer) {
        emitUpdate(transfer);
      },
      onTransferCompleted: (transferId) {
        _onTransferCompleted(device.deviceId, transferId);
      },
    );
    await _schedulers[device.deviceId]!.start();

    // Listen for incoming acks on all connections
    for (final connection in device.pool.connections) {
      connection.frames.listen((frame) {
        _handleIncomingFrame(frame, connection.id);
      });
    }
  }

  /// Handle transfer completion (all chunks ACK'd)
  Future<void> _onTransferCompleted(String deviceId, String transferId) async {
    final device = connectionManager.get(deviceId);
    if (device == null) return;

    // Send file_end on all connections
    for (final connection in device.pool.connections) {
      try {
        await connection.sendControl(
          type: 'file_end',
          metadata: {
            'transferId': transferId,
          },
        );
      } catch (e) {
        debugPrint('Failed to send file_end on ${connection.id}: $e');
      }
    }

    // Update transfer status
    final transfer = transfers[transferId];
    if (transfer != null) {
      transfer.status = TransferStatus.completed;
      emitUpdate(transfer);
    }

    // Delete progress file on completion
    await _deleteOutgoingProgress(transferId);
  }

  /// Send a file to a device
  ///
  /// Returns immediately but transfers asynchronously.
  /// Uses TransferScheduler for priority queuing, rate limiting, and retries.
  Future<Transfer> sendFile({
    required String deviceId,
    required File file,
  }) async {
    final device = connectionManager.get(deviceId);

    if (device == null) {
      throw StateError('Device not connected');
    }

    final scheduler = _schedulers[deviceId];
    if (scheduler == null) {
      throw StateError('Device not registered');
    }

    final size = await file.length();

    final transfer = FileTransfer(
      id: generateId(),
      deviceId: deviceId,
      type: TransferType.file,
      filePath: file.path,
      fileName: file.uri.pathSegments.last,
      totalBytes: size,
    );

    transfers[transfer.id] = transfer;
    transfer.status = TransferStatus.transferring;
    emitUpdate(transfer);

    // Send file_start on ALL connections and wait for acks
    final ackCompleter = Completer<void>();
    _fileStartAckWaiters[transfer.id] = ackCompleter;

    for (final connection in device.pool.connections) {
      try {
        await connection.sendControl(
          type: 'file_start',
          metadata: {
            'transferId': transfer.id,
            'fileName': transfer.fileName,
            'fileSize': transfer.totalBytes,
            'totalChunks': (size / BaseTcpConfig.fileChunkSize).ceil(),
          },
        );
      } catch (e) {
        debugPrint('Failed to send file_start on ${connection.id}: $e');
      }
    }

    // Wait for file_start_ack from all connections (with timeout)
    try {
      await ackCompleter.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      debugPrint('Timeout waiting for file_start_ack for transfer ${transfer.id}');
    } finally {
      _fileStartAckWaiters.remove(transfer.id);
    }

    // Enqueue all chunks into the scheduler
    await _enqueueChunks(file, transfer, scheduler, device);

    return transfer;
  }

  /// Handle file_start_ack from receiver
  void handleFileStartAck(String transferId, String connectionId, {List<int> completedChunks = const []}) {
    final completer = _fileStartAckWaiters[transferId];
    if (completer != null && !completer.isCompleted) {
      // For simplicity, we just complete on first ack.
      // In a more robust implementation, we'd track acks per connection.
      completer.complete();
    }
    
    // Store acknowledged chunks for resume
    if (completedChunks.isNotEmpty) {
      _acknowledgedChunks[transferId] = completedChunks.toSet();
    }
  }

  /// Read file and enqueue all chunks into the scheduler
  Future<void> _enqueueChunks(
    File file,
    FileTransfer transfer,
    TransferScheduler scheduler,
    DeviceSession device,
  ) async {
    const chunkSize = BaseTcpConfig.fileChunkSize;
    final raf = await file.open(mode: FileMode.read);

    try {
      int offset = 0;
      int chunkIndex = 0;
      final fileSize = await file.length();

      // Get already acknowledged chunks for resume
      final acknowledgedChunks = _acknowledgedChunks[transfer.id] ?? {};

      while (offset < fileSize) {
        final length = min(chunkSize, fileSize - offset);
        
        // Skip already acknowledged chunks
        if (acknowledgedChunks.contains(chunkIndex)) {
          debugPrint('Skipping already acknowledged chunk $chunkIndex for transfer ${transfer.id}');
          offset += length;
          chunkIndex++;
          continue;
        }

        await raf.setPosition(offset);
        final bytes = await raf.read(length);

        final chunk = TransferChunk(
          transfer: transfer,
          chunkIndex: chunkIndex,
          offset: offset,
          data: bytes,
        );

        // Scheduler handles priority, rate limiting, retry, and actual sending
        scheduler.addChunk(chunk, priority: SchedulerPriority.file);

        offset += bytes.length;
        chunkIndex++;
      }
    } finally {
      await raf.close();
    }
  }
  void _handleIncomingFrame(ParsedFrame frame, String connectionId) {
    final type = frame.header['type'] as String?;
    if (type == null) return;

    switch (type) {
      case 'file_start_ack':
        _handleFileStartAck(frame, connectionId);
        break;
      case 'chunk_ack':
        _handleChunkAck(frame);
        break;
      case 'file_end_ack':
        // Handle file end ack if needed
        break;
    }
  }

  /// Handle file_start_ack from receiver
  void _handleFileStartAck(ParsedFrame frame, String connectionId) {
    final transferId = frame.header['transferId'] as String?;
    final completedChunks = (frame.header['completedChunks'] as List<dynamic>?)?.map((e) => e as int).toList() ?? [];
    
    if (transferId != null) {
      handleFileStartAck(transferId, connectionId, completedChunks: completedChunks);
    }
  }

  /// Handle chunk_ack from receiver
  void _handleChunkAck(ParsedFrame frame) {
    final transferId = frame.header['transferId'] as String?;
    final chunkIndex = frame.header['chunkIndex'] as int?;
    
    if (transferId != null && chunkIndex != null) {
      TransferScheduler? scheduler;
      for (final s in _schedulers.values) {
        if (s.getChunk('${transferId}_$chunkIndex') != null) {
          scheduler = s;
          break;
        }
      }
      if (scheduler != null) {
        scheduler.recordChunkAck('${transferId}_$chunkIndex');
        // Save progress after each chunk is acknowledged
        final transfer = transfers[transferId];
        if (transfer is FileTransfer) {
          _saveOutgoingProgress(transferId, transfer);
        }
      }
    }
  }

  /// Save outgoing transfer progress to SQLite
  Future<void> _saveOutgoingProgress(String transferId, FileTransfer transfer) async {
    try {
      final data = {
        'transferId': transfer.id,
        'deviceId': transfer.deviceId,
        'fileName': transfer.fileName,
        'filePath': transfer.filePath,
        'totalBytes': transfer.totalBytes,
        'acknowledgedChunks': _acknowledgedChunks[transferId]?.toList() ?? [],
        'lastUpdated': DateTime.now().toIso8601String(),
      };
      await _db.insert('outgoing_progress', {
        'transfer_id': transfer.id,
        'device_id': transfer.deviceId,
        'file_name': transfer.fileName,
        'file_path': transfer.filePath,
        'total_bytes': transfer.totalBytes,
        'acknowledged_chunks': jsonEncode(_acknowledgedChunks[transferId]?.toList() ?? []),
        'last_updated': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint('Failed to save outgoing progress for $transferId: $e');
    }
  }

  /// Delete outgoing progress file on completion
  Future<void> _deleteOutgoingProgress(String transferId) async {
    await _db.delete('outgoing_progress', where: 'transfer_id = ?', whereArgs: [transferId]);
  }

  @override
  Future<void> dispose() async {
    for (final scheduler in _schedulers.values) {
      await scheduler.dispose();
    }
    await super.dispose();
  }
}