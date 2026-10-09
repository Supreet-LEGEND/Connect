import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'package:connect/network/connection/connection.dart';
import 'package:connect/network/connection/connection_pool.dart';
import 'package:connect/network/connection/incoming_connection.dart';
import 'package:connect/network/protocol/frame_parser.dart';
import 'package:connect/network/crypto/device_identity.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:connect/network/transfer/isolate/commands.dart';
import 'package:connect/network/transfer/isolate/network_commands.dart' as net_cmds;
import 'package:connect/app/tcp_config.dart';

class NetworkIsolateParams {
  final SendPort mainSendPort;
  final String identityPrivateKeyPem;
  final String trustStoreJson;
  final TrustPolicy trustPolicy;
  final int listenPort;
  final String peerRegistryJson; // fingerprint -> deviceId mapping

  NetworkIsolateParams({
    required this.mainSendPort,
    required this.identityPrivateKeyPem,
    required this.trustStoreJson,
    required this.trustPolicy,
    this.listenPort = BaseTcpConfig.tcpPort,
    this.peerRegistryJson = '{}',
  });
}

void networkIsolateEntrypoint(NetworkIsolateParams params) {
  final receivePort = ReceivePort();
  params.mainSendPort.send(receivePort.sendPort);

  final worker = _NetworkIsolateWorker(
    identityPrivateKeyPem: params.identityPrivateKeyPem,
    trustStoreJson: params.trustStoreJson,
    trustPolicy: params.trustPolicy,
    listenPort: params.listenPort,
    peerRegistryJson: params.peerRegistryJson,
    mainSendPort: params.mainSendPort,
  );

  // Set up listener IMMEDIATELY (sync) to avoid "stream already listened" race condition
  receivePort.listen((message) {
    if (message is net_cmds.NetworkCommand) {
      worker.handleCommand(message);
    }
  });

  // Start async initialization in background (don't await)
  worker.initializeAsync();
}

class _NetworkIsolateWorker {
  final String identityPrivateKeyPem;
  final String trustStoreJson;
  final TrustPolicy trustPolicy;
  final int listenPort;
  final String peerRegistryJson;
  final SendPort mainSendPort;

  final Map<String, _NetworkConnection> _connections = {};
  final Map<String, ConnectionPool> _connectionPools = {};

  // Track device endpoints for reconnection
  final Map<String, _DeviceEndpoint> _deviceEndpoints = {};

  // Reconnection timer
  Timer? _reconnectTimer;

  DeviceIdentity? _identity;
  TrustStore? _trustStore;
  ServerSocket? _serverSocket;
  StreamSubscription? _serverSubscription;
  Map<String, String> _fingerprintToDeviceId = {};

  // Initialization state tracking
  bool _isInitialized = false;
  final List<net_cmds.NetworkCommand> _commandQueue = [];

  _NetworkIsolateWorker({
    required this.identityPrivateKeyPem,
    required this.trustStoreJson,
    required this.trustPolicy,
    required this.listenPort,
    required this.peerRegistryJson,
    required this.mainSendPort,
  }) {
    _parsePeerRegistry();
    _startReconnectTimer();
  }

  Future<void> initializeAsync() async {
    await _initializeCrypto();
    _startServer();
    _isInitialized = true;
    // Process queued commands
    for (final command in _commandQueue) {
      handleCommand(command);
    }
    _commandQueue.clear();
  }

  void _parsePeerRegistry() {
    try {
      final data = jsonDecode(peerRegistryJson) as Map<String, dynamic>;
      _fingerprintToDeviceId = data.map((k, v) => MapEntry(k, v as String));
    } catch (e) {
      _fingerprintToDeviceId = {};
    }
  }

  Future<void> _initializeCrypto() async {
    _identity = await DeviceIdentity.createFromPrivateKeyPem(identityPrivateKeyPem);
    _trustStore = TrustStore.fromJson(trustStoreJson);
  }

