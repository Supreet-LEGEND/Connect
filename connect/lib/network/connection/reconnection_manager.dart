import 'dart:async';
import 'dart:math' show min, pow;
import 'device_session.dart';

enum ReconnectionEventType {
  started,
  attempt,
  succeeded,
  failed,
  exhausted,
}

class ReconnectionEvent {
  final ReconnectionEventType type;
  final int attempt;
  final Duration delay;
  final Object? error;
  final DateTime timestamp = DateTime.now();

  ReconnectionEvent({
    required this.type,
    required this.attempt,
    required this.delay,
    this.error,
  });
}

class ReconnectionManager {
  final int maxRetries;
  final Duration initialDelay;
  final Duration maxDelay;
  final double backoffMultiplier;

  final StreamController<ReconnectionEvent> _eventController =
      StreamController<ReconnectionEvent>.broadcast();

  Stream<ReconnectionEvent> get events => _eventController.stream;

  ReconnectionManager({
    this.maxRetries = 5,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffMultiplier = 2.0,
  });

  Future<bool> reconnect({
    required DeviceSession session,
    required void Function() onBeforeConnect,
    required void Function() onAfterConnect,
  }) async {
    _emitEvent(ReconnectionEvent(
      type: ReconnectionEventType.started,
      attempt: 0,
      delay: Duration.zero,
    ));

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      final delay = _calculateBackoff(attempt);

      _emitEvent(ReconnectionEvent(
        type: ReconnectionEventType.attempt,
        attempt: attempt + 1,
        delay: delay,
      ));

      await Future.delayed(delay);

      try {
        onBeforeConnect();
        await session.reconnect();
        onAfterConnect();

        _emitEvent(ReconnectionEvent(
          type: ReconnectionEventType.succeeded,
          attempt: attempt + 1,
          delay: delay,
        ));

        return true;
      } catch (e) {
        _emitEvent(ReconnectionEvent(
          type: ReconnectionEventType.failed,
          attempt: attempt + 1,
          delay: delay,
          error: e,
        ));
      }
    }

    _emitEvent(ReconnectionEvent(
      type: ReconnectionEventType.exhausted,
      attempt: maxRetries,
      delay: _calculateBackoff(maxRetries - 1),
    ));

    return false;
  }

  Duration _calculateBackoff(int attempt) {
    final ms = (initialDelay.inMilliseconds * pow(backoffMultiplier, attempt)).toInt();
    return Duration(milliseconds: min(ms, maxDelay.inMilliseconds));
  }

  void _emitEvent(ReconnectionEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void dispose() {
    _eventController.close();
  }
}