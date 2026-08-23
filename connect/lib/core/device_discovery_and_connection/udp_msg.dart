import 'package:connect/network/connection_utils/device_communication_msg_utils.dart';
import 'package:connect/network/connection_utils/device_connection_data_utils.dart';

class SenderMsg {
  final String msgType;
  final SenderInfo senderInfo;
  SenderMsg({required this.msgType, required this.senderInfo});

  String toSeparatedString() {
    return '$msgType${ConnectionMsgSeparatorType.mainSeparator}${senderInfo.toSeparatedString(ConnectionMsgSeparatorType.secondarySeparator)}';
  }

  static SenderMsg fromSeparatedString(String separatedString) {
    final parts = separatedString.split(
      ConnectionMsgSeparatorType.mainSeparator,
    );
    final msgType = parts[0];
    final senderParts = parts[1].split(
      ConnectionMsgSeparatorType.secondarySeparator,
    );

    final senderInfo = SenderInfo(
      ip: senderParts[0],
      name: senderParts[1],
      platform: senderParts[2],
    );
    return SenderMsg(msgType: msgType, senderInfo: senderInfo);
  }
}

class SenderInfo {
  final String ip;
  final String name;
  final String platform;

  SenderInfo({required this.ip, required this.name, required this.platform});

  String toSeparatedString(String separator) {
    return '$ip$separator$name$separator$platform';
  }

  DeviceConnectionInfo toDeviceConnectionInfo() {
    return DeviceConnectionInfo(
      ip: ip,
      name: name,
      platform: platform,
      lastSeen: DateTime.now(),
    );
  }
}
