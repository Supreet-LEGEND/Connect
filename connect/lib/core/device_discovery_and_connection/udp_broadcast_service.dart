import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:connect/core/connection_utils/device_communication_msg_utils.dart';
import 'package:connect/core/connection_utils/device_connection_data_utils.dart';
import 'package:connect/core/device_discovery_and_connection/udp_msg.dart';

class UdpDiscoveryService {
  final String myIp;
  final String myName;
  final int broadcastPort;
  final int cleanupIntervalSec;
  final int deviceTimeoutSec;
  void Function(String senderIp)? onConnectionRequest;
  void Function(String senderIp)? onConnectionAccepted;
  void Function(String senderIp)? onConnectionDenied;
  void Function(String senderIp)? onDisconnect;
  void Function(Map<String, DeviceConnectionInfo> ipDeviceMap)?
  onDevicesUpdated;

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;

  final List<DeviceConnectionInfo> devices = [];
  final Map<String, DeviceConnectionInfo> ipDeviceMap = {}; // key: device IP
  final Map<String, DeviceConnectionInfo> connectedDevices =
      {}; // key: device IP

  UdpDiscoveryService({
    required this.broadcastPort,
    required this.myIp,
    required this.myName,
    this.cleanupIntervalSec = 5,
    this.deviceTimeoutSec = 10,
    this.onConnectionRequest,
    this.onConnectionAccepted,
    this.onConnectionDenied,
  });

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      broadcastPort,
    );

    _socket!.broadcastEnabled = true;

    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        _receivePacket();
      }
    });

    // Send discovery broadcast repeatedly
    _broadcastTimer = Timer.periodic(Duration(seconds: 3), (_) {
      _sendBroadcast();
    });

    // Clean dead/inactive devices
    _cleanupTimer = Timer.periodic(Duration(seconds: cleanupIntervalSec), (_) {
      _cleanupDevices();
    });
  }

  // ---------------------- SEND BROADCAST --------------------------
  void _sendBroadcast() {
    final SenderMsg msg = SenderMsg(
      msgType: ConnectionMsgType.discoverDevice,
      senderInfo: SenderInfo(
        ip: myIp,
        name: myName,
        platform: Platform.operatingSystem,
      ),
    );

    _socket!.send(
      utf8.encode(msg.toSeparatedString()),
      InternetAddress("255.255.255.255"),
      broadcastPort,
    );
  }

  // ---------------------- RECEIVE PACKETS --------------------------
  void _receivePacket() {
    final datagram = _socket!.receive();
    if (datagram == null) return;
    final senderBroadcastIp = datagram.address.address;
    if (senderBroadcastIp == myIp) return; // ignore own packets

    final msg = utf8.decode(datagram.data);
    final SenderMsg senderMsg = SenderMsg.fromSeparatedString(msg);
    final String senderIp = senderMsg.senderInfo.ip;

    if (senderMsg.msgType == ConnectionMsgType.discoverDevice) {
      // check if device already exists
      if (!ipDeviceMap.containsKey(senderIp)) {
        // add new device
        ipDeviceMap[senderIp] = senderMsg.senderInfo.toDeviceConnectionInfo();
      } else {
        // update existing device's last seen time
        ipDeviceMap[senderIp]!.lastSeen = DateTime.now();
      }
      onDevicesUpdated?.call(
        Map<String, DeviceConnectionInfo>.from(ipDeviceMap),
      );
    } else if (senderMsg.msgType == ConnectionMsgType.requestConnection) {
      onConnectionRequest?.call(senderIp);
    } else if (senderMsg.msgType == ConnectionMsgType.connectionAccepted) {
      onConnectionAccepted?.call(senderIp);
    } else if (senderMsg.msgType == ConnectionMsgType.connectionDenied) {
      onConnectionDenied?.call(senderIp);
    } else if (senderMsg.msgType == ConnectionMsgType.disconnect) {
      // Handle disconnect message
      if (ipDeviceMap.containsKey(senderIp)) {
        onDisconnect?.call(senderIp);
      }
    }
  }

  // ---------------------- CONNECTION HANDLERS --------------------------

  // ---------------------- CLEANUP --------------------------
  void _cleanupDevices() {
    final now = DateTime.now();
    // devices.removeWhere(
    //   (device) => now.difference(device.lastSeen).inSeconds > deviceTimeoutSec,
    // );
    ipDeviceMap.removeWhere(
      (ip, device) =>
          now.difference(device.lastSeen).inSeconds > deviceTimeoutSec,
    );
    devices
      ..clear()
      ..addAll(ipDeviceMap.values);
    onDevicesUpdated?.call(Map<String, DeviceConnectionInfo>.from(ipDeviceMap));
  }

  void stopBroadcast() {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
  }

  void closeSockets() {
    _socket?.close();
  }

  void dispose() {
    stopBroadcast();
    closeSockets();
  }
}
