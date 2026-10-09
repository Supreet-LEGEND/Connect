import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

enum TrustPolicy {
  any,      // Accept any peer (no verification)
  tofu,     // Trust On First Use - auto-pin on first sight, show fingerprint for verification
  pinned,   // Only accept pre-pinned peers
}

class TrustEntry {
  final String fingerprint;
  final String? alias;
  final DateTime trustedAt;
  final TrustPolicy policy;

  TrustEntry({
    required this.fingerprint,
    this.alias,
    required this.trustedAt,
    required this.policy,
  });

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'alias': alias,
    'trustedAt': trustedAt.toIso8601String(),
    'policy': policy.name,
  };

  factory TrustEntry.fromJson(Map<String, dynamic> json) => TrustEntry(
    fingerprint: json['fingerprint'] as String,
    alias: json['alias'] as String?,
    trustedAt: DateTime.parse(json['trustedAt'] as String),
    policy: TrustPolicy.values.firstWhere((e) => e.name == json['policy']),
  );
}

class TrustStore {
  final Map<String, TrustEntry> _trustedPeers = {};
  final StreamController<TrustEntry> _onPeerTrusted = StreamController<TrustEntry>.broadcast();

  Stream<TrustEntry> get onPeerTrusted => _onPeerTrusted.stream;

  TrustStore();

  /// Check if a peer is trusted
  bool isTrusted(String fingerprint, {TrustPolicy effectivePolicy = TrustPolicy.tofu}) {
    final entry = _trustedPeers[fingerprint];
    if (entry == null) {
      // Unknown peer - depends on effective policy
      return effectivePolicy == TrustPolicy.any;
    }
    return true; // Known peer is trusted
  }

  /// Get the trust entry for a peer
  TrustEntry? getEntry(String fingerprint) => _trustedPeers[fingerprint];

  /// Get all trusted peers
  List<TrustEntry> get allTrustedPeers => _trustedPeers.values.toList();

  /// Trust a peer (pin their fingerprint)
  Future<void> trustPeer(String fingerprint, {String? alias, TrustPolicy policy = TrustPolicy.pinned}) async {
    final entry = TrustEntry(
      fingerprint: fingerprint,
      alias: alias,
      trustedAt: DateTime.now(),
      policy: policy,
    );
    _trustedPeers[fingerprint] = entry;
    await _persist();
    _onPeerTrusted.add(entry);
  }

  /// Revoke trust for a peer
  Future<void> revokePeer(String fingerprint) async {
    _trustedPeers.remove(fingerprint);
    await _persist();
  }

  /// Verify peer against trust policy
  /// Returns (isAllowed, reason)
  (bool, String) verifyPeer(String fingerprint, TrustPolicy effectivePolicy) {
    final entry = _trustedPeers[fingerprint];
    
    switch (effectivePolicy) {
      case TrustPolicy.any:
        return (true, 'Accepting any peer (policy: any)');
      
      case TrustPolicy.tofu:
        if (entry == null) {
          // First time seeing this peer - allow but mark for review
          return (true, 'First time seeing peer (TOFU) - fingerprint: $fingerprint');
        }
        return (true, 'Previously trusted peer (TOFU)');
      
      case TrustPolicy.pinned:
        if (entry == null) {
          return (false, 'Peer not pinned (policy: pinned) - fingerprint: $fingerprint');
        }
        return (true, 'Pinned peer verified');
    }
  }

  /// Get or create a trust decision for a peer
  Future<(bool, String)> decideTrust(String fingerprint, TrustPolicy effectivePolicy) async {
    final (allowed, reason) = verifyPeer(fingerprint, effectivePolicy);
    
    if (allowed && effectivePolicy == TrustPolicy.tofu && !_trustedPeers.containsKey(fingerprint)) {
      // Auto-pin for TOFU
      await trustPeer(fingerprint, policy: TrustPolicy.tofu);
    }
    
    return (allowed, reason);
  }

  /// Load trust store from disk
  Future<void> load() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/trust_store.json');
      if (await file.exists()) {
        final jsonStr = await file.readAsString();
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        
        _trustedPeers.clear();
        for (final entry in data.entries) {
          _trustedPeers[entry.key] = TrustEntry.fromJson(entry.value as Map<String, dynamic>);
        }
      }
    } catch (e) {
      // Ignore load errors, start fresh
    }
  }

  Future<void> _persist() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/trust_store.json');
    // Atomic write
    final tempFile = File('${file.path}.tmp');
    final data = <String, dynamic>{};
    for (final entry in _trustedPeers.entries) {
      data[entry.key] = entry.value.toJson();
    }
    await tempFile.writeAsString(jsonEncode(data));
    await tempFile.rename(file.path);
  }

  void dispose() {
    _onPeerTrusted.close();
  }

  /// Convert TrustStore to JSON string
  String toJson() {
    final data = <String, dynamic>{};
    for (final entry in _trustedPeers.entries) {
      data[entry.key] = entry.value.toJson();
    }
    return jsonEncode(data);
  }

  /// Create TrustStore from JSON string
  factory TrustStore.fromJson(String json) {
    final store = TrustStore();
    final data = jsonDecode(json) as Map<String, dynamic>;
    for (final entry in data.entries) {
      store._trustedPeers[entry.key] = TrustEntry.fromJson(entry.value as Map<String, dynamic>);
    }
    return store;
  }
}