import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show AppLifecycleState, RootIsolateToken;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:connect/network/transfer/isolate/commands.dart' hide TransferStatus;
import 'package:connect/network/transfer/isolate/network_commands.dart' as net_cmds;
import 'package:connect/network/transfer/isolate/transfer_isolate.dart';
import 'package:connect/network/connection/isolate/network_isolate.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/network/connection/connection_manager.dart';
import 'package:connect/network/crypto/device_identity.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:connect/app/tcp_config.dart';
import 'package:connect/app/transfer_config.dart';
import 'package:connect/network/storage/database_helper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/relay/providers/transfer_providers.dart';

class TransferController {
  Isolate? _transferIsolate;
  Isolate? _networkIsolate;
  SendPort? _transferSendPort;
  SendPort? _networkSendPort;
  ReceivePort? _transferReceivePort;
  ReceivePort? _networkReceivePort;
  ReceivePort? _mainReceivePort;
  ReceivePort? _connectionQueryPort;

  final ConnectionManager _connectionManager;
  final DeviceIdentity _identity;
  final TrustStore _trustStore;
  final TrustPolicy _trustPolicy;

  final StreamController<TransferEvent> _eventController = StreamController<TransferEvent>.broadcast();
  
  // Per-transfer event streams
  final Map<String, StreamController<TransferEvent>> _transferEventControllers = {};
  
  // Per-device event streams
  final Map<String, StreamController<TransferEvent>> _deviceEventControllers = {};

  final Map<String, Transfer> _activeTransfers = {};

  bool _isInitialized = false;
  bool _isShuttingDown = false;

  // Track pending connection queries to avoid race conditions
  final Map<String, Completer<List<String>>> _pendingConnectionQueries = {};
  int _connectionQueryCounter = 0;

  Stream<TransferEvent> get events => _eventController.stream;
  Map<String, Transfer> get activeTransfers => Map.unmodifiable(_activeTransfers);

  TransferController({
    required ConnectionManager connectionManager,
    required DeviceIdentity identity,
    required TrustStore trustStore,
    required TrustPolicy trustPolicy,
  })  : _connectionManager = connectionManager,
        _identity = identity,
        _trustStore = trustStore,
        _trustPolicy = trustPolicy;

  Future<void> initialize() async {
    if (_isInitialized) return;

    _mainReceivePort = ReceivePort();
    _networkReceivePort = ReceivePort();
    _transferReceivePort = ReceivePort();
    _connectionQueryPort = ReceivePort();

    // Get peer registry mapping (fingerprint -> deviceId)
    final peerRegistryJson = jsonEncode(
      _connectionManager.peerRegistry.peers.map(
        (deviceId, peer) => MapEntry(peer.fingerprint, deviceId),
      ),
    );

    // Start Network isolate first
    try {
      _networkIsolate = await Isolate.spawn(
        networkIsolateEntrypoint,
        NetworkIsolateParams(
          mainSendPort: _networkReceivePort!.sendPort,
          identityPrivateKeyPem: _identity.privateKeyPem,
          trustStoreJson: _trustStore.toJson(),
          trustPolicy: _trustPolicy,
          listenPort: BaseTcpConfig.tcpPort,
          peerRegistryJson: peerRegistryJson,
        ),
      );
    } on IsolateSpawnException catch (e) {
      debugPrint('Failed to spawn Network Isolate: $e');
      _cleanupOnInitFailure();
      throw StateError('Network isolate initialization failed: $e');
    }

    // Wait for Network isolate to be ready
    final networkReadyCompleter = Completer<SendPort>();
    late StreamSubscription networkSub;
    networkSub = _networkReceivePort!.listen((message) {
      if (!networkReadyCompleter.isCompleted && message is SendPort) {
        networkReadyCompleter.complete(message);
      } else {
        _handleNetworkEvent(message);
      }
    });

    try {
      _networkSendPort = await networkReadyCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Network isolate handshake timeout'),
      );
    } on TimeoutException catch (e) {
      networkSub.cancel();
      debugPrint('Network isolate handshake timeout: $e');
      _cleanupOnInitFailure();
      throw StateError('Network isolate handshake timeout');
    }

