import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:connect/network/transfer/isolate/commands.dart';
import 'package:connect/network/transfer/isolate/network_commands.dart' as net_cmds;
import 'package:connect/network/storage/database_helper.dart';
import 'package:connect/network/storage/database_helper_desktop.dart';
import 'package:connect/network/transfer/transfer_progress.dart';
import 'package:connect/app/tcp_config.dart';
import 'package:connect/app/transfer_config.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'package:sqflite_common/src/sqflite_database_factory.dart' show databaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactoryFfi;

class TransferIsolateParams {
  final SendPort networkSendPort;
  final SendPort mainSendPort;
  final RootIsolateToken rootIsolateToken;

  TransferIsolateParams({
    required this.networkSendPort,
    required this.mainSendPort,
    required this.rootIsolateToken,
  });
}

void transferIsolateEntrypoint(TransferIsolateParams params) {
  // Initialize binary messenger for platform channels (required for path_provider, etc.)
  BackgroundIsolateBinaryMessenger.ensureInitialized(params.rootIsolateToken);
  
  // Initialize sqflite for Windows (required for database access in background isolate)
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  
  // Initialize database helper for this isolate
  DatabaseHelper.initialize(DatabaseHelperDesktop.instance);

  final receivePort = ReceivePort();
  params.mainSendPort.send(receivePort.sendPort);

  final worker = _TransferIsolateWorker(
    networkSendPort: params.networkSendPort,
    mainSendPort: params.mainSendPort,
  );

  receivePort.listen((message) {
    if (message is TransferCommand) {
      worker.handleCommand(message);
    } else if (message is net_cmds.NetworkEvent) {
      worker.handleNetworkEvent(message);
    }
  });
}

class _TransferIsolateWorker {
  final SendPort networkSendPort;
  final SendPort mainSendPort;

  final Map<String, _DeviceSession> _deviceSessions = {};
  final Map<String, _ActiveTransfer> _activeTransfers = {};
  final Map<String, _SendWorker> _sendWorkers = {};
  final Map<String, _ReceiveWorker> _receiveWorkers = {};

  late final _SchedulerWorker _schedulerWorker;
  late final Database _db;

  Timer? _progressTimer;
  Timer? _healthCheckTimer;
  Timer? _statePersistenceTimer;
  bool _isRunning = true;

  _TransferIsolateWorker({
    required this.networkSendPort,
    required this.mainSendPort,
  }) {
    _initializeDatabase().then((_) {
      _schedulerWorker = _SchedulerWorker(
        networkSendPort: networkSendPort,
        mainSendPort: mainSendPort,
        deviceSessions: _deviceSessions,
        activeTransfers: _activeTransfers,
        sendWorkers: _sendWorkers,
        receiveWorkers: _receiveWorkers,
        db: _db,
      );
      _startTimers();
      _resumeIncompleteTransfers();
    });
  }

  Future<void> _initializeDatabase() async {
    _db = await DatabaseHelper.instance.init();
  }

  Future<void> _resumeIncompleteTransfers() async {
    try {
      // Resume outgoing transfers
      final outgoingResult = await _db.query(
        'outgoing_progress',
        where: 'status != ?',
        whereArgs: ['completed'],
      );
      for (final row in outgoingResult) {
        final transferId = row['transfer_id'] as String;
        if (!_activeTransfers.containsKey(transferId)) {
          // Transfer will be resumed when sender retries or app initiates
          // For now, just ensure the progress record exists
        }
      }

      // Resume incoming transfers - create _ActiveTransfer entries so they can be resumed when peer reconnects
      final incomingResult = await _db.query(
        'incoming_progress',
        where: 'status != ?',
        whereArgs: ['completed'],
      );
      for (final row in incomingResult) {
        final transferId = row['transfer_id'] as String;
        if (!_activeTransfers.containsKey(transferId)) {
          final deviceId = row['device_id'] as String;
          final fileName = row['file_name'] as String? ?? 'unknown_file';
          final filePath = row['file_path'] as String? ?? '';
          final totalBytes = row['total_bytes'] as int? ?? 0;
          final expectedHash = row['expected_hash'] as String?;

          final transfer = _ActiveTransfer(
            id: transferId,
            deviceId: deviceId,
            fileName: fileName,
            totalBytes: totalBytes,
            priority: SchedulerPriority.file,
            filePath: filePath,
            isOutgoing: false,
          );
          transfer.fileHash = expectedHash;

          // Load completed chunks from DB
          final completedChunksJson = row['completed_chunks'] as String?;
          if (completedChunksJson != null) {
            try {
              final list = jsonDecode(completedChunksJson) as List;
              transfer.completedChunks = list.length;
            } catch (_) {}
          }

          _activeTransfers[transferId] = transfer;
        }
      }
    } catch (e) {
      // Ignore resume errors
    }
  }

