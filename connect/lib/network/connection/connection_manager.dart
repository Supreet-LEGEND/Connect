import 'dart:convert';
import 'package:connect/network/connection/device_session.dart';
import 'package:connect/network/connection/peer_registry.dart';
import 'package:connect/network/crypto/device_identity.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class ConnectionManager {
  final Map<String, DeviceSession>
      _devices = {};

  final TrustStore trustStore;
  final TrustPolicy trustPolicy;
  final PeerRegistry peerRegistry;

  Map<String, DeviceSession>
      get devices =>
          Map.unmodifiable(_devices);

  ConnectionManager({
    required this.trustStore,
    this.trustPolicy = TrustPolicy.tofu,
    required this.peerRegistry,
  });

  Future<DeviceSession> addDevice({
    required String deviceId,
    required String name,
    required String ip,
    required int port,
    required DeviceIdentity identity,
    int sockets = 4,
    Future<bool> Function(String fingerprint)? onVerifyFingerprint,
  }) async {
    final existing =
        _devices[deviceId];

    if (existing != null) {
      return existing;
    }

    final device = DeviceSession(
      deviceId: deviceId,
      name: name,
      ip: ip,
      port: port,
      identity: identity,
      trustStore: trustStore,
      trustPolicy: trustPolicy,
      sockets: sockets,
    );

    // Set callback for when reconnection is exhausted
    device.onReconnectionExhausted = () {
      remove(deviceId);
    };

    // Connect with verification if callback provided
    await device.connect(requireVerification: onVerifyFingerprint != null);

    _devices[deviceId] = device;

    // Listen for peer fingerprint and update key if different
    device.onPeerFingerprintKnown.listen((peerKey) {
      final fingerprint = _computeFingerprint(peerKey);
      if (fingerprint != deviceId) {
        _updateDeviceKey(deviceId, fingerprint, device);
      }
      // Update trust entry in peer registry after handshake
      _updatePeerTrustEntry(fingerprint);
      
      // If verification callback provided, call it
      if (onVerifyFingerprint != null) {
        onVerifyFingerprint(fingerprint).then((verified) {
          device.completeVerification(verified);
        });
      }
    });

    // Register/update peer in registry
    _registerPeer(device);

    return device;
  }

  Future<void> _registerPeer(DeviceSession device) async {
    final fingerprint = device.deviceId;
    final existing = peerRegistry.getPeer(fingerprint);
    
    if (existing != null) {
      // Update endpoint info
      await peerRegistry.updatePeerEndpoint(fingerprint, device.ip, device.port);
    } else {
      // New peer - create placeholder peer entry
      // The trust entry will be updated after handshake completes
      await peerRegistry.addOrUpdatePeer(PeerInfo(
        fingerprint: fingerprint,
        alias: device.name,
        lastKnownIp: device.ip,
        lastKnownPort: device.port,
        lastSeen: DateTime.now(),
        trustEntry: TrustEntry(
          fingerprint: fingerprint,
          alias: device.name,
          trustedAt: DateTime.now(),
          policy: trustPolicy,
        ),
      ));
    }
  }

  void _updatePeerTrustEntry(String fingerprint) {
    final trustEntry = trustStore.getEntry(fingerprint);
    if (trustEntry != null) {
      peerRegistry.updateTrustEntry(fingerprint, trustEntry);
    }
  }

  String _computeFingerprint(SimplePublicKey key) {
    final digest = sha256.convert(key.bytes);
    return base64Encode(digest.bytes);
  }

  void _updateDeviceKey(String oldKey, String newKey, DeviceSession device) {
    if (_devices[oldKey] == device) {
      _devices.remove(oldKey);
      device.updateDeviceId(newKey);
      _devices[newKey] = device;
    }
  }

  DeviceSession? get(
    String deviceId,
  ) {
    return _devices[deviceId];
  }

  Future<void> remove(
    String deviceId,
  ) async {
    final device =
        _devices.remove(deviceId);

    await device?.close();
  }

  Future<void> closeAll() async {
    for (final device
        in _devices.values) {
      await device.close();
    }

    _devices.clear();
  }
}