    // Set up single listener for main events (handles both handshake and ongoing events)
    final transferReadyCompleter = Completer<SendPort>();
    late StreamSubscription mainSub;
    mainSub = _mainReceivePort!.listen((message) {
      if (!transferReadyCompleter.isCompleted && message is SendPort) {
        transferReadyCompleter.complete(message);
      } else {
        _handleMainEvent(message);
      }
    });

    // Set up connection query listener
    _connectionQueryPort!.listen(_handleConnectionQueryResponse);

    // Start Transfer isolate with Network isolate's send port
    // Transfer isolate sends its sendPort to _mainReceivePort
    try {
      _transferIsolate = await Isolate.spawn(
        transferIsolateEntrypoint,
        TransferIsolateParams(
          networkSendPort: _networkSendPort!,
          mainSendPort: _mainReceivePort!.sendPort,
          rootIsolateToken: RootIsolateToken.instance!,
        ),
      );
    } on IsolateSpawnException catch (e) {
      mainSub.cancel();
      debugPrint('Failed to spawn Transfer Isolate: $e');
      _cleanupOnInitFailure();
      throw StateError('Transfer isolate initialization failed: $e');
    }

    // Wait for Transfer isolate to be ready
    try {
      _transferSendPort = await transferReadyCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Transfer isolate handshake timeout'),
      );
    } on TimeoutException catch (e) {
      mainSub.cancel();
      debugPrint('Transfer isolate handshake timeout: $e');
      _cleanupOnInitFailure();
      throw StateError('Transfer isolate handshake timeout');
    }

    _isInitialized = true;

    // Restore pending transfers from database
    await _restorePendingTransfers();
  }

  void _cleanupOnInitFailure() {
    _transferIsolate?.kill(priority: Isolate.immediate);
    _networkIsolate?.kill(priority: Isolate.immediate);
    _mainReceivePort?.close();
    _networkReceivePort?.close();
    _transferReceivePort?.close();
    _connectionQueryPort?.close();
    _transferIsolate = null;
    _networkIsolate = null;
    _transferSendPort = null;
    _networkSendPort = null;
    _mainReceivePort = null;
    _transferReceivePort = null;
    _networkReceivePort = null;
    _connectionQueryPort = null;
    _isInitialized = false;
  }

  Future<void> _restorePendingTransfers() async {
    final db = await DatabaseHelper.instance.init();

    try {
      // Load outgoing transfers that are not completed
      final outgoingResult = await db.query(
        'outgoing_progress',
        where: 'status IS NULL OR status != ?',
        whereArgs: ['completed'],
      );

      for (final row in outgoingResult) {
        final transferId = row['transfer_id'] as String;
        final deviceId = row['device_id'] as String;
        final fileName = row['file_name'] as String;
        final filePath = row['file_path'] as String;
        final totalBytes = row['total_bytes'] as int;

        // Check if file still exists
        final file = File(filePath);
        if (!await file.exists()) {
          // File deleted, mark as failed in DB
          await db.update(
            'outgoing_progress',
            {'status': 'failed', 'error': 'File not found'},
            where: 'transfer_id = ?',
            whereArgs: [transferId],
          );
          continue;
        }

        // Create transfer object
        final transfer = FileTransfer(
          id: transferId,
          deviceId: deviceId,
          type: TransferType.file,
          filePath: filePath,
          fileName: fileName,
          totalBytes: totalBytes,
        );
        transfer.status = TransferStatus.queued;
        _activeTransfers[transferId] = transfer;

        // Re-queue the transfer
        _transferSendPort?.send(SendFileCommand(
          transferId: transferId,
          deviceId: deviceId,
          filePath: filePath,
          fileName: fileName,
          fileSize: totalBytes,
        ));
      }

      // Load incoming transfers that are not completed
      final incomingResult = await db.query(
        'incoming_progress',
        where: 'status IS NULL OR status != ?',
        whereArgs: ['completed'],
      );

      for (final row in incomingResult) {
        final transferId = row['transfer_id'] as String;
        final deviceId = row['device_id'] as String;
        final fingerprint = row['fingerprint'] as String? ?? deviceId;
        final fileName = row['file_name'] as String;
        final filePath = row['file_path'] as String;
        final totalBytes = row['total_bytes'] as int;

        // Create transfer object for incoming
        final transfer = FileTransfer(
          id: transferId,
          deviceId: fingerprint, // Use fingerprint as deviceId for proper identification
          type: TransferType.file,
          filePath: filePath,
          fileName: fileName,
          totalBytes: totalBytes,
        );
        transfer.status = TransferStatus.queued;
        _activeTransfers[transferId] = transfer;

        // Trigger connection to device so incoming transfer can resume when peer sends file_start
        final device = _connectionManager.get(fingerprint);
        if (device != null) {
          // Device already connected, receive worker should handle resume
        } else {
          // Try to get peer info and connect using fingerprint
          final peerRegistry = _connectionManager.peerRegistry;
          final peer = peerRegistry.getPeer(fingerprint);
          if (peer != null && peer.lastKnownIp != null && peer.lastKnownPort != null) {
            connectDevice(
              deviceId: fingerprint,
              host: peer.lastKnownIp!,
              port: peer.lastKnownPort!,
              fingerprint: fingerprint,
            );
          }
        }
      }
    } catch (e) {
      // Log error but don't fail initialization
      print('Failed to restore pending transfers: $e');
    }
  }

  void _handleMainEvent(dynamic message) {
    if (message is TransferEvent) {
      _handleTransferEvent(message);
    }
  }

  void _handleNetworkEvent(dynamic message) {
    // Events from Network Isolate are TransferEvent types (ConnectionStateEvent from commands.dart)
    if (message is ConnectionStateEvent) {
      // Forward to Transfer Isolate so it can create/cleanup receive workers for incoming connections
      _transferSendPort?.send(UpdateConnectionStateCommand(
        deviceId: message.deviceId,
        state: message.state,
        error: message.error,
      ));
      _handleConnectionState(message);
    } else if (message is net_cmds.DeviceConnectionsEvent) {
      _handleDeviceConnections(message);
    } else if (message is net_cmds.ConnectionStatsEvent) {
      // Handle connection stats if needed
    }
  }

  void _handleDeviceConnections(net_cmds.DeviceConnectionsEvent event) {
    // Complete any pending query for this device
    final completer = _pendingConnectionQueries.remove(event.requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(event.connectionIds);
    }

    // Update ConnectionManager with actual connections from Network Isolate
    final device = _connectionManager.get(event.deviceId);
    if (device != null) {
      // ConnectionManager could track active connection IDs
      // For now, just log or update internal state
    }
  }

  void _handleConnectionQueryResponse(dynamic message) {
    if (message is net_cmds.DeviceConnectionsEvent) {
      final completer = _pendingConnectionQueries.remove(message.requestId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message.connectionIds);
      }
    }
  }

  void _handleTransferEvent(TransferEvent event) {
    switch (event) {
      case TransferProgressEvent progress:
        _updateTransferProgress(progress);
        break;
      case TransferCompletedEvent completed:
        _handleTransferCompleted(completed);
        break;
      case TransferFailedEvent failed:
        _handleTransferFailed(failed);
        break;
      case TransferCancelledEvent cancelled:
        _handleTransferCancelled(cancelled);
        break;
      case TransferPausedEvent paused:
        _handleTransferPaused(paused);
        break;
      case TransferResumedEvent resumed:
        _handleTransferResumed(resumed);
        break;
      case TransferQueuedEvent queued:
        _handleTransferQueued(queued);
        break;
      case TransfersListEvent _:
        break;
      case TransferStatusEvent _:
        break;
      case ConnectionStateEvent conn:
        _handleConnectionState(conn);
        break;
      case IsolateHealthEvent health:
        if (!health.isHealthy) {
          _handleIsolateUnhealthy(health.error);
        }
        break;
      case SchedulerStatsEvent _:
        break;
    }
    _routeEventToSubscribers(event);
  }

  void _updateTransferProgress(TransferProgressEvent progress) {
    final transfer = _activeTransfers[progress.transferId];
    if (transfer is FileTransfer) {
      transfer.transferredBytes = progress.transferredBytes;
      transfer.status = TransferStatus.transferring;
    }
  }

  void _handleTransferCompleted(TransferCompletedEvent event) {
    final transfer = _activeTransfers[event.transferId];
    if (transfer is FileTransfer) {
      transfer.status = TransferStatus.completed;
      transfer.transferredBytes = transfer.totalBytes;
    }
  }

  void _handleTransferFailed(TransferFailedEvent event) {
    final transfer = _activeTransfers[event.transferId];
    if (transfer != null) {
      transfer.status = TransferStatus.failed;
      transfer.error = event.error;
    }
  }

  void _handleTransferCancelled(TransferCancelledEvent event) {
    final transfer = _activeTransfers.remove(event.transferId);
    if (transfer != null) {
      transfer.status = TransferStatus.cancelled;
    }
  }

  void _handleTransferPaused(TransferPausedEvent event) {
    final transfer = _activeTransfers[event.transferId];
    if (transfer != null) {
      transfer.status = TransferStatus.paused;
    }
  }

  void _handleTransferResumed(TransferResumedEvent event) {
    final transfer = _activeTransfers[event.transferId];
    if (transfer != null) {
      transfer.status = TransferStatus.transferring;
    }
  }

  void _handleTransferQueued(TransferQueuedEvent event) {
    final transfer = FileTransfer(
      id: event.transferId,
      deviceId: event.deviceId,
      type: TransferType.file,
      filePath: '',
      fileName: event.fileName,
      totalBytes: event.totalBytes,
    );
    transfer.status = TransferStatus.queued;
    _activeTransfers[event.transferId] = transfer;
  }

  void _handleConnectionState(ConnectionStateEvent event) {
    // Handle connection state changes
  }

  void _handleIsolateUnhealthy(String? error) {
    // Attempt to restart isolates
    _restartIsolates();
  }

  Future<void> _restartIsolates() async {
    await shutdown();
    await Future.delayed(const Duration(seconds: 1));
    await initialize();
  }

  /// Get event stream for a specific transfer
  Stream<TransferEvent> transferEvents(String transferId) {
    return _transferEventControllers.putIfAbsent(transferId, () => StreamController<TransferEvent>.broadcast()).stream;
  }

  /// Get event stream for a specific device
  Stream<TransferEvent> deviceEvents(String deviceId) {
    return _deviceEventControllers.putIfAbsent(deviceId, () => StreamController<TransferEvent>.broadcast()).stream;
  }

  void _routeEventToSubscribers(TransferEvent event) {
    _eventController.add(event);
    
    // Route to transfer-specific stream
    if (event.transferId != null) {
      _transferEventControllers[event.transferId!]?.add(event);
    }
    
    // Route to device-specific stream
    if (event.deviceId != null) {
      _deviceEventControllers[event.deviceId!]?.add(event);
    }
  }

  /// Check if device has active connections in Network Isolate
  Future<bool> hasActiveConnections(String deviceId) async {
    if (!_isInitialized) return false;

    final requestId = 'conn_query_${_connectionQueryCounter++}_${DateTime.now().microsecondsSinceEpoch}';
    
    final completer = Completer<List<String>>();
    _pendingConnectionQueries[requestId] = completer;

    // Send command with the shared response port and request ID
    _networkSendPort?.send(net_cmds.GetDeviceConnectionsCommand(deviceId, _connectionQueryPort!.sendPort, requestId));

    try {
      final connectionIds = await completer.future.timeout(const Duration(seconds: 5), onTimeout: () {
        _pendingConnectionQueries.remove(requestId);
        if (!completer.isCompleted) {
          completer.complete([]);
        }
        return <String>[];
      });
      return connectionIds.isNotEmpty;
    } catch (_) {
      _pendingConnectionQueries.remove(requestId);
      if (!completer.isCompleted) {
        completer.complete([]);
      }
      return false;
    }
  }

  /// Send a file to a device
  Future<String> sendFile({
    required String deviceId,
    required File file,
  }) async {
    if (!_isInitialized) await initialize();

    // Check concurrent transfer limit
    final activeFileTransfers = _activeTransfers.values
        .where((t) => t is FileTransfer && (t.status == TransferStatus.transferring || t.status == TransferStatus.queued || t.status == TransferStatus.paused))
        .length;
    if (activeFileTransfers >= TransferConfig.maxConcurrentTransfers) {
      throw StateError('Max concurrent transfers (${TransferConfig.maxConcurrentTransfers}) reached');
    }

    final device = _connectionManager.get(deviceId);
    if (device == null) {
      throw StateError('Device not connected');
    }

    // Also check Network Isolate for active connections
    final hasConnections = await hasActiveConnections(deviceId);
    if (!hasConnections) {
      throw StateError('Device not connected (no active connections)');
    }

    if (!await file.exists()) {
      throw StateError('File does not exist: ${file.path}');
    }

    final size = await file.length();
    final transferId = DateTime.now().microsecondsSinceEpoch.toString();

    _transferSendPort?.send(SendFileCommand(
      transferId: transferId,
      deviceId: deviceId,
      filePath: file.path,
      fileName: file.uri.pathSegments.last,
      fileSize: size,
    ));

    return transferId;
  }

  /// Send a message to a device
  Future<String> sendMessage({
    required String deviceId,
    required String content,
    String contentType = 'text',
  }) async {
    if (!_isInitialized) await initialize();

    final device = _connectionManager.get(deviceId);
    if (device == null) {
      throw StateError('Device not connected');
    }

    final transferId = DateTime.now().microsecondsSinceEpoch.toString();

    _transferSendPort?.send(SendMessageCommand(
      transferId: transferId,
      deviceId: deviceId,
      content: content,
      contentType: contentType,
    ));

    return transferId;
  }

  /// Send a control message (volume, etc.) - highest priority
  Future<void> sendControl({
    required String deviceId,
    required Map<String, dynamic> payload,
  }) async {
    if (!_isInitialized) await initialize();

    final transferId = DateTime.now().microsecondsSinceEpoch.toString();

    _transferSendPort?.send(ControlCommand(
      transferId: transferId,
      deviceId: deviceId,
      payload: payload,
    ));
  }

  /// Pause a transfer
  Future<void> pauseTransfer(String transferId) async {
    _transferSendPort?.send(PauseTransferCommand(transferId));
  }

  /// Resume a paused transfer
  Future<void> resumeTransfer(String transferId) async {
    _transferSendPort?.send(ResumeTransferCommand(transferId));
  }

  /// Cancel a transfer
  Future<void> cancelTransfer(String transferId, String reason) async {
    _transferSendPort?.send(CancelTransferCommand(transferId, reason));
  }

  /// Prioritize a transfer
  Future<void> prioritizeTransfer(String transferId, SchedulerPriority priority) async {
    _transferSendPort?.send(PrioritizeTransferCommand(transferId, priority));
  }

  /// Send config update to isolates
  void sendConfigUpdate({
    int? chunkSize,
    int? maxConcurrentTransfers,
    bool? enableBandwidthThrottling,
    int? maxBytesPerSecond,
  }) {
    _transferSendPort?.send(UpdateConfigCommand(
      chunkSize: chunkSize,
      maxConcurrentTransfers: maxConcurrentTransfers,
      enableBandwidthThrottling: enableBandwidthThrottling,
      maxBytesPerSecond: maxBytesPerSecond,
    ));
  }

  /// Connect to a device
  void connectDevice({
    required String deviceId,
    required String host,
    required int port,
    required String fingerprint,
  }) {
    _transferSendPort?.send(ConnectDeviceCommand(
      deviceId: deviceId,
      host: host,
      port: port,
      fingerprint: fingerprint,
      trustPolicy: _trustPolicy,
    ));
  }

  /// Reconnect to a device (triggers reconnection in Network Isolate)
  void reconnectDevice({
    required String deviceId,
    required String host,
    required int port,
  }) {
    _networkSendPort?.send(net_cmds.ReconnectCommand(
      deviceId: deviceId,
      host: host,
      port: port,
    ));
  }

  /// Disconnect from a device
  void disconnectDevice(String deviceId) {
    _transferSendPort?.send(DisconnectDeviceCommand(deviceId));
  }

  /// Get all active transfers
  Future<List<TransferInfo>> getTransfers() async {
    final completer = Completer<List<TransferInfo>>();

    late StreamSubscription sub;
    sub = _eventController.stream.listen((event) {
      if (event is TransfersListEvent) {
        completer.complete(event.transfers);
        sub.cancel();
      }
    });

    _transferSendPort?.send(const GetTransfersCommand());

    return completer.future.timeout(const Duration(seconds: 5), onTimeout: () => []);
  }

  /// Get transfer status
  Future<TransferInfo?> getTransferStatus(String transferId) async {
    final completer = Completer<TransferInfo?>();

    late StreamSubscription sub;
    sub = _eventController.stream.listen((event) {
      if (event is TransferStatusEvent) {
        completer.complete(event.info);
        sub.cancel();
      }
    });

    _transferSendPort?.send(GetTransferStatusCommand(transferId));

    return completer.future.timeout(const Duration(seconds: 5), onTimeout: () => null);
  }

  /// Handle app lifecycle state changes
  void handleAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
        _pauseAllTransfers();
        break;
      case AppLifecycleState.resumed:
        _resumeAllTransfers();
        _reconnectDevices();
        break;
      case AppLifecycleState.detached:
        // App is being terminated, shutdown gracefully
        shutdown();
        break;
    }
  }

  void _pauseAllTransfers() {
    for (final transferId in _activeTransfers.keys) {
      final transfer = _activeTransfers[transferId];
      if (transfer is FileTransfer && 
          (transfer.status == TransferStatus.transferring || transfer.status == TransferStatus.queued)) {
        pauseTransfer(transferId);
      }
    }
  }

  void _resumeAllTransfers() {
    for (final transferId in _activeTransfers.keys) {
      final transfer = _activeTransfers[transferId];
      if (transfer is FileTransfer && transfer.status == TransferStatus.paused) {
        resumeTransfer(transferId);
      }
    }
  }

  void _reconnectDevices() {
    for (final deviceId in _connectionManager.devices.keys) {
      final device = _connectionManager.get(deviceId);
      if (device != null) {
        // Check if device has active connections
        hasActiveConnections(deviceId).then((hasConnections) {
          if (!hasConnections) {
            // Try to reconnect using stored endpoint
            final peer = _connectionManager.peerRegistry.getPeer(deviceId);
            if (peer != null && peer.lastKnownIp != null && peer.lastKnownPort != null) {
              reconnectDevice(
                deviceId: deviceId,
                host: peer.lastKnownIp!,
                port: peer.lastKnownPort!,
              );
            }
          }
        });
      }
    }
  }

  /// Shutdown the transfer system
  Future<void> shutdown() async {
    if (_isShuttingDown) return;
    _isShuttingDown = true;

    // Complete all pending connection queries with empty results
    for (final entry in _pendingConnectionQueries.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete([]);
      }
    }
    _pendingConnectionQueries.clear();

    try {
      _transferSendPort?.send(const ShutdownCommand());
      _networkSendPort?.send(const net_cmds.NetworkShutdownCommand());
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 500));

    _transferIsolate?.kill(priority: Isolate.immediate);
    _networkIsolate?.kill(priority: Isolate.immediate);

    await _eventController.close();
    for (final controller in _transferEventControllers.values) {
      await controller.close();
    }
    for (final controller in _deviceEventControllers.values) {
      await controller.close();
    }
    _transferEventControllers.clear();
    _deviceEventControllers.clear();
    _mainReceivePort?.close();
    _transferReceivePort?.close();
    _networkReceivePort?.close();
    _connectionQueryPort?.close();

    _transferIsolate = null;
    _networkIsolate = null;
    _transferSendPort = null;
    _networkSendPort = null;
    _mainReceivePort = null;
    _transferReceivePort = null;
    _networkReceivePort = null;
    _isInitialized = false;
    _isShuttingDown = false;
  }
}

/// Riverpod provider for TransferController
final transferControllerProvider = Provider<TransferController>((ref) {
  throw UnimplementedError('Use transferControllerProviderAsync');
});

final transferControllerProviderAsync = FutureProvider<TransferController>((ref) async {
  final connectionManager = await ref.watch(connectionManagerProvider.future);
  final identity = await ref.watch(deviceIdentityFutureProvider.future);
  final trustStore = await ref.watch(trustStoreProvider.future);
  final trustPolicy = ref.watch(trustPolicyProvider);

  final controller = TransferController(
    connectionManager: connectionManager,
    identity: identity,
    trustStore: trustStore,
    trustPolicy: trustPolicy,
  );

  await controller.initialize();

  ref.onDispose(() => controller.shutdown());

  return controller;
});

/// Active transfers state provider (updates from isolate events)
final activeTransfersProvider = StreamProvider.autoDispose<Map<String, Transfer>>((ref) async* {
  final controller = await ref.watch(transferControllerProviderAsync.future);
  yield controller.activeTransfers;

  await for (final _ in controller.events) {
    yield controller.activeTransfers;
  }
});