  void _startTimers() {
    _progressTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _emitProgressUpdates();
    });

    _healthCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      mainSendPort.send(const IsolateHealthEvent(true));
    });

    // Persist transfer state every 10 seconds
    _statePersistenceTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _persistTransferStates();
    });
  }

  Future<void> _persistTransferStates() async {
    try {
      for (final transfer in _activeTransfers.values) {
        if (transfer.status == TransferStatus.transferring || 
            transfer.status == TransferStatus.paused) {
          if (transfer.isOutgoing) {
            await _schedulerWorker.saveProgress(transfer.id, transfer);
          } else {
            await _receiveWorkers[transfer.deviceId]?.saveReceiveProgress(transfer);
          }
        }
      }
    } catch (e) {
      // Ignore persistence errors
    }
  }

  void _emitProgressUpdates() {
    for (final transfer in _activeTransfers.values) {
      if (transfer.status == TransferStatus.transferring) {
        mainSendPort.send(TransferProgressEvent(
          transferId: transfer.id,
          transferredBytes: transfer.transferredBytes,
          totalBytes: transfer.totalBytes,
          completedChunks: transfer.completedChunks,
          totalChunks: transfer.totalChunks,
          speedBytesPerSecond: transfer.speedBytesPerSecond,
          estimatedTimeRemaining: transfer.estimatedTimeRemaining,
        ));
      }
    }
  }

  void handleCommand(TransferCommand command) {
    switch (command) {
      case SendFileCommand cmd:
        _handleSendFile(cmd);
        break;
      case SendMessageCommand cmd:
        _handleSendMessage(cmd);
        break;
      case ControlCommand cmd:
        _handleControl(cmd);
        break;
      case PauseTransferCommand cmd:
        _schedulerWorker.pauseTransfer(cmd.transferId);
        break;
      case ResumeTransferCommand cmd:
        _schedulerWorker.resumeTransfer(cmd.transferId);
        break;
      case CancelTransferCommand cmd:
        _schedulerWorker.cancelTransfer(cmd.transferId, cmd.reason);
        break;
      case PrioritizeTransferCommand cmd:
        _schedulerWorker.prioritizeTransfer(cmd.transferId, cmd.priority);
        break;
      case ConnectDeviceCommand cmd:
        _handleConnectDevice(cmd);
        break;
      case DisconnectDeviceCommand cmd:
        _handleDisconnectDevice(cmd.deviceId);
        break;
      case UpdateConnectionStateCommand cmd:
        _handleConnectionState(ConnectionStateEvent(cmd.deviceId, cmd.state, error: cmd.error));
        break;
      case GetTransfersCommand cmd:
        _handleGetTransfers();
        break;
      case GetTransferStatusCommand cmd:
        _handleGetTransferStatus(cmd.transferId);
        break;
      case ShutdownCommand cmd:
        _shutdown();
        break;
      case UpdateConfigCommand cmd:
        _handleUpdateConfig(cmd);
        break;
    }
  }

  void _handleUpdateConfig(UpdateConfigCommand cmd) {
    if (cmd.chunkSize != null) {
      TransferConfig.fileChunkSize = cmd.chunkSize!;
    }
    if (cmd.maxConcurrentTransfers != null) {
      TransferConfig.maxConcurrentTransfers = cmd.maxConcurrentTransfers!;
    }
    if (cmd.enableBandwidthThrottling != null) {
      TransferConfig.enableBandwidthThrottling = cmd.enableBandwidthThrottling!;
    }
    if (cmd.maxBytesPerSecond != null) {
      TransferConfig.maxBytesPerSecond = cmd.maxBytesPerSecond!;
    }
    if (cmd.activeWindowSize != null) {
      TransferConfig.activeWindowSize = cmd.activeWindowSize!;
    }
    // Forward to Network Isolate
    networkSendPort.send(net_cmds.UpdateConfigCommand(
      chunkSize: cmd.chunkSize,
      maxConcurrentTransfers: cmd.maxConcurrentTransfers,
      enableBandwidthThrottling: cmd.enableBandwidthThrottling,
      maxBytesPerSecond: cmd.maxBytesPerSecond,
      activeWindowSize: cmd.activeWindowSize,
    ));
  }

  void handleNetworkEvent(net_cmds.NetworkEvent event) {
    switch (event) {
      case net_cmds.FrameReceivedEvent frame:
        _schedulerWorker.handleFrame(frame);
        break;
      case ConnectionStateEvent state:
        _handleConnectionState(state);
        break;
      case net_cmds.ConnectionStatsEvent stats:
        break;
      case net_cmds.NetworkErrorEvent error:
        _handleNetworkError(error.connectionId, error.error);
        break;
      case IsolateHealthEvent health:
        break;
      case net_cmds.DeviceConnectionsEvent event:
        _handleDeviceConnections(event);
        break;
      default:
        break;
    }
  }

  void _handleDeviceConnections(net_cmds.DeviceConnectionsEvent event) {
    // Update device session with connection IDs
    final session = _deviceSessions[event.deviceId];
    if (session != null) {
      session.connectionIds
        ..clear()
        ..addAll(event.connectionIds);
    }

    // Update SendWorker's connection health with available connections
    final sendWorker = _sendWorkers[event.deviceId];
    if (sendWorker != null) {
      sendWorker.updateAvailableConnections(event.connectionIds);
    }
  }

  void _handleSendFile(SendFileCommand cmd) {
    final session = _deviceSessions[cmd.deviceId];
    if (session == null) {
      mainSendPort.send(TransferFailedEvent(cmd.transferId, 'Device not connected'));
      return;
    }

    final transfer = _ActiveTransfer(
      id: cmd.transferId,
      deviceId: cmd.deviceId,
      fileName: cmd.fileName,
      totalBytes: cmd.fileSize,
      priority: cmd.priority,
      filePath: cmd.filePath,
      isOutgoing: true,
    );

    _activeTransfers[cmd.transferId] = transfer;
    _schedulerWorker.addTransfer(transfer, session);
    mainSendPort.send(TransferQueuedEvent(
      transferId: cmd.transferId,
      deviceId: cmd.deviceId,
      fileName: cmd.fileName,
      totalBytes: cmd.fileSize,
    ));
  }

  void _handleSendMessage(SendMessageCommand cmd) {
    final session = _deviceSessions[cmd.deviceId];
    if (session == null) {
      mainSendPort.send(TransferFailedEvent(cmd.transferId, 'Device not connected'));
      return;
    }

    final transfer = _ActiveTransfer(
      id: cmd.transferId,
      deviceId: cmd.deviceId,
      fileName: 'message',
      totalBytes: cmd.content.length,
      priority: SchedulerPriority.message,
      isOutgoing: true,
      messageContent: cmd.content,
      messageContentType: cmd.contentType,
    );

    _activeTransfers[cmd.transferId] = transfer;
    _schedulerWorker.addTransfer(transfer, session);
  }

  void _handleControl(ControlCommand cmd) {
    final session = _deviceSessions[cmd.deviceId];
    if (session == null) return;

    // Send control only on first connection to avoid duplication
    final connectionId = session.connectionIds.first;
    networkSendPort.send(net_cmds.SendFrameCommand(
      connectionId: connectionId,
      type: 'control',
      header: {
        'transferId': cmd.transferId,
        ...cmd.payload,
      },
      payload: Uint8List(0),
      priority: SchedulerPriority.control,
    ));
  }

  void _handleConnectDevice(ConnectDeviceCommand cmd) {
    final existingSession = _deviceSessions[cmd.deviceId];
    final connectionIds = existingSession?.connectionIds ??
        List.generate(4, (i) => '${cmd.deviceId}-$i');

    // Update existing session or create new one, preserving workers
    if (existingSession != null) {
      existingSession.connectionIds
        ..clear()
        ..addAll(connectionIds);
    } else {
      _deviceSessions[cmd.deviceId] = _DeviceSession(
        deviceId: cmd.deviceId,
        connectionIds: connectionIds,
      );
    }

    final connectionId = connectionIds.first;
    networkSendPort.send(net_cmds.ConnectCommand(
      connectionId: connectionId,
      deviceId: cmd.deviceId,
      host: cmd.host,
      port: cmd.port,
      trustPolicy: cmd.trustPolicy,
    ));
  }

  void _handleDisconnectDevice(String deviceId) {
    final session = _deviceSessions.remove(deviceId);
    if (session != null) {
      for (final connectionId in session.connectionIds) {
        networkSendPort.send(net_cmds.DisconnectCommand(connectionId));
      }
      _sendWorkers.remove(deviceId)?.dispose();
      _receiveWorkers.remove(deviceId)?.dispose();
    }
    mainSendPort.send(ConnectionStateEvent(deviceId, ConnectionState.disconnected));
  }

  void _handleGetTransfers() {
    final transfers = _activeTransfers.values.map((t) => t.toInfo()).toList();
    mainSendPort.send(TransfersListEvent(transfers));
  }

  void _handleGetTransferStatus(String transferId) {
    final transfer = _activeTransfers[transferId];
    if (transfer != null) {
      mainSendPort.send(TransferStatusEvent(transfer.toInfo()));
    }
  }

  void _handleConnectionState(ConnectionStateEvent event) {
    mainSendPort.send(event);

    final deviceId = event.deviceId;
    if (deviceId == null) return;

    if (event.state == ConnectionState.connected) {
      // Find or create device session and start receive worker
      final session = _deviceSessions.putIfAbsent(deviceId, () => _DeviceSession(
        deviceId: deviceId,
        connectionIds: [],
      ));
      
      // Note: Connection IDs are updated via UpdateDeviceConnectionsCommand from Network Isolate
      // We don't add event.deviceId here since it's now the actual deviceId, not a connectionId

      if (!_receiveWorkers.containsKey(deviceId)) {
        _receiveWorkers[deviceId] = _ReceiveWorker(
          deviceId: deviceId,
          connectionIds: session.connectionIds,
          networkSendPort: networkSendPort,
          mainSendPort: mainSendPort,
          db: _db,
          activeTransfers: _activeTransfers,
          schedulerWorker: _schedulerWorker,
        );
      }
    } else if (event.state == ConnectionState.disconnected || event.state == ConnectionState.failed) {
      _cleanupDeviceTransfers(deviceId);
      _receiveWorkers.remove(deviceId)?.dispose();
    }
  }

  void _cleanupDeviceTransfers(String deviceId) {
    // Cancel all in-flight transfers for this device
    final transfersToCancel = _activeTransfers.entries
        .where((e) => e.value.deviceId == deviceId && 
            (e.value.status == TransferStatus.transferring || e.value.status == TransferStatus.queued))
        .map((e) => e.key)
        .toList();

    for (final transferId in transfersToCancel) {
      _schedulerWorker.cancelTransfer(transferId, 'Device disconnected');
    }

    // Clean up send worker unacked chunks
    final sendWorker = _sendWorkers[deviceId];
    sendWorker?.clearDeviceUnackedChunks();
    
    // Clear connection health for this device
    sendWorker?.clearDeviceHealth(deviceId);
  }

  void _handleNetworkError(String connectionId, String error) {
    for (final entry in _deviceSessions.entries) {
      if (entry.value.connectionIds.contains(connectionId)) {
        mainSendPort.send(ConnectionStateEvent(entry.key, ConnectionState.failed, error: error));
        break;
      }
    }
  }

  void _shutdown() {
    _isRunning = false;
    _progressTimer?.cancel();
    _healthCheckTimer?.cancel();
    _statePersistenceTimer?.cancel();

    for (final worker in _sendWorkers.values) {
      worker.dispose();
    }
    for (final worker in _receiveWorkers.values) {
      worker.dispose();
    }
    _schedulerWorker.dispose();
    _db.close();

    mainSendPort.send(const IsolateHealthEvent(false, error: 'Shutdown'));
  }
}

