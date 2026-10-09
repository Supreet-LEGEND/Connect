import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connect/network/connection_utils/device_communication_msg_utils.dart';
import 'package:connect/network/connection_utils/device_connection_data_utils.dart';
import 'package:connect/core/device_discovery_and_connection/udp_msg.dart';
import 'package:connect/core/hardware_connection_status/hardware_connection_status_manager.dart';

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
  Timer? _networkCheckTimer;
  String? _lastKnownIp;

  final List<DeviceConnectionInfo> devices = [];
  final Map<String, DeviceConnectionInfo> ipDeviceMap = {}; // key: device IP
  final Map<String, DeviceConnectionInfo> connectedDevices =
      {}; // key: device IP

  // Reusable socket for sending connection signals
  RawDatagramSocket? _signalSocket;

  UdpDiscoveryService({
    required this.broadcastPort,
    required this.myIp,
    required this.myName,
    this.cleanupIntervalSec = 5,
    this.deviceTimeoutSec = 10,
    this.onConnectionRequest,
    this.onConnectionAccepted,
    this.onConnectionDenied,
  }) {
    _lastKnownIp = myIp;
  }

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        broadcastPort,
      );

      _socket!.broadcastEnabled = true;

      _socket!.listen((event) {
        if (event == RawSocketEvent.read) {
          _receivePacket();
        }
      }, onError: (error) {
        debugPrint('UDP socket error: $error');
      });

      // Initialize signal socket
      await _initSignalSocket();

      // Send discovery broadcast repeatedly
      _broadcastTimer = Timer.periodic(Duration(seconds: 3), (_) {
        _sendBroadcast();
      });

      // Clean dead/inactive devices
      _cleanupTimer = Timer.periodic(Duration(seconds: cleanupIntervalSec), (_) {
        _cleanupDevices();
      });

      // Check for network changes (IP address changes)
      _networkCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        _checkNetworkChange();
      });
    } on SocketException catch (e) {
      debugPrint('Failed to bind UDP socket on port $broadcastPort: $e');
      // Try fallback port
      if (broadcastPort != 50001) {
        debugPrint('Trying fallback port 50001...');
        // Note: This would require recreating the service with new port
        // For now, just log the error
      }
      rethrow;
    }
  }

  Future<void> _initSignalSocket() async {
    _signalSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
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
    ipDeviceMap.removeWhere(
      (ip, device) =>
          now.difference(device.lastSeen).inSeconds > deviceTimeoutSec,
    );
    devices
      ..clear()
      ..addAll(ipDeviceMap.values);
    onDevicesUpdated?.call(Map<String, DeviceConnectionInfo>.from(ipDeviceMap));
  }

  Future<void> _checkNetworkChange() async {
    final currentIp = await WifiConnectionManager.getLocalIp();
    if (currentIp != null && currentIp != _lastKnownIp) {
      _lastKnownIp = currentIp;
      // Rebind sockets with new IP
      await _rebindSockets(currentIp);
    }
  }

  Future<void> _rebindSockets(String newIp) async {
    // Close and rebind broadcast socket
    _broadcastTimer?.cancel();
    _socket?.close();
    _signalSocket?.close();
    
    // Wait for OS to release ports
    await Future.delayed(const Duration(milliseconds: 100));
    
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      broadcastPort,
      reuseAddress: true,
    );
    _socket!.broadcastEnabled = true;
    _socket!.listen((event) {
      if (event == RawSocketEvent.read) {
        _receivePacket();
      }
    });
    
    _broadcastTimer = Timer.periodic(Duration(seconds: 3), (_) {
      _sendBroadcast();
    });

    // Rebind signal socket
    await _initSignalSocket();
  }

  void stopBroadcast() {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _networkCheckTimer?.cancel();
  }

  void closeSockets() {
    _socket?.close();
    _signalSocket?.close();
  }

  void dispose() {
    stopBroadcast();
    closeSockets();
  }

  // Getter for signal socket (lazy initialization)
  Future<RawDatagramSocket> get signalSocket async {
    if (_signalSocket == null) {
      await _initSignalSocket();
    }
    return _signalSocket!;
  }
}
