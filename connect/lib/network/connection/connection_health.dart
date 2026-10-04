import 'dart:async';

/// Interface for connections that support heartbeat
abstract class HeartbeatCapable {
  bool get isConnected;
  bool get isHandshakeComplete;
  Future<void> sendHeartbeat();
}

enum ConnectionState {
  connected,
  reconnecting,
  disconnected,
}

class ConnectionHealth {
  final Duration heartbeatInterval;
  final Duration heartbeatTimeout;
  final int maxMissedHeartbeats;

  Timer? _heartbeatTimer;
  int _missedHeartbeats = 0;
  ConnectionState _state = ConnectionState.connected;

  final StreamController<ConnectionState> _stateController =
      StreamController<ConnectionState>.broadcast();

  Stream<ConnectionState> get stateChanges => _stateController.stream;

  ConnectionState get currentState => _state;

  ConnectionHealth({
    this.heartbeatInterval = const Duration(seconds: 5),
    this.heartbeatTimeout = const Duration(seconds: 10),
    this.maxMissedHeartbeats = 3,
  });

  void startHeartbeat(HeartbeatCapable connection) {
    _heartbeatTimer?.cancel();
    _missedHeartbeats = 0;
    _state = ConnectionState.connected;
    _stateController.add(_state);

    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) async {
      if (!connection.isConnected || !connection.isHandshakeComplete) {
        _onMissedHeartbeat();
        return;
      }

      try {
        await connection.sendHeartbeat();
      } catch (e) {
        _onMissedHeartbeat();
      }
    });
  }

  void onHeartbeatReceived() {
    _missedHeartbeats = 0;
    if (_state != ConnectionState.connected) {
      _state = ConnectionState.connected;
      _stateController.add(_state);
    }
  }

  void _onMissedHeartbeat() {
    _missedHeartbeats++;
    if (_missedHeartbeats >= maxMissedHeartbeats) {
      _state = ConnectionState.disconnected;
      _stateController.add(_state);
      stop();
    }
  }

  void stop() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void dispose() {
    stop();
    _stateController.close();
  }
}