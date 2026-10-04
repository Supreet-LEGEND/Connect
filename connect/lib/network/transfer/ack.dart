/// Acknowledgment for file transfer initiation
/// Sent by the receiver to confirm it's ready to receive the file
class FileStartAck {
  final String transferId;
  final String fileName;
  final List<int> completedChunks; // For resume support

  const FileStartAck({
    required this.transferId,
    required this.fileName,
    this.completedChunks = const [],
  });

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'fileName': fileName,
    'completedChunks': completedChunks,
  };

  static FileStartAck fromJson(Map<String, dynamic> json) => FileStartAck(
    transferId: json['transferId'] as String,
    fileName: json['fileName'] as String,
    completedChunks: (json['completedChunks'] as List<dynamic>?)?.map((e) => e as int).toList() ?? [],
  );
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

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'chunkIndex': chunkIndex,
  };

  static ChunkAck fromJson(Map<String, dynamic> json) => ChunkAck(
    transferId: json['transferId'] as String,
    chunkIndex: json['chunkIndex'] as int,
  );
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

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'fileName': fileName,
    'success': success,
    'error': error,
  };

  static FileEndAck fromJson(Map<String, dynamic> json) => FileEndAck(
    transferId: json['transferId'] as String,
    fileName: json['fileName'] as String,
    success: json['success'] as bool,
    error: json['error'] as String?,
  );
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

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'reason': reason,
  };

  static TransferCancelAck fromJson(Map<String, dynamic> json) => TransferCancelAck(
    transferId: json['transferId'] as String,
    reason: json['reason'] as String,
  );
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

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'success': success,
    'error': error,
  };

  static MessageAck fromJson(Map<String, dynamic> json) => MessageAck(
    messageId: json['messageId'] as String,
    success: json['success'] as bool,
    error: json['error'] as String?,
  );
}

/// Resume request for interrupted transfers
/// Sent by sender to resume an interrupted transfer
class TransferResumeRequest {
  final String transferId;
  final int resumeFromChunk;
  final List<int> missingChunks;

  const TransferResumeRequest({
    required this.transferId,
    required this.resumeFromChunk,
    required this.missingChunks,
  });

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'resumeFromChunk': resumeFromChunk,
    'missingChunks': missingChunks,
  };

  static TransferResumeRequest fromJson(Map<String, dynamic> json) => TransferResumeRequest(
    transferId: json['transferId'] as String,
    resumeFromChunk: json['resumeFromChunk'] as int,
    missingChunks: (json['missingChunks'] as List<dynamic>?)?.map((e) => e as int).toList() ?? [],
  );
}