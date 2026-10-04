import 'dart:convert';
import 'dart:io';
import 'package:connect/network/connection_utils/device_communication_msg_utils.dart';
import 'package:connect/core/device_discovery_and_connection/udp_msg.dart';

class UdpConnectionSignaler {
  // vars
  final int port;
  final String deviceIp;
  final String deviceName;

  UdpConnectionSignaler({
    required this.port,
    required this.deviceIp,
    required this.deviceName,
  });

  // SEND CONNECTION REQUEST TO TARGET DEVICE IP
  Future<void> sendConnectionRequest(String targetIp) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    SenderMsg msg = SenderMsg(
      msgType: ConnectionMsgType.requestConnection,
      senderInfo: SenderInfo(
        ip: deviceIp,
        name: deviceName,
        platform: Platform.operatingSystem,
      ),
    );

    socket.send(
      utf8.encode(msg.toSeparatedString()),
      InternetAddress(targetIp),
      port,
    );

    socket.close();
  }

  // SEND CONNECTION ACCEPTED MSG TO TARGET DEVICE IP
  Future<void> sendConnectionAccepted(String targetIp) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    final SenderMsg msg = SenderMsg(
      msgType: ConnectionMsgType.connectionAccepted,
      senderInfo: SenderInfo(
        ip: deviceIp,
        name: deviceName,
        platform: Platform.operatingSystem,
      ),
    );

    socket.send(
      utf8.encode(msg.toSeparatedString()),
      InternetAddress(targetIp),
      port,
    );

    socket.close();
  }

  // SEND CONNECTION DENIED MSG TO TARGET DEVICE IP
  Future<void> sendConnectionDenied(String targetIp) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    final SenderMsg msg = SenderMsg(
      msgType: ConnectionMsgType.connectionDenied,
      senderInfo: SenderInfo(
        ip: deviceIp,
        name: deviceName,
        platform: Platform.operatingSystem,
      ),
    );

    socket.send(
      utf8.encode(msg.toSeparatedString()),
      InternetAddress(targetIp),
      port,
    );

    socket.close();
  }

  Future<void> sendDisconnect(String targetIp) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    final SenderMsg msg = SenderMsg(
      msgType: ConnectionMsgType.disconnect,
      senderInfo: SenderInfo(
        ip: deviceIp,
        name: deviceName,
        platform: Platform.operatingSystem,
      ),
    );

    socket.send(
      utf8.encode(msg.toSeparatedString()),
      InternetAddress(targetIp),
      port,
    );

    socket.close();
  }
}