class _DeviceSession {
  final String deviceId;
  final List<String> connectionIds;

  _DeviceSession({
    required this.deviceId,
    required this.connectionIds,
  });
}

class _ProgressLock {
  bool _locked = false;
  final List<Completer<void>> _waiters = [];

  Future<void> acquire() async {
    if (!_locked) {
      _locked = true;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _locked = false;
    }
  }
}

class _ActiveTransfer {
  final String id;
  final String deviceId;
  final String fileName;
  final int totalBytes;
  final SchedulerPriority priority;
  String? filePath;
  final bool isOutgoing;
  final String? messageContent;
  final String? messageContentType;

  int transferredBytes = 0;
  int completedChunks = 0;
  int totalChunks = 0;
  TransferStatus status = TransferStatus.queued;
  final DateTime startedAt = DateTime.now();
  DateTime? completedAt;
  String? error;
  String? fileHash;

  // For speed calculation - protected by lock
  final List<_ProgressSample> _progressSamples = [];
  final _ProgressLock _progressLock = _ProgressLock();

  _ActiveTransfer({
    required this.id,
    required this.deviceId,
    required this.fileName,
    required this.totalBytes,
    required this.priority,
    this.filePath,
    this.isOutgoing = true,
    this.messageContent,
    this.messageContentType,
  });

  double get speedBytesPerSecond {
    if (_progressSamples.length < 2) return 0;
    final now = DateTime.now();
    final recent = _progressSamples.where((s) => now.difference(s.time).inSeconds <= 5).toList();
    if (recent.length < 2) return 0;
    final first = recent.first;
    final last = recent.last;
    final timeDiff = last.time.difference(first.time).inMilliseconds;
    if (timeDiff == 0) return 0;
    return (last.bytes - first.bytes) / (timeDiff / 1000);
  }

  Duration? get estimatedTimeRemaining {
    final speed = speedBytesPerSecond;
    if (speed <= 0) return null;
    final remaining = totalBytes - transferredBytes;
    return Duration(seconds: (remaining / speed).ceil());
  }

  void recordProgress(int bytes) async {
    await _progressLock.acquire();
    try {
      transferredBytes = bytes;
      _progressSamples.add(_ProgressSample(DateTime.now(), bytes));
      // Keep only last 30 seconds of samples
      final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
      _progressSamples.removeWhere((s) => s.time.isBefore(cutoff));
    } finally {
      _progressLock.release();
    }
  }

  TransferInfo toInfo() => TransferInfo(
    id: id,
    deviceId: deviceId,
    fileName: fileName,
    totalBytes: totalBytes,
    transferredBytes: transferredBytes,
    status: status,
    priority: priority,
    startedAt: startedAt,
    completedAt: completedAt,
    error: error,
  );
}

class _ProgressSample {
  final DateTime time;
  final int bytes;

  _ProgressSample(this.time, this.bytes);
}

class _SchedulerWorker {
  final SendPort networkSendPort;
  final SendPort mainSendPort;
  final Map<String, _DeviceSession> deviceSessions;
  final Map<String, _ActiveTransfer> activeTransfers;
  final Map<String, _SendWorker> sendWorkers;
  final Map<String, _ReceiveWorker> receiveWorkers;
  final Database db;

  final Map<String, _TransferQueue> _queues = {};
  final Map<String, _ScheduledChunk> _allChunks = {};
  final Set<String> _pausedTransfers = {};
  final Map<String, int> _chunkAckCounts = {};

  _SchedulerWorker({
    required this.networkSendPort,
    required this.mainSendPort,
    required this.deviceSessions,
    required this.activeTransfers,
    required this.sendWorkers,
    required this.receiveWorkers,
    required this.db,
  });

  void addTransfer(_ActiveTransfer transfer, _DeviceSession session) {
    final queue = _getOrCreateQueue(session.deviceId);
    final sendWorker = _getOrCreateSendWorker(session.deviceId);

    // Chunk the file
    _chunkFile(transfer, queue);
  }

  Future<void> _chunkFile(_ActiveTransfer transfer, _TransferQueue queue) async {
    if (transfer.filePath == null) return;

    final file = File(transfer.filePath!);
    if (!await file.exists()) {
      _failTransfer(transfer.id, 'File not found');
      return;
    }

    final fileSize = await file.length();
    final chunkSize = _calculateChunkSize(fileSize);
    int offset = 0;
    int chunkIndex = 0;

    // Initialize streaming hash calculator using AccumulatorSink
    final hashAccumulator = TransferConfig.enableStreamingHash ? _StreamingHashAccumulator() : null;

    // Load acknowledged chunks from DB for resume
    final acknowledgedChunks = await _loadAcknowledgedChunks(transfer.id);

    final raf = await file.open(mode: FileMode.read);

    try {
      while (offset < fileSize) {
        final length = chunkSize.clamp(0, fileSize - offset);

        if (!acknowledgedChunks.contains(chunkIndex)) {
          Uint8List bytes;
          
          // Use mmap for zero-copy reads on large files if enabled
          if (TransferConfig.enableMmap && fileSize > TransferConfig.mediumFileThreshold) {
            bytes = await _readFileMmap(raf, offset, length);
          } else {
            await raf.setPosition(offset);
            bytes = await raf.read(length);
          }

          // Add to streaming hash
          if (hashAccumulator != null) {
            hashAccumulator.add(bytes);
          }

          final chunk = _ScheduledChunk(
            id: '${transfer.id}_$chunkIndex',
            chunkIndex: chunkIndex,
            offset: offset,
            length: length,
            data: bytes,
            priority: transfer.priority,
            transferId: transfer.id,
            deviceId: transfer.deviceId,
          );

          _allChunks[chunk.id] = chunk;
          queue.add(chunk);
          transfer.totalChunks++;
        } else {
          transfer.completedChunks++;
          transfer.transferredBytes += length;
        }

        offset += length;
        chunkIndex++;
      }
    } finally {
      await raf.close();
    }

    // Finalize hash
    if (hashAccumulator != null) {
      transfer.fileHash = hashAccumulator.finalize();
      await _saveFileHash(transfer.id, transfer.fileHash!);
    }

    // Verify hash on resume if we have an expected hash
    if (transfer.fileHash != null && acknowledgedChunks.isNotEmpty) {
      final isValid = await _verifyPartialHash(transfer.filePath!, acknowledgedChunks, transfer.fileHash!, fileSize, chunkSize);
      if (!isValid) {
        _failTransfer(transfer.id, 'Hash verification failed on resume - file may be corrupted');
        return;
      }
    }

    transfer.totalChunks = chunkIndex;
    transfer.status = TransferStatus.transferring;

    // Determine file path for sender (for reference) and include in file_start
    final filePath = transfer.filePath ?? '';

    // Send file_start message to receiver with file hash and path
    final session = deviceSessions[transfer.deviceId];
    if (session != null && session.connectionIds.isNotEmpty) {
      final connectionId = session.connectionIds.first;
      networkSendPort.send(net_cmds.SendFrameCommand(
        connectionId: connectionId,
        type: 'file_start',
        header: {
          'transferId': transfer.id,
          'fileName': transfer.fileName,
          'totalBytes': transfer.totalBytes,
          'totalChunks': transfer.totalChunks,
          'fileHash': transfer.fileHash,
          'filePath': filePath,
        },
        payload: Uint8List(0),
        priority: SchedulerPriority.control,
      ));
    }

    // Start send worker if not running
    final sendWorker = sendWorkers[transfer.deviceId];
    sendWorker?.start();
  }

