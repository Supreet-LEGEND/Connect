import 'dart:collection';
import 'dart:typed_data';

enum FramePriority {
  control,
  message,
  file,
}

class OutgoingFrame {
  final FramePriority priority;
  final Uint8List data;

  OutgoingFrame({
    required this.priority,
    required this.data,
  });
}

class PriorityFrameQueue {
  final Queue<OutgoingFrame> _control = Queue();
  final Queue<OutgoingFrame> _messages = Queue();
  final Queue<OutgoingFrame> _files = Queue();

  void add(OutgoingFrame frame) {
    switch (frame.priority) {
      case FramePriority.control:
        _control.add(frame);
        break;

      case FramePriority.message:
        _messages.add(frame);
        break;

      case FramePriority.file:
        _files.add(frame);
        break;
    }
  }

  OutgoingFrame? removeFirst() {
    if (_control.isNotEmpty) {
      return _control.removeFirst();
    }

    if (_messages.isNotEmpty) {
      return _messages.removeFirst();
    }

    if (_files.isNotEmpty) {
      return _files.removeFirst();
    }

    return null;
  }

  bool get isEmpty =>
      _control.isEmpty &&
      _messages.isEmpty &&
      _files.isEmpty;
}