  void _startReconnectTimer() {
    _reconnectTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkAndReconnect();
    });
  }

  void _checkAndReconnect() {
    for (final entry in _deviceEndpoints.entries) {
      final deviceId = entry.key;
      final endpoint = entry.value;
      
      // Check if we have any active connections for this device
      final hasActiveConnection = _connections.values.any((conn) => 
        conn.deviceId == deviceId && conn.isConnected
      );
      
      if (!hasActiveConnection && !endpoint.isConnecting) {
        // Try to reconnect
        _attemptReconnect(deviceId, endpoint);
      }
    }
  }

  Future<void> _attemptReconnect(String deviceId, _DeviceEndpoint endpoint) async {
    if (endpoint.isConnecting) return;
    
    endpoint.isConnecting = true;
    endpoint.reconnectAttempts++;
    
    try {
      final pool = ConnectionPool(
        deviceId: deviceId,
        host: endpoint.host,
        port: endpoint.port,
        identity: _identity!,
        trustStore: _trustStore!,
        trustPolicy: trustPolicy,
        connectionCount: 4,
      );

      _connectionPools[deviceId] = pool;

      await pool.connect();

      for (int i = 0; i < pool.connections.length; i++) {
        final connection = pool.connections[i];
        final connectionId = '${deviceId}-$i';

        final networkConn = _NetworkConnection(
          connectionId: connectionId,
          deviceId: deviceId,
          connection: connection,
          mainSendPort: mainSendPort,
          isIncoming: false,
        );

        _connections[connectionId] = networkConn;
        await networkConn.connect();
      }

      endpoint.isConnecting = false;
      endpoint.reconnectAttempts = 0;
      
      // Send updated connection IDs to Transfer Isolate via DeviceConnectionsEvent
      final newConnectionIds = List.generate(4, (i) => '$deviceId-$i');
      mainSendPort.send(net_cmds.DeviceConnectionsEvent(
        deviceId,
        newConnectionIds,
      ));
      
      mainSendPort.send(ConnectionStateEvent(
        deviceId,
        ConnectionState.connected,
      ));
    } catch (e) {
      endpoint.isConnecting = false;
      // Log error but don't spam - will retry on next timer tick
    }
  }

  void _startServer() async {
    int port = listenPort;
    const maxPortAttempts = 3;
    
    for (int attempt = 0; attempt < maxPortAttempts; attempt++) {
      try {
        _serverSocket = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          port,
          shared: false,
        );

        _serverSubscription = _serverSocket!.listen(
          _handleIncomingConnection,
          onError: (error) {
            mainSendPort.send(net_cmds.NetworkErrorEvent('server', error.toString()));
          },
          onDone: () {
            mainSendPort.send(net_cmds.NetworkErrorEvent('server', 'Server socket closed'));
          },
        );
        
        if (attempt > 0) {
          mainSendPort.send(net_cmds.NetworkErrorEvent('server', 'Bound to fallback port $port after $attempt attempts'));
        }
        return;
      } catch (e) {
        if (attempt < maxPortAttempts - 1) {
          port = listenPort + attempt + 1;
          print('Port $port in use, trying $port...');
        } else {
          mainSendPort.send(net_cmds.NetworkErrorEvent('server', 'Failed to start server after $maxPortAttempts attempts: $e'));
        }
      }
    }
  }

  void _handleIncomingConnection(Socket socket) async {
    try {
      // Create IncomingConnection for handshake
      final incomingConnection = IncomingConnection(
        socket: socket,
        identity: _identity!,
        trustStore: _trustStore!,
        trustPolicy: trustPolicy,
      );

      // Perform handshake as responder
      await incomingConnection.performHandshake();

      // Get peer fingerprint
      final peerKey = incomingConnection.peerIdentityPublicKey;
      if (peerKey == null) {
        await socket.close();
        return;
      }

      final digest = sha256.convert(peerKey.bytes);
      final fingerprint = base64Encode(digest.bytes);

      // Look up deviceId from peer registry
      final deviceId = _fingerprintToDeviceId[fingerprint] ?? fingerprint;

      // Create connection ID using deviceId with consistent format: $deviceId-incoming
      final connectionId = '$deviceId-incoming';

      // Wrap in _NetworkConnection
      final networkConn = _NetworkConnection(
        connectionId: connectionId,
        deviceId: deviceId,
        connection: incomingConnection,
        mainSendPort: mainSendPort,
        isIncoming: true,
      );

      _connections[connectionId] = networkConn;

      // Start frame processing
      await networkConn.connect();

      // Notify main isolate
      mainSendPort.send(ConnectionStateEvent(networkConn.deviceId, ConnectionState.connected));
    } catch (e) {
      await socket.close();
      mainSendPort.send(net_cmds.NetworkErrorEvent('incoming', 'Handshake failed: $e'));
    }
  }

