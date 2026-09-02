import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'package:connect/network/connection/device_session.dart';
import 'package:connect/network/connection_utils/async_semaphore.dart';
import 'package:connect/network/transfer/transfer.dart';

import '../connection/connection_manager.dart';

/// Bounded queue for managing frame transmission with backpressure
/// 
/// Uses fixed-size window (10MB default) to control memory and implement backpressure.
/// When window is full, sender must wait for ACKs before sending more frames.
class BoundedFrameQueue {
  /// Maximum bytes allowed in flight (not yet ACK'd)
  /// 10MB is standard for most networks
  final int maxBytesInFlight;

  /// Current bytes in flight
  int _bytesInFlight = 0;

  /// Completer that resolves when space becomes available
  Completer<void>? _waitingCompleter;

  BoundedFrameQueue({this.maxBytesInFlight = 10 * 1024 * 1024});

  /// Check if we can send frameSize bytes
  /// Returns true if within budget, false if need to wait
  bool canSend(int frameSize) {
    return _bytesInFlight + frameSize <= maxBytesInFlight;
  }

  /// Wait until there's space to send frameSize bytes
  /// Throws error if already waiting
  Future<void> waitForSpace(int frameSize) async {
    if (canSend(frameSize)) {
      return; // Already have space
    }

    if (_waitingCompleter != null && !_waitingCompleter!.isCompleted) {
      throw StateError('Already waiting for space');
    }

    _waitingCompleter = Completer<void>();
    await _waitingCompleter!.future;
  }

  /// Record that frameSize bytes were sent
  /// Must be called when frame is actually transmitted
  void recordSent(int frameSize) {
    _bytesInFlight += frameSize;
  }

  /// Record that frameSize bytes were ACK'd
  /// Signals any waiters that space is available
  void recordAck(int frameSize) {
    _bytesInFlight -= frameSize;

    if (_waitingCompleter != null && !_waitingCompleter!.isCompleted) {
      _waitingCompleter!.complete();
      _waitingCompleter = null;
    }
  }

  /// Get current window usage as percentage
  double getUsagePercent() {
    return (_bytesInFlight / maxBytesInFlight) * 100;
  }

  /// Get remaining space in bytes
  int getRemainingBytes() {
    return maxBytesInFlight - _bytesInFlight;
  }

  /// Reset the queue (used on transfer completion/error)
  void reset() {
    _bytesInFlight = 0;
    if (_waitingCompleter != null && !_waitingCompleter!.isCompleted) {
      _waitingCompleter!.complete();
    }
    _waitingCompleter = null;
  }
}

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
  Future<void> registerDevice(DeviceSession device);

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
/// Implements bounded queue with backpressure to control:
/// - Memory usage (max 10MB in flight)
/// - Network congestion (waits for ACKs before sending more)
/// - Quality of service (prioritizes messages over files)
class SendTransferManager extends BaseTransferManager {
  final ConnectionManager connectionManager;

  /// Bounded frame queue for each device (per-device backpressure)
  final Map<String, BoundedFrameQueue> _deviceQueues = {};

  /// Map of device ID to transfer scheduler
  /// TODO: Implement TransferScheduler when transfer_scheduler.dart is enabled
  final Map<String, dynamic> _schedulers = {};

  SendTransferManager({
    required this.connectionManager,
  });

  @override
  Future<void> registerDevice(DeviceSession device) async {
    // Create bounded queue for this device
    _deviceQueues[device.deviceId] = BoundedFrameQueue();

    // TODO: Initialize scheduler for this device when TransferScheduler is ready
    _schedulers[device.deviceId] = null;
  }

  /// Send a file to a device with backpressure
  /// 
  /// Returns immediately but transfers asynchronously.
  /// Respects bounded queue - will pause if window is full.
  Future<Transfer> sendFile({
    required String deviceId,
    required File file,
  }) async {
    final device = connectionManager.get(deviceId);

    if (device == null) {
      throw StateError('Device not connected');
    }

    final queue = _deviceQueues[deviceId];
    if (queue == null) {
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

    // Send file_start message
    await device.pool.connections.first.sendControl(
      type: 'file_start',
      metadata: {
        'transferId': transfer.id,
        'fileName': transfer.fileName,
        'fileSize': transfer.totalBytes,
      },
    );

    // Start producing chunks with backpressure
    await _produceChunksWithBackpressure(
      file: file,
      transfer: transfer,
      queue: queue,
      device: device,
    );

    return transfer;
  }

  /// Produce and send file chunks while respecting bounded queue backpressure
  Future<void> _produceChunksWithBackpressure({
    required File file,
    required FileTransfer transfer,
    required BoundedFrameQueue queue,
    required DeviceSession device,
  }) async {
    const chunkSize = 1024 * 1024; // 1MB chunks
    final fileSize = await file.length();
    final raf = await file.open(mode: FileMode.read);

    try {
      int offset = 0;
      int chunkIndex = 0;

      while (offset < fileSize) {
        final length = min(chunkSize, fileSize - offset);

        // BACKPRESSURE: Wait if queue is full
        // This naturally slows down reading to match network speed
        await queue.waitForSpace(length);

        await raf.setPosition(offset);
        final bytes = await raf.read(length);

        // TODO: Integrate with scheduler when TransferScheduler is ready
        // final chunk = TransferChunk(
        //   transfer: transfer,
        //   chunkIndex: chunkIndex,
        //   offset: offset,
        //   data: bytes,
        // );
        // scheduler.add(chunk);

        // Record bytes sent and update queue
        queue.recordSent(length);
        transfer.transferredBytes += length;
        emitUpdate(transfer);

        // TODO: Send chunk through connection
        // await device.pool.connections.first.send(
        //   type: 'file_chunk',
        //   metadata: {...},
        //   payload: bytes,
        // );

        offset += bytes.length;
        chunkIndex++;
      }

      // Send file_end message
      await device.pool.connections.first.sendControl(
        type: 'file_end',
        metadata: {
          'transferId': transfer.id,
          'fileName': transfer.fileName,
        },
      );

      transfer.status = TransferStatus.completed;
      emitUpdate(transfer);
    } finally {
      await raf.close();
      queue.reset(); // Clean up for next transfer
    }
  }

  @override
  Future<void> dispose() async {
    for (final queue in _deviceQueues.values) {
      queue.reset();
    }
    for (final scheduler in _schedulers.values) {
      if (scheduler != null) {
        // TODO: Call stop() when TransferScheduler is implemented
        // await scheduler.stop();
      }
    }
    await super.dispose();
  }
}