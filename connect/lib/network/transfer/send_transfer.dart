enum TransferType {
  file,
  message,
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

class Transfer {
  final String id;
  final String deviceId;
  final TransferType type;

  final String? filePath;
  final String? fileName;

  // final int chunkSize;
  // final int totalChunks;

  final int totalBytes;

  int transferredBytes = 0;

  TransferStatus status =
      TransferStatus.queued;

  Object? error;

  int nextChunk;

  Transfer({
    required this.id,
    required this.deviceId,
    required this.type,
    required this.totalBytes,
    this.nextChunk = 0,
    this.filePath,
    this.fileName,
  });

  double get progress {
    if (totalBytes == 0) {
      return 1.0;
    }

    return transferredBytes / totalBytes;
  }
}