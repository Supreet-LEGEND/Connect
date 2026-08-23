import 'dart:async';
import 'dart:collection';

class AsyncSemaphore {
  int _available;

  final Queue<Completer<void>> _waiters = Queue();

  AsyncSemaphore(this._available);

  Future<void> acquire() async {
    if (_available > 0) {
      _available--;
      return;
    }

    final completer = Completer<void>();
    _waiters.add(completer);

    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      waiter.complete();
    } else {
      _available++;
    }
  }
}