import 'dart:io';

/// Generic TCP server for listening to incoming connections
/// 
/// This class handles the server-side infrastructure for accepting
/// incoming TCP connections. When a connection is accepted, it's
/// passed to the onConnection callback for further processing.
class TcpServer {
  final int port;

  ServerSocket? _server;

  /// Callback invoked when a new socket connection is accepted
  final Future<void> Function(Socket socket) onConnection;

  TcpServer({
    required this.port,
    required this.onConnection,
  });

  /// Start listening for incoming connections on the specified port
  Future<void> start() async {
    _server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      shared: false,
    );

    _server!.listen(
      onConnection,
      onError: (error) {
        // TODO: Log error appropriately
      },
    );
  }

  /// Stop listening and close the server
  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}
