import 'dart:io';

import '../crypto/device_identity.dart';
import 'incoming_connection.dart';
import 'connection_health.dart';
import '../crypto/trust_store.dart';

/// Generic TCP server for listening to incoming connections
///
/// This class handles the server-side infrastructure for accepting
/// incoming TCP connections. When a connection is accepted, it's
/// passed to the onConnection callback for further processing.
class TcpServer {
  final int port;
  final DeviceIdentity identity;
  final TrustStore trustStore;
  final TrustPolicy trustPolicy;

  ServerSocket? _server;

  /// Callback invoked when a new socket connection is accepted and handshake is complete
  final Future<void> Function(IncomingConnection connection, ConnectionHealth health) onConnection;

  TcpServer({
    required this.port,
    required this.identity,
    required this.trustStore,
    required this.onConnection,
    this.trustPolicy = TrustPolicy.tofu,
  });

  /// Start listening for incoming connections on the specified port
  Future<void> start() async {
    _server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      shared: false,
    );

    _server!.listen(
      _handleRawConnection,
      onError: (error) {
        // TODO: Log error appropriately
      },
    );
  }

  void _handleRawConnection(Socket socket) async {
    final health = ConnectionHealth(
      heartbeatInterval: const Duration(seconds: 5),
      heartbeatTimeout: const Duration(seconds: 15),
      maxMissedHeartbeats: 3,
    );

    try {
      final incomingConnection = IncomingConnection(
        socket: socket,
        identity: identity,
        trustStore: trustStore,
        trustPolicy: trustPolicy,
      );

      await incomingConnection.performHandshake();

      await onConnection(incomingConnection, health);
    } catch (e) {
      await socket.close();
      health.dispose();
    }
  }

  /// Stop listening and close the server
  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}