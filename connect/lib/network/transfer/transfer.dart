import 'dart:io';

enum TransferType {
  file,
  message,
  control,
}

enum TransferStatus {
  queued,
  transferring,
  paused,
  reconnecting,
  completed,
  failed,
  cancelled,
}

/// Base abstract class for all transfer operations (send and receive)
abstract class Transfer {
  /// Unique identifier for this transfer
  final String id;

  /// Device ID this transfer is with
  final String deviceId;

  /// Type of transfer (file, message, control)
  final TransferType type;

  /// Current status of the transfer
  TransferStatus status;

  /// Error object if transfer failed
  Object? error;

  /// Timestamp when transfer was created
  final DateTime timestamp;

  /// Priority level for this transfer (0 = lowest, higher = higher priority)
  int priority;

  Transfer({
    required this.id,
    required this.deviceId,
    required this.type,
    this.status = TransferStatus.queued,
    this.error,
    DateTime? timestamp,
    this.priority = 0,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Start the transfer
  Future<void> start();

  /// Cancel the transfer
  Future<void> cancel();

  /// Pause the transfer
  Future<void> pause();

  /// Resume the transfer
  Future<void> resume();

  /// Check if transfer is completed
  bool get isCompleted => status == TransferStatus.completed;

  /// Check if transfer has failed
  bool get isFailed => status == TransferStatus.failed;

  /// Check if transfer is cancelled
  bool get isCancelled => status == TransferStatus.cancelled;

  /// Check if transfer is paused
  bool get isPaused => status == TransferStatus.paused;
}

/// Outgoing file transfer (send to device)
class FileTransfer extends Transfer {
  /// File path on local device
  final String? filePath;

  /// File name
  final String? fileName;

  /// Total bytes to transfer
  final int totalBytes;

  /// Bytes already transferred
  int transferredBytes = 0;

  /// Next chunk index to send
  int nextChunk;

  FileTransfer({
    required super.id,
    required super.deviceId,
    required super.type,
    required this.totalBytes,
    this.nextChunk = 0,
    this.filePath,
    this.fileName,
    super.status,
    super.error,
    super.timestamp,
    super.priority,
  });

  /// Progress as a percentage (0.0 to 1.0)
  double get progress {
    if (totalBytes == 0) {
      return 1.0;
    }
    return transferredBytes / totalBytes;
  }

  @override
  Future<void> start() async {
    status = TransferStatus.transferring;
  }

  @override
  Future<void> cancel() async {
    status = TransferStatus.cancelled;
  }

  @override
  Future<void> pause() async {
    status = TransferStatus.paused;
  }

  @override
  Future<void> resume() async {
    status = TransferStatus.transferring;
  }
}

/// Incoming file transfer (receive from device)
class ReceivingFileTransfer extends Transfer {
  /// File name being received
  final String fileName;

  /// Total file size
  final int fileSize;

  /// RandomAccessFile for writing received data
  final RandomAccessFile file;

  /// Set of received chunk indices
  final Set<int> receivedChunks = {};

  ReceivingFileTransfer({
    required super.id,
    required super.deviceId,
    required this.fileName,
    required this.fileSize,
    required this.file,
    super.type = TransferType.file,
    super.status,
    super.error,
    super.timestamp,
    super.priority,
  });

  /// Progress as a percentage (0.0 to 1.0)
  double get progress {
    if (fileSize == 0) {
      return 1.0;
    }
    return receivedChunks.length / (fileSize ~/ (1024 * 1024) + 1);
  }

  @override
  Future<void> start() async {
    status = TransferStatus.transferring;
  }

  @override
  Future<void> cancel() async {
    status = TransferStatus.cancelled;
  }

  @override
  Future<void> pause() async {
    status = TransferStatus.paused;
  }

  @override
  Future<void> resume() async {
    status = TransferStatus.transferring;
  }
}

/// Outgoing message transfer (send to device)
class MessageTransfer extends Transfer {
  /// Message content
  final String content;

  /// Message content type (e.g., 'text', 'json', etc.)
  final String contentType;

  MessageTransfer({
    required super.id,
    required super.deviceId,
    required this.content,
    this.contentType = 'text',
    super.status,
    super.error,
    super.timestamp,
    super.priority = 1, // Messages get higher priority than files
  }) : super(
    type: TransferType.message,
  );

  @override
  Future<void> start() async {
    status = TransferStatus.transferring;
  }

  @override
  Future<void> cancel() async {
    status = TransferStatus.cancelled;
  }

  @override
  Future<void> pause() async {
    status = TransferStatus.paused;
  }

  @override
  Future<void> resume() async {
    status = TransferStatus.transferring;
  }
}

/// Incoming message transfer (receive from device)
class ReceivingMessageTransfer extends Transfer {
  /// Received message content
  final String content;

  /// Message content type
  final String contentType;

  ReceivingMessageTransfer({
    required super.id,
    required super.deviceId,
    required this.content,
    this.contentType = 'text',
    super.status,
    super.error,
    super.timestamp,
    super.priority = 1,
  }) : super(
    type: TransferType.message,
  );

  @override
  Future<void> start() async {
    status = TransferStatus.transferring;
  }

  @override
  Future<void> cancel() async {
    status = TransferStatus.cancelled;
  }

  @override
  Future<void> pause() async {
    status = TransferStatus.paused;
  }

  @override
  Future<void> resume() async {
    status = TransferStatus.transferring;
  }
}

/// Outgoing control transfer (send to device)
/// Used for control protocol messages and commands
class ControlTransfer extends Transfer {
  /// Control command or data
  final Map<String, dynamic> controlData;

  ControlTransfer({
    required super.id,
    required super.deviceId,
    required this.controlData,
    super.status,
    super.error,
    super.timestamp,
    super.priority = 2, // Control messages get highest priority
  }) : super(
    type: TransferType.control,
  );

  @override
  Future<void> start() async {
    status = TransferStatus.transferring;
  }

  @override
  Future<void> cancel() async {
    status = TransferStatus.cancelled;
  }

  @override
  Future<void> pause() async {
    status = TransferStatus.paused;
  }

  @override
  Future<void> resume() async {
    status = TransferStatus.transferring;
  }
}

/// Incoming control transfer (receive from device)
/// Used for receiving control protocol messages and commands
class ReceivingControlTransfer extends Transfer {
  /// Received control command or data
  final Map<String, dynamic> controlData;

  ReceivingControlTransfer({
    required super.id,
    required super.deviceId,
    required this.controlData,
    super.status,
    super.error,
    super.timestamp,
    super.priority = 2,
  }) : super(
    type: TransferType.control,
  );

  @override
  Future<void> start() async {
    status = TransferStatus.transferring;
  }

  @override
  Future<void> cancel() async {
    status = TransferStatus.cancelled;
  }

  @override
  Future<void> pause() async {
    status = TransferStatus.paused;
  }

  @override
  Future<void> resume() async {
    status = TransferStatus.transferring;
  }
}