void handleCommand(net_cmds.NetworkCommand command) {
    // Queue commands until initialization is complete (except heartbeat which is safe)
    if (!_isInitialized && command is! net_cmds.HeartbeatCommand) {
      _commandQueue.add(command);
      return;
    }

    switch (command) {
      case net_cmds.SendFrameCommand cmd:
        _handleSendFrame(cmd);
        break;
      case net_cmds.ConnectCommand cmd:
        _handleConnect(cmd);
        break;
      case net_cmds.ReconnectCommand cmd:
        _handleReconnect(cmd);
        break;
      case net_cmds.DisconnectCommand cmd:
        _handleDisconnect(cmd.connectionId);
        break;
      case net_cmds.CloseConnectionCommand cmd:
        _handleCloseConnection(cmd.connectionId);
        break;
      case net_cmds.GetConnectionStateCommand cmd:
        _handleGetConnectionState(cmd.connectionId);
        break;
      case net_cmds.GetDeviceConnectionsCommand cmd:
        _handleGetDeviceConnections(cmd.deviceId, cmd.responsePort, cmd.requestId);
        break;
      case net_cmds.HeartbeatCommand cmd:
        _handleHeartbeat(cmd.connectionId);
        break;
      case net_cmds.NetworkShutdownCommand cmd:
        _shutdown();
        break;
      case net_cmds.UpdateConfigCommand cmd:
        _handleUpdateConfig(cmd);
        break;
      default:
        break;
    }
  }

  void _handleUpdateConfig(net_cmds.UpdateConfigCommand cmd) {
    // Network isolate doesn't need most config, but could log or forward to connections
    // For now, just acknowledge
  }

  void _handleGetDeviceConnections(String deviceId, SendPort? responsePort, String requestId) {
    final connectionIds = _connections.keys
        .where((id) => id.startsWith('$deviceId-'))
        .toList();
    final event = net_cmds.DeviceConnectionsEvent(deviceId, connectionIds, requestId);
    if (responsePort != null) {
      responsePort.send(event);
    } else {
      mainSendPort.send(event);
    }
  }

  void _handleSendFrame(net_cmds.SendFrameCommand cmd) {
    final conn = _connections[cmd.connectionId];
    if (conn != null && conn.isConnected) {
      conn.sendFrame(cmd.type, cmd.header, cmd.payload, cmd.priority);
    }
  }

  void _handleConnect(net_cmds.ConnectCommand cmd) {
    // Store endpoint for reconnection
    _deviceEndpoints[cmd.deviceId] = _DeviceEndpoint(
      host: cmd.host,
      port: cmd.port,
    );

    final pool = ConnectionPool(
      deviceId: cmd.deviceId,
      host: cmd.host,
      port: cmd.port,
      identity: _identity!,
      trustStore: _trustStore!,
      trustPolicy: cmd.trustPolicy,
      connectionCount: 4,
    );

    _connectionPools[cmd.deviceId] = pool;

    pool.connect().then((_) {
      for (int i = 0; i < pool.connections.length; i++) {
        final connection = pool.connections[i];
        final connectionId = '${cmd.deviceId}-$i';

        final networkConn = _NetworkConnection(
          connectionId: connectionId,
          deviceId: cmd.deviceId,
          connection: connection,
          mainSendPort: mainSendPort,
          isIncoming: false,
        );

        _connections[connectionId] = networkConn;
      }

      mainSendPort.send(ConnectionStateEvent(
        cmd.deviceId,
        ConnectionState.connected,
      ));
    }).catchError((error) {
      mainSendPort.send(ConnectionStateEvent(
        cmd.deviceId,
        ConnectionState.failed,
        error: error.toString(),
      ));
    });
  }

  void _handleReconnect(net_cmds.ReconnectCommand cmd) {
    // Update endpoint if provided
    _deviceEndpoints[cmd.deviceId] = _DeviceEndpoint(
      host: cmd.host,
      port: cmd.port,
    );
    
    // Trigger immediate reconnection attempt
    final endpoint = _deviceEndpoints[cmd.deviceId]!;
    _attemptReconnect(cmd.deviceId, endpoint);
  }

  void _handleDisconnect(String connectionId) {
    final conn = _connections.remove(connectionId);
    conn?.disconnect();
  }

  void _handleCloseConnection(String connectionId) {
    final conn = _connections.remove(connectionId);
    conn?.close();
  }

  void _handleGetConnectionState(String connectionId) {
    final conn = _connections[connectionId];
    if (conn != null) {
      mainSendPort.send(ConnectionStateEvent(conn.deviceId, conn.state));
    }
  }

  void _handleHeartbeat(String connectionId) {
    final conn = _connections[connectionId];
    conn?.sendHeartbeat();
  }

  void _shutdown() {
    _reconnectTimer?.cancel();
    _serverSubscription?.cancel();
    _serverSocket?.close();

    for (final conn in _connections.values) {
      conn.close();
    }
    _connections.clear();

    for (final pool in _connectionPools.values) {
      pool.close();
    }
    _connectionPools.clear();
    _deviceEndpoints.clear();
  }
}

