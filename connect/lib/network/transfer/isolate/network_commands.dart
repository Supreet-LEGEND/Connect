import 'dart:isolate';
import 'dart:typed_data';

import 'commands.dart';
import 'package:connect/network/crypto/trust_store.dart';

sealed class NetworkCommand {
  const NetworkCommand();
}

sealed class NetworkEvent {
  const NetworkEvent();
}

class SendFrameCommand extends NetworkCommand {
  final String connectionId;
  final String type;
  final Map<String, dynamic> header;
  final Uint8List payload;
  final SchedulerPriority priority;

  const SendFrameCommand({
    required this.connectionId,
    required this.type,
    required this.header,
    required this.payload,
    this.priority = SchedulerPriority.file,
  });
}

class ConnectCommand extends NetworkCommand {
  final String connectionId;
  final String deviceId;
  final String host;
  final int port;
  final TrustPolicy trustPolicy;

  const ConnectCommand({
    required this.connectionId,
    required this.deviceId,
    required this.host,
    required this.port,
    required this.trustPolicy,
  });
}

class DisconnectCommand extends NetworkCommand {
  final String connectionId;

  const DisconnectCommand(this.connectionId);
}

class CloseConnectionCommand extends NetworkCommand {
  final String connectionId;

  const CloseConnectionCommand(this.connectionId);
}

class GetConnectionStateCommand extends NetworkCommand {
  final String connectionId;

  const GetConnectionStateCommand(this.connectionId);
}

class HeartbeatCommand extends NetworkCommand {
  final String connectionId;

  const HeartbeatCommand(this.connectionId);
}

class GetDeviceConnectionsCommand extends NetworkCommand {
  final String deviceId;
  final SendPort? responsePort;
  final String requestId;

  const GetDeviceConnectionsCommand(this.deviceId, [this.responsePort, this.requestId = '']);
}

class ReconnectCommand extends NetworkCommand {
  final String deviceId;
  final String host;
  final int port;

  const ReconnectCommand({
    required this.deviceId,
    required this.host,
    required this.port,
  });
}

class NetworkShutdownCommand extends NetworkCommand {
  const NetworkShutdownCommand();
}

class UpdateConfigCommand extends NetworkCommand {
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

class FrameReceivedEvent extends NetworkEvent {
  final String connectionId;
  final String type;
  final Map<String, dynamic> header;
  final Uint8List payload;

  const FrameReceivedEvent({
    required this.connectionId,
    required this.type,
    required this.header,
    required this.payload,
  });
}

class ConnectionStatsEvent extends NetworkEvent {
  final String connectionId;
  final int bytesSent;
  final int bytesReceived;
  final int framesSent;
  final int framesReceived;
  final int decryptionErrors;
  final Duration uptime;

  const ConnectionStatsEvent({
    required this.connectionId,
    required this.bytesSent,
    required this.bytesReceived,
    required this.framesSent,
    required this.framesReceived,
    required this.decryptionErrors,
    required this.uptime,
  });
}

class DeviceConnectionsEvent extends NetworkEvent {
  final String deviceId;
  final List<String> connectionIds;
  final String requestId;

  const DeviceConnectionsEvent(this.deviceId, this.connectionIds, [this.requestId = '']);
}

class NetworkErrorEvent extends NetworkEvent {
  final String connectionId;
  final String error;

  const NetworkErrorEvent(this.connectionId, this.error);
}