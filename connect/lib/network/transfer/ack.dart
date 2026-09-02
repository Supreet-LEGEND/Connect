/// Acknowledgment for file transfer initiation
/// Sent by the receiver to confirm it's ready to receive the file
class FileStartAck {
  final String transferId;
  final String fileName;

  const FileStartAck({
    required this.transferId,
    required this.fileName,
  });
}

/// Acknowledgment for a received chunk
/// Sent by the receiver to confirm successful chunk reception
class ChunkAck {
  final String transferId;
  final int chunkIndex;

  const ChunkAck({
    required this.transferId,
    required this.chunkIndex,
  });
}

/// Acknowledgment for file transfer completion
/// Sent by the receiver to confirm the complete file was received
class FileEndAck {
  final String transferId;
  final String fileName;
  final bool success;
  final String? error;

  const FileEndAck({
    required this.transferId,
    required this.fileName,
    required this.success,
    this.error,
  });
}

/// Acknowledgment for transfer cancellation
/// Sent by the receiver to confirm the transfer was cancelled
class TransferCancelAck {
  final String transferId;
  final String reason;

  const TransferCancelAck({
    required this.transferId,
    required this.reason,
  });
}

/// Acknowledgment for message reception
/// Sent by the receiver to confirm the message was received
class MessageAck {
  final String messageId;
  final bool success;
  final String? error;

  const MessageAck({
    required this.messageId,
    required this.success,
    this.error,
  });
}