  int _calculateChunkSize(int fileSize) {
    if (!TransferConfig.enableDynamicChunking) {
      return TransferConfig.chunkSizeDefault;
    }

    if (fileSize >= TransferConfig.largeFileThreshold) {
      return TransferConfig.chunkSizeLarge;
    } else if (fileSize >= TransferConfig.mediumFileThreshold) {
      return TransferConfig.chunkSizeMedium;
    } else {
      return TransferConfig.chunkSizeSmall;
    }
  }

  Future<Uint8List> _readFileMmap(RandomAccessFile raf, int offset, int length) async {
    // Use readInto with pre-allocated buffer for zero-copy
    final buffer = Uint8List(length);
    await raf.setPosition(offset);
    final bytesRead = await raf.readInto(buffer);
    if (bytesRead < length) {
      return buffer.sublist(0, bytesRead);
    }
    return buffer;
  }

  Future<void> _saveFileHash(String transferId, String hash) async {
    try {
      await db.insert('outgoing_progress', {
        'transfer_id': transferId,
        'file_hash': hash,
        'last_updated': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  Future<bool> _verifyPartialHash(String filePath, Set<int> completedChunks, String expectedHash, int fileSize, int chunkSize) async {
    // Skip full file hash verification on resume for performance
    // The receiver will verify chunk integrity during transfer and full hash at completion
    // Only verify if no chunks were acknowledged (fresh transfer) or file is small
    if (completedChunks.isEmpty) {
      return true; // Fresh transfer, no need to verify
    }
    if (fileSize < 100 * 1024 * 1024) { // 100MB threshold
      try {
        final file = File(filePath);
        if (!await file.exists()) return false;
        final actualHash = await _computeFullFileHash(file);
        return actualHash == expectedHash;
      } catch (e) {
        return false;
      }
    }
    // For large files with partial progress, trust acknowledged chunks
    // Full verification happens at transfer completion
    return true;
  }

  Future<String> _computeFullFileHash(File file) async {
    final hashAccumulator = _StreamingHashAccumulator();
    final fileSize = await file.length();
    final raf = await file.open(mode: FileMode.read);

    try {
      // Read entire file in chunks
      const chunkSize = 64 * 1024; // 64KB chunks
      int offset = 0;
      while (offset < fileSize) {
        final length = chunkSize.clamp(0, fileSize - offset);
        await raf.setPosition(offset);
        final bytes = await raf.read(length);
        hashAccumulator.add(bytes);
        offset += length;
      }
    } finally {
      await raf.close();
    }

    return hashAccumulator.finalize();
  }

  Future<Set<int>> _loadAcknowledgedChunks(String transferId) async {
    try {
      final result = await db.query(
        'outgoing_progress',
        where: 'transfer_id = ?',
        whereArgs: [transferId],
      );
      if (result.isNotEmpty) {
        final chunksJson = result.first['completed_chunks'] as String?;
        if (chunksJson != null) {
          final list = jsonDecode(chunksJson) as List;
          return list.map((e) => e as int).toSet();
        }
      }
    } catch (_) {}
    return {};
  }

  void handleFrame(net_cmds.FrameReceivedEvent frame) {
    final type = frame.type;
    final header = frame.header;
    final transferId = header['transferId'] as String?;

    if (transferId == null) return;

    switch (type) {
      case 'chunk_ack':
        _handleChunkAck(transferId, header['chunkIndex'] as int);
        break;
      case 'file_chunk':
        _handleIncomingFileChunk(transferId, frame, header);
        break;
      case 'file_start':
        // Handle asynchronously since it may need to create directories
        _handleFileStart(transferId, header);
        break;
      case 'file_start_ack':
        _handleFileStartAck(transferId, header);
        break;
      case 'file_end':
        _handleFileEnd(transferId);
        break;
      case 'file_end_ack':
        _handleFileEndAck(transferId);
        break;
      case 'control':
        // Handle control messages
        break;
    }
  }

  Future<void> _handleFileStart(String transferId, Map<String, dynamic> header) async {
    final transfer = activeTransfers[transferId];
    if (transfer == null) return;

    // Store expected hash from sender
    final expectedHash = header['fileHash'] as String?;
    if (expectedHash != null) {
      transfer.fileHash = expectedHash;
    }

    // Store totalChunks from sender for accurate progress calculation
    final totalChunks = header['totalChunks'] as int?;
    if (totalChunks != null) {
      transfer.totalChunks = totalChunks;
    }

    // Set filePath for incoming transfers if not already set
    if (transfer.filePath == null) {
      final fileName = header['fileName'] as String? ?? 'unknown_file';
      final appDir = await getApplicationSupportDirectory();
      final downloadDir = Directory('${appDir.path}/${TransferConfig.defaultDownloadDir}/${transfer.deviceId}');
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      transfer.filePath = '${downloadDir.path}/$fileName';
    }

    // Ensure receive worker exists for this device (delegate to worker)
    // This will be handled by the TransferIsolateWorker when it receives the event

    // Send file_start_ack with acknowledged chunks for resume
    final deviceId = transfer.deviceId;
    final session = deviceSessions[deviceId];
    if (session != null) {
      // Load acknowledged chunks from DB
      final acknowledgedChunks = await _loadAcknowledgedChunks(transferId);
      for (final connectionId in session.connectionIds) {
networkSendPort.send(net_cmds.SendFrameCommand(
          connectionId: connectionId,
          type: 'file_start_ack',
          header: {
            'transferId': transferId,
            'completedChunks': acknowledgedChunks.toList(),
          },
          payload: Uint8List(0),
          priority: SchedulerPriority.control,
        ));
      }
    }
  }

  void _handleIncomingFileChunk(String transferId, net_cmds.FrameReceivedEvent frame, Map<String, dynamic> header) {
    final chunkIndex = header['chunkIndex'] as int;
    final offset = header['offset'] as int;
    final length = header['length'] as int;
    final connectionId = frame.header['connectionId'] as String? ?? '${deviceSessions[activeTransfers[transferId]?.deviceId ?? '']?.connectionIds.first ?? ''}';

    // Delegate to receive worker
    final deviceId = activeTransfers[transferId]?.deviceId;
    if (deviceId != null) {
      final receiveWorker = receiveWorkers[deviceId];
      if (receiveWorker != null) {
        receiveWorker.handleFileChunk(transferId, chunkIndex, offset, length, frame.payload, connectionId);
      }
    }
  }

  void _handleFileEnd(String transferId) {
    // Trigger verification and finalization
    final deviceId = activeTransfers[transferId]?.deviceId;
    if (deviceId != null) {
      final receiveWorker = receiveWorkers[deviceId];
      if (receiveWorker != null) {
        receiveWorker.verifyAndFinalize(transferId);
      }
    }
  }

  void _handleChunkAck(String transferId, int chunkIndex) {
    final chunkId = '${transferId}_$chunkIndex';
    final chunk = _allChunks[chunkId];
    if (chunk == null) return;

    chunk.state = ChunkState.acked;
    chunk.ackedAt = DateTime.now();

    // Notify send worker to remove from retry tracking
    final sendWorker = sendWorkers[activeTransfers[transferId]?.deviceId ?? ''];
    sendWorker?._onChunkAcked(chunkId);

    final transfer = activeTransfers[transferId];
    if (transfer != null) {
      transfer.transferredBytes += chunk.length;
      transfer.completedChunks++;
      transfer.recordProgress(transfer.transferredBytes);

      // Save progress to DB periodically
      if (transfer.completedChunks % 10 == 0) {
        saveProgress(transferId, transfer);
      }

      // Emit progress
      mainSendPort.send(TransferProgressEvent(
        transferId: transferId,
        transferredBytes: transfer.transferredBytes,
        totalBytes: transfer.totalBytes,
        completedChunks: transfer.completedChunks,
        totalChunks: transfer.totalChunks,
        speedBytesPerSecond: transfer.speedBytesPerSecond,
        estimatedTimeRemaining: transfer.estimatedTimeRemaining,
      ));
    }

    _checkTransferCompletion(transferId);
  }

  void _handleFileStartAck(String transferId, Map<String, dynamic> header) {
    // Get acknowledged chunks from receiver
    final completedChunks = (header['completedChunks'] as List<dynamic>?)
        ?.map((e) => e as int)
        .toSet() ?? {};

    // Save to DB for resume
    _saveAcknowledgedChunks(transferId, completedChunks);

    // Re-chunk the file based on acknowledged chunks
    final transfer = activeTransfers[transferId];
    if (transfer != null && transfer.isOutgoing) {
      _rechunkFileForResume(transfer, completedChunks);
    }
  }

  void _rechunkFileForResume(_ActiveTransfer transfer, Set<int> completedChunks) {
    // Remove already-acked chunks from the queue
    final chunksToRemove = _allChunks.entries
        .where((e) => e.value.transferId == transfer.id && completedChunks.contains(e.value.chunkIndex))
        .map((e) => e.key)
        .toList();

    for (final key in chunksToRemove) {
      final chunk = _allChunks.remove(key);
      if (chunk != null && chunk.state == ChunkState.queued) {
        // Already acked, don't re-queue
      } else if (chunk != null && chunk.state == ChunkState.sending) {
        // Was in flight, will be retried or handled by retry logic
        _sentChunksByTransfer[transfer.id]?.remove(key);
      }
    }

    // Update transfer progress
    transfer.completedChunks = completedChunks.length;
    transfer.transferredBytes = completedChunks.fold(0, (sum, idx) {
      // We don't have the exact bytes per chunk here, but we can estimate
      // For now, just mark the chunks as completed
      return sum;
    });

    // Re-chunk the remaining file
    final queue = _getOrCreateQueue(transfer.deviceId);
    final sendWorker = _getOrCreateSendWorker(transfer.deviceId);
    _chunkFileForResume(transfer, queue, completedChunks);

    // Ensure send worker is running
    sendWorker.start();
  }

  // Track sent chunks per transfer for resume handling
  final Map<String, Set<String>> _sentChunksByTransfer = {};

  Future<void> _chunkFileForResume(_ActiveTransfer transfer, _TransferQueue queue, Set<int> completedChunks) async {
    if (transfer.filePath == null) return;

    final file = File(transfer.filePath!);
    if (!await file.exists()) {
      _failTransfer(transfer.id, 'File not found');
      return;
    }

    final fileSize = await file.length();
    final chunkSize = _calculateChunkSize(fileSize);
    int offset = 0;
    int chunkIndex = 0;

    // Initialize streaming hash calculator using AccumulatorSink
    final hashAccumulator = TransferConfig.enableStreamingHash ? _StreamingHashAccumulator() : null;

    final raf = await file.open(mode: FileMode.read);

    try {
      while (offset < fileSize) {
        final length = chunkSize.clamp(0, fileSize - offset);

        if (!completedChunks.contains(chunkIndex)) {
          Uint8List bytes;
          
          // Use mmap for zero-copy reads on large files if enabled
          if (TransferConfig.enableMmap && fileSize > TransferConfig.mediumFileThreshold) {
            bytes = await _readFileMmap(raf, offset, length);
          } else {
            await raf.setPosition(offset);
            bytes = await raf.read(length);
          }

          // Add to streaming hash
          if (hashAccumulator != null) {
            hashAccumulator.add(bytes);
          }

          final chunk = _ScheduledChunk(
            id: '${transfer.id}_$chunkIndex',
            chunkIndex: chunkIndex,
            offset: offset,
            length: length,
            data: bytes,
            priority: transfer.priority,
            transferId: transfer.id,
            deviceId: transfer.deviceId,
          );

          _allChunks[chunk.id] = chunk;
          queue.add(chunk);
          transfer.totalChunks++;
        } else {
          transfer.completedChunks++;
          transfer.transferredBytes += length;
        }

        offset += length;
        chunkIndex++;
      }
    } finally {
      await raf.close();
    }

    // Finalize hash
    if (hashAccumulator != null) {
      transfer.fileHash = hashAccumulator.finalize();
      await _saveFileHash(transfer.id, transfer.fileHash!);
    }
    // NOTE: Do NOT send file_start again on resume - receiver already has transfer info
    // The file_start_ack with acknowledged chunks is sufficient to resume
  }

  Future<void> _saveAcknowledgedChunks(String transferId, Set<int> chunks) async {
    try {
      await db.insert('outgoing_progress', {
        'transfer_id': transferId,
        'completed_chunks': jsonEncode(chunks.toList()),
        'last_updated': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  void _handleFileEndAck(String transferId) {
    final transfer = activeTransfers[transferId];
    if (transfer != null) {
      transfer.status = TransferStatus.completed;
      transfer.completedAt = DateTime.now();
      mainSendPort.send(TransferCompletedEvent(transferId, transfer.filePath ?? ''));
      _cleanupTransfer(transferId);
    }
  }

  void _checkTransferCompletion(String transferId) {
    final transfer = activeTransfers[transferId];
    if (transfer == null) return;

    if (transfer.completedChunks >= transfer.totalChunks && transfer.totalChunks > 0) {
      // Send file_end
      final session = deviceSessions[transfer.deviceId];
      if (session != null) {
        for (final connectionId in session.connectionIds) {
networkSendPort.send(net_cmds.SendFrameCommand(
            connectionId: connectionId,
            type: 'file_end',
            header: {'transferId': transferId},
            payload: Uint8List(0),
            priority: SchedulerPriority.control,
          ));
        }
      }
    }
  }

  Future<void> saveProgress(String transferId, _ActiveTransfer transfer) async {
    try {
      await db.insert('outgoing_progress', {
        'transfer_id': transferId,
        'device_id': transfer.deviceId,
        'file_name': transfer.fileName,
        'file_path': transfer.filePath,
        'total_bytes': transfer.totalBytes,
        'completed_chunks': jsonEncode(
          _allChunks.entries
              .where((e) => e.value.transferId == transferId && e.value.state == ChunkState.acked)
              .map((e) => e.value.chunkIndex)
              .toList()
        ),
        'last_updated': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  void _failTransfer(String transferId, String error) {
    final transfer = activeTransfers[transferId];
    if (transfer != null) {
      transfer.status = TransferStatus.failed;
      transfer.error = error;
      mainSendPort.send(TransferFailedEvent(transferId, error));
      _cleanupTransfer(transferId);
    }
  }

  void _cleanupTransfer(String transferId) {
    _allChunks.removeWhere((key, chunk) => chunk.transferId == transferId);
    _chunkAckCounts.remove(transferId);
    _pausedTransfers.remove(transferId);
    _sentChunksByTransfer.remove(transferId);
  }

  _TransferQueue _getOrCreateQueue(String deviceId) {
    return _queues.putIfAbsent(deviceId, () => _TransferQueue());
  }

  _SendWorker _getOrCreateSendWorker(String deviceId) {
    return sendWorkers.putIfAbsent(deviceId, () => _SendWorker(
      deviceId: deviceId,
      queue: _getOrCreateQueue(deviceId),
      networkSendPort: networkSendPort,
      mainSendPort: mainSendPort,
      allChunks: _allChunks,
      pausedTransfers: _pausedTransfers,
      db: db,
      schedulerWorker: this,
    ));
  }

  void pauseTransfer(String transferId) {
    _pausedTransfers.add(transferId);
    final transfer = activeTransfers[transferId];
    if (transfer != null) {
      transfer.status = TransferStatus.paused;
      mainSendPort.send(TransferPausedEvent(transferId));
    }
  }

  void resumeTransfer(String transferId) {
    _pausedTransfers.remove(transferId);
    final transfer = activeTransfers[transferId];
    if (transfer != null) {
      transfer.status = TransferStatus.transferring;
      mainSendPort.send(TransferResumedEvent(transferId));
    }
  }

  void cancelTransfer(String transferId, String reason) {
    _pausedTransfers.remove(transferId);
    final transfer = activeTransfers.remove(transferId);
    if (transfer != null) {
      transfer.status = TransferStatus.cancelled;
      _cleanupTransfer(transferId);
      mainSendPort.send(TransferCancelledEvent(transferId, reason));
    }
  }

  void prioritizeTransfer(String transferId, SchedulerPriority priority) {
    // Re-prioritize chunks in queue
    for (final chunk in _allChunks.values) {
      if (chunk.transferId == transferId && chunk.state == ChunkState.queued) {
        chunk.priority = priority;
      }
    }
  }

  void dispose() {
    // Cleanup handled by parent
  }
}

enum ChunkState {
  queued,
  sending,
  acked,
  failed,
}

class _ScheduledChunk {
  final String id;
  final int chunkIndex;
  final int offset;
  final int length;
  final Uint8List data;
  SchedulerPriority priority;
  final String transferId;
  final String deviceId;

  ChunkState state = ChunkState.queued;
  int retryCount = 0;
  final DateTime createdAt = DateTime.now();
  DateTime? sentAt;
  DateTime? ackedAt;
  Object? lastError;

  _ScheduledChunk({
    required this.id,
    required this.chunkIndex,
    required this.offset,
    required this.length,
    required this.data,
    required this.priority,
    required this.transferId,
    required this.deviceId,
  });
}

class _TransferQueue {
  final List<_ScheduledChunk> _controlQueue = [];
  final List<_ScheduledChunk> _messageQueue = [];
  final List<_ScheduledChunk> _fileQueue = [];

  void add(_ScheduledChunk chunk) {
    switch (chunk.priority) {
      case SchedulerPriority.control:
        _controlQueue.add(chunk);
        break;
      case SchedulerPriority.message:
        _messageQueue.add(chunk);
        break;
      case SchedulerPriority.file:
        _fileQueue.add(chunk);
        break;
    }
  }

  _ScheduledChunk? removeFirst() {
    if (_controlQueue.isNotEmpty) return _controlQueue.removeAt(0);
    if (_messageQueue.isNotEmpty) return _messageQueue.removeAt(0);
    if (_fileQueue.isNotEmpty) return _fileQueue.removeAt(0);
    return null;
  }

  bool get isEmpty => _controlQueue.isEmpty && _messageQueue.isEmpty && _fileQueue.isEmpty;
  int get length => _controlQueue.length + _messageQueue.length + _fileQueue.length;
}

class _SendWorker {
  final String deviceId;
  final _TransferQueue queue;
  final SendPort networkSendPort;
  final SendPort mainSendPort;
  final Map<String, _ScheduledChunk> allChunks;
  final Set<String> pausedTransfers;
  final Database db;
  final _SchedulerWorker schedulerWorker;

  Timer? _workerTimer;
  Timer? _retryTimer;
  Timer? _healthCheckTimer;
  Timer? _connectionQueryTimer;
  bool _running = false;

  // Track sent chunks for retry: chunkId -> {sentAt, retryCount}
  final Map<String, _SentChunkInfo> _sentChunks = {};

  // Connection health tracking: connectionId -> health info
  final Map<String, _ConnectionHealth> _connectionHealth = {};

  // Backpressure: track unacked chunks per connection
  final Map<String, int> _unackedChunksPerConnection = {};
  final int _windowSize = TransferConfig.activeWindowSize;

  _SendWorker({
    required this.deviceId,
    required this.queue,
    required this.networkSendPort,
    required this.mainSendPort,
    required this.allChunks,
    required this.pausedTransfers,
    required this.db,
    required this.schedulerWorker,
  });

  void start() {
    if (_running) return;
    _running = true;
    _workerTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      _processQueue();
    });
    // Check for timed-out chunks every 5 seconds
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkTimeouts();
    });
    // Check connection health every 10 seconds
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkConnectionHealth();
    });
    // Query available connections from Network Isolate every 15 seconds
    _connectionQueryTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _queryAvailableConnections();
    });
  }

  void _processQueue() {
    if (!_running) return;

    final chunk = queue.removeFirst();
    if (chunk == null) return;

    if (pausedTransfers.contains(chunk.transferId)) {
      queue.add(chunk);
      return;
    }

    // Find a healthy connection for this device
    final connectionId = _selectHealthyConnection(chunk.deviceId);
    if (connectionId == null) {
      // No healthy connections, re-queue and wait
      chunk.state = ChunkState.queued;
      queue.add(chunk);
      return;
    }

    // Check backpressure window
    final unackedCount = _unackedChunksPerConnection[connectionId] ?? 0;
    if (unackedCount >= _windowSize) {
      // Window full, yield to event loop before re-queueing to avoid tight loop
      chunk.state = ChunkState.queued;
      Future.microtask(() => queue.add(chunk));
      return;
    }

    chunk.state = ChunkState.sending;
    chunk.sentAt = DateTime.now();
    chunk.retryCount++;

    // Track for retry
    _sentChunks[chunk.id] = _SentChunkInfo(
      sentAt: chunk.sentAt!,
      retryCount: chunk.retryCount,
      connectionId: connectionId,
    );

    // Track unacked chunks for backpressure
    _unackedChunksPerConnection[connectionId] = (_unackedChunksPerConnection[connectionId] ?? 0) + 1;

    networkSendPort.send(net_cmds.SendFrameCommand(
      connectionId: connectionId,
      type: 'file_chunk',
      header: {
        'transferId': chunk.transferId,
        'chunkIndex': chunk.chunkIndex,
        'offset': chunk.offset,
        'length': chunk.length,
      },
      payload: chunk.data,
      priority: chunk.priority,
    ));
  }

  String? _selectHealthyConnection(String deviceId) {
    // Check all 4 connections for this device
    final candidates = <String>[];
    for (int i = 0; i < 4; i++) {
      final connId = '$deviceId-$i';
      final health = _connectionHealth[connId];
      if (health != null && health.isHealthy) {
        candidates.add(connId);
      }
    }

    if (candidates.isEmpty) {
      return null;
    }

    // Select the connection with the lowest latency/errors
    candidates.sort((a, b) {
      final healthA = _connectionHealth[a]!;
      final healthB = _connectionHealth[b]!;
      // Prefer lower error rate, then lower latency
      final scoreA = healthA.errorRate * 1000 + healthA.avgLatencyMs;
      final scoreB = healthB.errorRate * 1000 + healthB.avgLatencyMs;
      return scoreA.compareTo(scoreB);
    });

    return candidates.first;
  }

  void _checkConnectionHealth() {
    // Remove stale health entries (older than 60 seconds)
    final now = DateTime.now();
    _connectionHealth.removeWhere((_, health) {
      return now.difference(health.lastUpdate) > const Duration(seconds: 60);
    });
  }

  void recordConnectionResult(String connectionId, bool success, int latencyMs) {
    final health = _connectionHealth.putIfAbsent(connectionId, () => _ConnectionHealth());
    health.recordResult(success, latencyMs);
  }

  void _checkTimeouts() {
    if (!_running) return;
    final now = DateTime.now();
    const timeout = Duration(seconds: 30);

    final toRetry = <String>[];
    for (final entry in _sentChunks.entries) {
      final chunkId = entry.key;
      final info = entry.value;
      
      if (now.difference(info.sentAt) > timeout) {
        final chunk = allChunks[chunkId];
        if (chunk != null && chunk.state == ChunkState.sending && chunk.retryCount < 3) {
          toRetry.add(chunkId);
        } else if (chunk != null && chunk.retryCount >= 3) {
          // Max retries exceeded - fail the transfer
          chunk.state = ChunkState.failed;
          chunk.lastError = 'Max retries exceeded';
          toRetry.add(chunkId); // Remove from tracking
          
          // Notify scheduler to fail the transfer
          schedulerWorker._failTransfer(chunk.transferId, 'Chunk $chunkId failed after max retries');
        }
      }
    }

    // Re-queue timed-out chunks
    for (final chunkId in toRetry) {
      _sentChunks.remove(chunkId);
      final chunk = allChunks[chunkId];
      if (chunk != null && chunk.state != ChunkState.failed) {
        chunk.state = ChunkState.queued;
        queue.add(chunk);
      }
    }
  }

  void _onChunkAcked(String chunkId) {
    final info = _sentChunks.remove(chunkId);
    if (info != null) {
      // Decrement unacked count for backpressure
      final current = _unackedChunksPerConnection[info.connectionId];
      if (current != null && current > 0) {
        _unackedChunksPerConnection[info.connectionId] = current - 1;
      }
    }
  }

  void _queryAvailableConnections() {
    if (!_running) return;
    // Send GetDeviceConnectionsCommand to Network Isolate via mainSendPort
    mainSendPort.send(net_cmds.GetDeviceConnectionsCommand(deviceId));
  }

  void updateAvailableConnections(List<String> connectionIds) {
    // Track health for all connections (both outgoing and incoming)
    // Remove health entries for connections that no longer exist
    _connectionHealth.removeWhere((connId, _) => !connectionIds.contains(connId));
    // Add health entries for new connections (default healthy)
    for (final connId in connectionIds) {
      _connectionHealth.putIfAbsent(connId, () => _ConnectionHealth());
    }
  }

  void dispose() {
    _running = false;
    _workerTimer?.cancel();
    _retryTimer?.cancel();
    _healthCheckTimer?.cancel();
    _connectionQueryTimer?.cancel();
  }

  void clearDeviceUnackedChunks() {
    _unackedChunksPerConnection.clear();
  }

  void clearDeviceHealth(String deviceId) {
    _connectionHealth.removeWhere((connId, _) => connId.startsWith('$deviceId-'));
  }
}

class _ConnectionHealth {
  int _totalRequests = 0;
  int _failedRequests = 0;
  int _totalLatencyMs = 0;
  DateTime lastUpdate = DateTime.now();

  double get errorRate => _totalRequests > 0 ? _failedRequests / _totalRequests : 0.0;
  double get avgLatencyMs => _totalRequests > 0 ? _totalLatencyMs / _totalRequests : 0.0;
  bool get isHealthy => errorRate < 0.5 && avgLatencyMs < 5000;

  void recordResult(bool success, int latencyMs) {
    _totalRequests++;
    _totalLatencyMs += latencyMs;
    if (!success) {
      _failedRequests++;
    }
    lastUpdate = DateTime.now();
  }
}

class _SentChunkInfo {
  final DateTime sentAt;
  final int retryCount;
  final String connectionId;

  _SentChunkInfo({
    required this.sentAt,
    required this.retryCount,
    required this.connectionId,
  });
}

class _ReceiveWorker {
  final String deviceId;
  final List<String> connectionIds;
  final SendPort networkSendPort;
  final SendPort mainSendPort;
  final Database db;
  final Map<String, _ActiveTransfer> activeTransfers;
  final _SchedulerWorker schedulerWorker;

  final Map<String, RandomAccessFile> _openFiles = {};
  final Map<String, AsyncSemaphore> _writeSemaphores = {};
  final Map<String, _StreamingHashAccumulator> _hashSinks = {};
  // Track completed chunk indices for each transfer for resume capability
  final Map<String, Set<int>> _completedChunkIndices = {};

  _ReceiveWorker({
    required this.deviceId,
    required this.connectionIds,
    required this.networkSendPort,
    required this.mainSendPort,
    required this.db,
    required this.activeTransfers,
    required this.schedulerWorker,
  });

  /// Handle incoming file chunk - called from scheduler when frame received
  Future<void> handleFileChunk(String transferId, int chunkIndex, int offset, int length, Uint8List payload, String connectionId) async {
    final transfer = activeTransfers[transferId];
    if (transfer == null) return;

    // Initialize file and hash sink on first chunk
    if (!_openFiles.containsKey(transferId)) {
      await _initializeTransferFile(transfer);
    }

    final file = _openFiles[transferId]!;
    final semaphore = _writeSemaphores.putIfAbsent(transferId, () => AsyncSemaphore(1));
    final hashSink = _hashSinks[transferId];

    // Track completed chunk index for resume
    _completedChunkIndices.putIfAbsent(transferId, () => {}).add(chunkIndex);

    await semaphore.acquire();
    try {
      await file.setPosition(offset);
      await file.writeFrom(payload);

      // Update streaming hash
      if (hashSink != null) {
        hashSink.add(payload);
      }

      // Update progress
      transfer.completedChunks++;
      transfer.transferredBytes += length;
      transfer.recordProgress(transfer.transferredBytes);

      // Save progress to DB periodically
      if (transfer.completedChunks % TransferConfig.progressPersistInterval == 0) {
        await saveReceiveProgress(transfer);
      }

      // Emit progress
      mainSendPort.send(TransferProgressEvent(
        transferId: transferId,
        transferredBytes: transfer.transferredBytes,
        totalBytes: transfer.totalBytes,
        completedChunks: transfer.completedChunks,
        totalChunks: transfer.totalChunks,
        speedBytesPerSecond: transfer.speedBytesPerSecond,
        estimatedTimeRemaining: transfer.estimatedTimeRemaining,
      ));
    } finally {
      semaphore.release();
    }

    // Send acknowledgment
    await _sendChunkAck(transferId, chunkIndex, connectionId);
  }

  Future<void> _initializeTransferFile(_ActiveTransfer transfer) async {
    if (transfer.filePath == null) return;

    // Use a temporary .part file for incoming transfers
    final partPath = '${transfer.filePath}.part';
    final partFile = File(partPath);
    final fileExists = await partFile.exists();
    
    final file = await partFile.open(mode: FileMode.writeOnlyAppend);
    _openFiles[transfer.id] = file;

    // Initialize streaming hash for verification
    if (TransferConfig.enableStreamingHash) {
      _hashSinks[transfer.id] = _StreamingHashAccumulator();
      
      // If resuming (file exists and has content), recompute hash from existing file
      if (fileExists) {
        final fileSize = await partFile.length();
        if (fileSize > 0) {
          await _recomputeHashFromFile(transfer.id, partFile, fileSize);
        }
      }
    }

    // Load completed chunks from DB for resume
    await _loadIncomingProgress(transfer);
  }

  Future<void> _recomputeHashFromFile(String transferId, File partFile, int fileSize) async {
    try {
      final hashAccumulator = _hashSinks[transferId];
      if (hashAccumulator == null) return;
      
      final raf = await partFile.open(mode: FileMode.read);
      try {
        const chunkSize = 64 * 1024; // 64KB chunks
        int offset = 0;
        while (offset < fileSize) {
          final length = chunkSize.clamp(0, fileSize - offset);
          await raf.setPosition(offset);
          final bytes = await raf.read(length);
          hashAccumulator.add(bytes);
          offset += length;
        }
      } finally {
        await raf.close();
      }
    } catch (e) {
      // If hash recomputation fails, create fresh accumulator (will fail verification later)
      _hashSinks[transferId] = _StreamingHashAccumulator();
    }
  }

  Future<void> _loadIncomingProgress(_ActiveTransfer transfer) async {
    try {
      final result = await db.query(
        'incoming_progress',
        where: 'transfer_id = ?',
        whereArgs: [transfer.id],
      );
      if (result.isNotEmpty) {
        final completedChunksJson = result.first['completed_chunks'] as String?;
        if (completedChunksJson != null) {
          final list = jsonDecode(completedChunksJson) as List;
          final completedChunks = list.map((e) => e as int).toSet();
          transfer.completedChunks = completedChunks.length;
          // Note: We don't track individual chunk indices here, but we could
          // For now, we just update the count
        }
      }
    } catch (_) {}
  }

  Future<void> saveReceiveProgress(_ActiveTransfer transfer) async {
    try {
      final completedIndices = _completedChunkIndices[transfer.id]?.toList() ?? [];
      await db.insert('incoming_progress', {
        'transfer_id': transfer.id,
        'device_id': transfer.deviceId,
        'fingerprint': transfer.deviceId, // For incoming transfers, deviceId is the fingerprint
        'file_name': transfer.fileName,
        'file_path': transfer.filePath,
        'total_bytes': transfer.totalBytes,
        'completed_chunks': jsonEncode(completedIndices),
        'expected_hash': transfer.fileHash,
        'last_updated': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}
  }

  Future<void> _sendChunkAck(String transferId, int chunkIndex, String connectionId) async {
    networkSendPort.send(net_cmds.SendFrameCommand(
      connectionId: connectionId,
      type: 'chunk_ack',
      header: {
        'transferId': transferId,
        'chunkIndex': chunkIndex,
      },
      payload: Uint8List(0),
      priority: SchedulerPriority.control,
    ));
  }

  /// Verify file integrity after all chunks received
  Future<void> verifyAndFinalize(String transferId) async {
    final transfer = activeTransfers[transferId];
    if (transfer == null || transfer.filePath == null) return;

    final partPath = '${transfer.filePath}.part';
    final partFile = File(partPath);

    // Load expected hash from DB if not set
    if (transfer.fileHash == null) {
      await _loadFileHash(transfer);
    }

    // Finalize hash
    String? computedHash;
    if (_hashSinks.containsKey(transferId)) {
      final hashAccumulator = _hashSinks.remove(transferId)!;
      computedHash = hashAccumulator.finalize();
    }

    // Verify against expected hash if available
    bool integrityOk = true;
    if (computedHash != null && transfer.fileHash != null) {
      integrityOk = computedHash == transfer.fileHash;
    }

    // Close file
    await _openFiles[transferId]?.close();
    _openFiles.remove(transferId);
    _writeSemaphores.remove(transferId);

    if (integrityOk) {
      // Rename .part to final file
      await partFile.rename(transfer.filePath!);
      transfer.status = TransferStatus.completed;
      mainSendPort.send(TransferCompletedEvent(transferId, transfer.filePath!));
    } else {
      // Delete corrupted file
      if (await partFile.exists()) {
        await partFile.delete();
      }
      transfer.status = TransferStatus.failed;
      transfer.error = 'File integrity check failed';
      mainSendPort.send(TransferFailedEvent(transferId, 'File integrity check failed'));
    }

    // Delete progress from DB
    await db.delete('incoming_progress', where: 'transfer_id = ?', whereArgs: [transferId]);
  }

  Future<void> _loadFileHash(_ActiveTransfer transfer) async {
    try {
      final result = await db.query(
        'incoming_progress',
        where: 'transfer_id = ?',
        whereArgs: [transfer.id],
      );
      if (result.isNotEmpty) {
        final hash = result.first['expected_hash'] as String?;
        if (hash != null) {
          transfer.fileHash = hash;
        }
      }
    } catch (_) {}
  }

  void dispose() {
    // Save progress for all active transfers before closing
    for (final transferId in _openFiles.keys) {
      final transfer = activeTransfers[transferId];
      if (transfer != null && transfer.status == TransferStatus.transferring) {
        saveReceiveProgress(transfer);
      }
    }

    for (final file in _openFiles.values) {
      file.close();
    }
    _openFiles.clear();
    _writeSemaphores.clear();
    _hashSinks.clear();
    _completedChunkIndices.clear();
  }
}

class AsyncSemaphore {
  final int _permits;
  int _available;
  final List<Completer<void>> _waiters = [];

  AsyncSemaphore(this._permits) : _available = _permits;

  Future<void> acquire() async {
    if (_available > 0) {
      _available--;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _available = (_available + 1).clamp(0, _permits);
    }
  }
}

/// Streaming hash accumulator using SHA-256 for incremental hash computation
/// without loading the entire file into memory.
class _StreamingHashAccumulator {
  late final Sink<List<int>> _sink;
  Digest? _digest;

  _StreamingHashAccumulator() {
    _sink = sha256.startChunkedConversion(_DigestCaptureSink((digest) {
      _digest = digest;
    }));
  }

  void add(List<int> data) {
    _sink.add(data);
  }

  String finalize() {
    _sink.close();
    if (_digest == null) {
      throw StateError('Hash not finalized');
    }
    return base64Encode(_digest!.bytes);
  }
}

class _DigestCaptureSink implements Sink<Digest> {
  final void Function(Digest) onDigest;
  _DigestCaptureSink(this.onDigest);

  @override
  void add(Digest digest) {
    onDigest(digest);
  }

  @override
  void close() {}
}