class _DeviceEndpoint {
  final String host;
  final int port;
  bool isConnecting = false;
  int reconnectAttempts = 0;

  _DeviceEndpoint({
    required this.host,
    required this.port,
  });
}

class _NetworkConnection {
  final String connectionId;
  final String deviceId;
  final dynamic connection; // Can be Connection or IncomingConnection
  final SendPort mainSendPort;
  final bool isIncoming;

  ConnectionState state = ConnectionState.connecting;
  StreamSubscription? _frameSubscription;

  int _bytesSent = 0;
  int _bytesReceived = 0;
  int _framesSent = 0;
  int _framesReceived = 0;
  int _decryptionErrors = 0;
  final DateTime _connectedAt = DateTime.now();

  _NetworkConnection({
    required this.connectionId,
    required this.deviceId,
    required this.connection,
    required this.mainSendPort,
    required this.isIncoming,
  });

  bool get isConnected => state == ConnectionState.connected && _isConnectionAlive();

  bool _isConnectionAlive() {
    if (isIncoming) {
      return (connection as IncomingConnection).isConnected;
    } else {
      return (connection as Connection).isConnected;
    }
  }

  Future<void> connect() async {
    try {
      if (isIncoming) {
        // IncomingConnection already did handshake, just start frame processing
        (connection as IncomingConnection).channel!.startFrameProcessing();
      } else {
        await (connection as Connection).connect();
      }
      state = ConnectionState.connected;

      _frameSubscription = _getFrameStream().listen(
        _handleFrame,
        onError: (error) {
          _handleError(error);
        },
      );

mainSendPort.send(ConnectionStateEvent(deviceId, state));
    } catch (e) {
      state = ConnectionState.failed;
      mainSendPort.send(ConnectionStateEvent(deviceId, state, error: e.toString()));
    }
  }

  Stream<ParsedFrame> _getFrameStream() {
    if (isIncoming) {
      return (connection as IncomingConnection).frames.map((frameMap) {
        // Convert IncomingConnection frame format to ParsedFrame
        return ParsedFrame(
          header: Map<String, dynamic>.from(frameMap['header']),
          payload: frameMap['payload'] as List<int>,
        );
      });
    } else {
      return (connection as Connection).frames;
    }
  }

  void _handleFrame(ParsedFrame frame) {
    _framesReceived++;
    _bytesReceived += frame.payload.length;

    final type = frame.header['type'] as String? ?? '';

    if (type == 'heartbeat_pong') {
      return;
    }

    mainSendPort.send(net_cmds.FrameReceivedEvent(
      connectionId: connectionId,
      type: type,
      header: frame.header,
      payload: Uint8List.fromList(frame.payload),
    ));
  }

  void _handleError(Object error) {
    state = ConnectionState.failed;
    mainSendPort.send(ConnectionStateEvent(deviceId, state, error: error.toString()));
    mainSendPort.send(net_cmds.NetworkErrorEvent(connectionId, error.toString()));
  }

  void sendFrame(String type, Map<String, dynamic> header, Uint8List payload, SchedulerPriority priority) {
    if (!isConnected) return;

    _framesSent++;
    _bytesSent += payload.length;

    header['priority'] = priority.name;

    if (isIncoming) {
      (connection as IncomingConnection).sendFrame(
        type: type,
        header: header,
        payload: payload,
      ).catchError((error) {
        _handleError(error);
      });
    } else {
      (connection as Connection).send(
        type: type,
        metadata: header,
        plaintext: payload,
      ).catchError((error) {
        _handleError(error);
      });
    }
  }

  void sendHeartbeat() {
    if (isConnected) {
      if (isIncoming) {
        (connection as IncomingConnection).sendHeartbeat();
      } else {
        (connection as Connection).sendHeartbeat();
      }
    }
  }

  void disconnect() {
    state = ConnectionState.disconnected;
    _frameSubscription?.cancel();
    if (isIncoming) {
      (connection as IncomingConnection).close();
    } else {
      (connection as Connection).close();
    }
    mainSendPort.send(ConnectionStateEvent(deviceId, state));
  }

  void close() {
    disconnect();
  }

  net_cmds.ConnectionStatsEvent getStats() {
    return net_cmds.ConnectionStatsEvent(
      connectionId: connectionId,
      bytesSent: _bytesSent,
      bytesReceived: _bytesReceived,
      framesSent: _framesSent,
      framesReceived: _framesReceived,
      decryptionErrors: _decryptionErrors,
      uptime: DateTime.now().difference(_connectedAt),
    );
  }
}