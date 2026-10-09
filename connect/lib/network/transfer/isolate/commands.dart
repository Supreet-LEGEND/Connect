import 'package:connect/network/crypto/trust_store.dart';

sealed class TransferCommand {
  const TransferCommand();
}

sealed class TransferEvent {
  const TransferEvent();
  
  String? get transferId => null;
  String? get deviceId => null;
}

class SendFileCommand extends TransferCommand {
  final String transferId;
  final String deviceId;
  final String filePath;
  final String fileName;
  final int fileSize;
  final SchedulerPriority priority;

  const SendFileCommand({
    required this.transferId,
    required this.deviceId,
    required this.filePath,
    required this.fileName,
    required this.fileSize,
    this.priority = SchedulerPriority.file,
  });
}

class SendMessageCommand extends TransferCommand {
  final String transferId;
  final String deviceId;
  final String content;
  final String contentType;

  const SendMessageCommand({
    required this.transferId,
    required this.deviceId,
    required this.content,
    this.contentType = 'text',
  });
}

class ControlCommand extends TransferCommand {
  final String transferId;
  final String deviceId;
  final Map<String, dynamic> payload;

  const ControlCommand({
    required this.transferId,
    required this.deviceId,
    required this.payload,
  });
}

class PauseTransferCommand extends TransferCommand {
  final String transferId;

  const PauseTransferCommand(this.transferId);
}

class ResumeTransferCommand extends TransferCommand {
  final String transferId;

  const ResumeTransferCommand(this.transferId);
}

class CancelTransferCommand extends TransferCommand {
  final String transferId;
  final String reason;

  const CancelTransferCommand(this.transferId, this.reason);
}

class PrioritizeTransferCommand extends TransferCommand {
  final String transferId;
  final SchedulerPriority priority;

  const PrioritizeTransferCommand(this.transferId, this.priority);
}

class ConnectDeviceCommand extends TransferCommand {
  final String deviceId;
  final String host;
  final int port;
  final String fingerprint;
  final TrustPolicy trustPolicy;

  const ConnectDeviceCommand({
    required this.deviceId,
    required this.host,
    required this.port,
    required this.fingerprint,
    this.trustPolicy = TrustPolicy.tofu,
  });
}

class UpdateConnectionStateCommand extends TransferCommand {
  final String deviceId;
  final ConnectionState state;
  final String? error;

  const UpdateConnectionStateCommand({
    required this.deviceId,
    required this.state,
    this.error,
  });
}

class DisconnectDeviceCommand extends TransferCommand {
  final String deviceId;

  const DisconnectDeviceCommand(this.deviceId);
}

class GetTransfersCommand extends TransferCommand {
  const GetTransfersCommand();
}

class GetTransferStatusCommand extends TransferCommand {
  final String transferId;

  const GetTransferStatusCommand(this.transferId);
}

class ShutdownCommand extends TransferCommand {
  const ShutdownCommand();
}

class UpdateConfigCommand extends TransferCommand {
  final int? chunkSize;
  final int? maxConcurrentTransfers;
  final bool? enableBandwidthThrottling;
  final int? maxBytesPerSecond;
  final int? activeWindowSize;

  const UpdateConfigCommand({
    this.chunkSize,
    this.maxConcurrentTransfers,
    this.enableBandwidthThrottling,
    this.maxBytesPerSecond,
    this.activeWindowSize,
  });
}

class TransferProgressEvent extends TransferEvent {
  @override
  final String transferId;
  final int transferredBytes;
  final int totalBytes;
  final int completedChunks;
  final int totalChunks;
  final double speedBytesPerSecond;
  final Duration? estimatedTimeRemaining;

  const TransferProgressEvent({
    required this.transferId,
    required this.transferredBytes,
    required this.totalBytes,
    required this.completedChunks,
    required this.totalChunks,
    required this.speedBytesPerSecond,
    this.estimatedTimeRemaining,
  });

  double get progress => totalBytes > 0 ? transferredBytes / totalBytes : 0.0;

  @override
  String? get deviceId => null;
}

class TransferCompletedEvent extends TransferEvent {
  @override
  final String transferId;
  final String filePath;

  const TransferCompletedEvent(this.transferId, this.filePath);

  @override
  String? get deviceId => null;
}

class TransferFailedEvent extends TransferEvent {
  @override
  final String transferId;
  final String error;

  const TransferFailedEvent(this.transferId, this.error);

  @override
  String? get deviceId => null;
}

class TransferCancelledEvent extends TransferEvent {
  @override
  final String transferId;
  final String reason;

  const TransferCancelledEvent(this.transferId, this.reason);

  @override
  String? get deviceId => null;
}

class TransferPausedEvent extends TransferEvent {
  @override
  final String transferId;

  const TransferPausedEvent(this.transferId);

  @override
  String? get deviceId => null;
}

class TransferResumedEvent extends TransferEvent {
  @override
  final String transferId;

  const TransferResumedEvent(this.transferId);

  @override
  String? get deviceId => null;
}

class TransferQueuedEvent extends TransferEvent {
  @override
  final String transferId;
  @override
  final String deviceId;
  final String fileName;
  final int totalBytes;

  const TransferQueuedEvent({
    required this.transferId,
    required this.deviceId,
    required this.fileName,
    required this.totalBytes,
  });
}

class ConnectionStateEvent extends TransferEvent {
  @override
  final String deviceId;
  final ConnectionState state;
  final String? error;

  const ConnectionStateEvent(this.deviceId, this.state, {this.error});
}

enum ConnectionState {
  connecting,
  connected,
  disconnected,
  failed,
}

class SchedulerStatsEvent extends TransferEvent {
  final int totalChunksSent;
  final int totalChunksAcked;
  final int totalChunksFailed;
  final int totalRetries;
  final int totalBytesSent;
  final double successRate;
  final double throughputKBps;

  const SchedulerStatsEvent({
    required this.totalChunksSent,
    required this.totalChunksAcked,
    required this.totalChunksFailed,
    required this.totalRetries,
    required this.totalBytesSent,
    required this.successRate,
    required this.throughputKBps,
  });

  @override
  String? get transferId => null;
  @override
  String? get deviceId => null;
}

class IsolateHealthEvent extends TransferEvent {
  final bool isHealthy;
  final String? error;

  const IsolateHealthEvent(this.isHealthy, {this.error});

  @override
  String? get transferId => null;
  @override
  String? get deviceId => null;
}

class TransfersListEvent extends TransferEvent {
  final List<TransferInfo> transfers;

  const TransfersListEvent(this.transfers);

  @override
  String? get transferId => null;
  @override
  String? get deviceId => null;
}

class TransferStatusEvent extends TransferEvent {
  final TransferInfo info;

  const TransferStatusEvent(this.info);

  @override
  String? get transferId => info.id;
  @override
  String? get deviceId => info.deviceId;
}

class TransferInfo {
  final String id;
  final String deviceId;
  final String fileName;
  final int totalBytes;
  final int transferredBytes;
  final TransferStatus status;
  final SchedulerPriority priority;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? error;

  const TransferInfo({
    required this.id,
    required this.deviceId,
    required this.fileName,
    required this.totalBytes,
    required this.transferredBytes,
    required this.status,
    required this.priority,
    this.startedAt,
    this.completedAt,
    this.error,
  });

  double get progress => totalBytes > 0 ? transferredBytes / totalBytes : 0.0;
}

enum TransferStatus {
  queued,
  transferring,
  paused,
  completed,
  failed,
  cancelled,
}

enum SchedulerPriority {
  control,
  message,
  file,
}