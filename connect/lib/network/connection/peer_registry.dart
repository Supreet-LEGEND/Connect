import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:connect/network/crypto/device_identity.dart';
import 'package:connect/network/crypto/trust_store.dart';

class PeerInfo {
  final String fingerprint;
  final String alias;
  String? lastKnownIp;
  int? lastKnownPort;
  DateTime lastSeen;
  final TrustEntry trustEntry;

  PeerInfo({
    required this.fingerprint,
    required this.alias,
    this.lastKnownIp,
    this.lastKnownPort,
    required this.lastSeen,
    required this.trustEntry,
  });

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'alias': alias,
    'lastKnownIp': lastKnownIp,
    'lastKnownPort': lastKnownPort,
    'lastSeen': lastSeen.toIso8601String(),
    'trustEntry': trustEntry.toJson(),
  };

  factory PeerInfo.fromJson(Map<String, dynamic> json) => PeerInfo(
    fingerprint: json['fingerprint'] as String,
    alias: json['alias'] as String,
    lastKnownIp: json['lastKnownIp'] as String?,
    lastKnownPort: json['lastKnownPort'] as int?,
    lastSeen: DateTime.parse(json['lastSeen'] as String),
    trustEntry: TrustEntry.fromJson(json['trustEntry'] as Map<String, dynamic>),
  );

  PeerInfo copyWith({
    String? alias,
    String? lastKnownIp,
    int? lastKnownPort,
    DateTime? lastSeen,
    TrustEntry? trustEntry,
  }) => PeerInfo(
    fingerprint: fingerprint,
    alias: alias ?? this.alias,
    lastKnownIp: lastKnownIp ?? this.lastKnownIp,
    lastKnownPort: lastKnownPort ?? this.lastKnownPort,
    lastSeen: lastSeen ?? this.lastSeen,
    trustEntry: trustEntry ?? this.trustEntry,
  );
}

class PeerRegistry {
  final Map<String, PeerInfo> _peers = {};
  final StreamController<Map<String, PeerInfo>> _onPeersChanged = StreamController<Map<String, PeerInfo>>.broadcast();

  Stream<Map<String, PeerInfo>> get onPeersChanged => _onPeersChanged.stream;
  Map<String, PeerInfo> get peers => Map.unmodifiable(_peers);

  PeerRegistry();

  Future<void> load() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/peers.json');
      if (await file.exists()) {
        final jsonStr = await file.readAsString();
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        _peers.clear();
        for (final entry in data.entries) {
          _peers[entry.key] = PeerInfo.fromJson(entry.value as Map<String, dynamic>);
        }
      }
    } catch (e) {
      // Ignore load errors, start fresh
    }
  }

  Future<void> _persist() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/peers.json');
    final data = <String, dynamic>{};
    for (final entry in _peers.entries) {
      data[entry.key] = entry.value.toJson();
    }
    await file.writeAsString(jsonEncode(data));
  }

  PeerInfo? getPeer(String fingerprint) => _peers[fingerprint];

  List<PeerInfo> get allPeers => _peers.values.toList();

  List<PeerInfo> get trustedPeers => _peers.values.where((p) => p.trustEntry.policy != TrustPolicy.any).toList();

  Future<void> addOrUpdatePeer(PeerInfo peer) async {
    _peers[peer.fingerprint] = peer;
    await _persist();
    _onPeersChanged.add(Map.unmodifiable(_peers));
  }

  Future<void> updatePeerEndpoint(String fingerprint, String ip, int port) async {
    final peer = _peers[fingerprint];
    if (peer != null) {
      final updated = peer.copyWith(
        lastKnownIp: ip,
        lastKnownPort: port,
        lastSeen: DateTime.now(),
      );
      _peers[fingerprint] = updated;
      await _persist();
      _onPeersChanged.add(Map.unmodifiable(_peers));
    }
  }

  Future<void> removePeer(String fingerprint) async {
    _peers.remove(fingerprint);
    await _persist();
    _onPeersChanged.add(Map.unmodifiable(_peers));
  }

  Future<void> updateTrustEntry(String fingerprint, TrustEntry trustEntry) async {
    final peer = _peers[fingerprint];
    if (peer != null) {
      final updated = peer.copyWith(trustEntry: trustEntry);
      _peers[fingerprint] = updated;
      await _persist();
      _onPeersChanged.add(Map.unmodifiable(_peers));
    }
  }

  Future<void> trustPeer(String fingerprint, String alias, TrustEntry trustEntry) async {
    final peer = _peers[fingerprint] ?? PeerInfo(
      fingerprint: fingerprint,
      alias: alias,
      lastSeen: DateTime.now(),
      trustEntry: trustEntry,
    );
    final updated = peer.copyWith(
      alias: alias,
      lastSeen: DateTime.now(),
      trustEntry: trustEntry,
    );
    _peers[fingerprint] = updated;
    await _persist();
    _onPeersChanged.add(Map.unmodifiable(_peers));
  }

  bool hasPeer(String deviceId) => _peers.containsKey(deviceId);

  void dispose() {
    _onPeersChanged.close();
  }
}