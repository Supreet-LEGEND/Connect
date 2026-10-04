import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

class SessionKeyDerivation {
  final X25519 _x25519 = X25519();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Derive initial session key from ephemeral key exchange
  Future<SecretKey> deriveSessionKey({
    required SimpleKeyPair myEphemeralKeyPair,
    required SimplePublicKey peerEphemeralPublicKey,
    required List<int> salt,
    required List<int> info,
  }) async {
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: myEphemeralKeyPair,
      remotePublicKey: peerEphemeralPublicKey,
    );

    final derivedKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: salt,
      info: info,
    );

    return derivedKey;
  }

  /// Derive resumption master secret from initial handshake
  /// Returns a secret that can be used to resume the session without full handshake
  Future<List<int>> deriveResumptionMasterSecret({
    required SecretKey sessionKey,
    required List<int> transcriptHash,
  }) async {
    // RFC 8446 style resumption master secret derivation
    const label = 'resumption master';
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    
    return hkdf.deriveKey(
      secretKey: sessionKey,
      nonce: utf8.encode(label),
      info: transcriptHash,
    ).then((key) => key.extractBytes());
  }

  /// Derive traffic keys from resumption master secret
  /// Used when resuming a session without full handshake
  Future<SecretKey> deriveTrafficKeysFromResumption({
    required List<int> resumptionMasterSecret,
    required List<int> clientNonce,
    required List<int> serverNonce,
  }) async {
    // Derive new traffic keys from resumption master secret + new nonces
    const label = 'resumption traffic';
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    
    final info = <int>[
      ...clientNonce,
      ...serverNonce,
    ];
    
    return hkdf.deriveKey(
      secretKey: SecretKey(resumptionMasterSecret),
      nonce: utf8.encode(label),
      info: info,
    );
  }

  /// Derive resumption ticket to send to peer
  /// Contains encrypted resumption master secret + nonces
  Future<List<int>> createResumptionTicket({
    required List<int> resumptionMasterSecret,
    required List<int> clientNonce,
    required List<int> serverNonce,
    required SecretKey ticketKey, // Long-term key for encrypting tickets
  }) async {
    final ticketData = {
      'resumption_master_secret': base64Encode(resumptionMasterSecret),
      'client_nonce': base64Encode(clientNonce),
      'server_nonce': base64Encode(serverNonce),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    };
    
    final ticketJson = jsonEncode(ticketData);
    final ticketBytes = utf8.encode(ticketJson);
    
    // Encrypt with ticket key (AES-GCM)
    final aesGcm = AesGcm.with256bits();
    final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final box = await aesGcm.encrypt(ticketBytes, secretKey: ticketKey, nonce: nonce);
    
    // Return nonce + ciphertext + tag
    return [
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];
  }

  /// Decrypt and validate resumption ticket
  Future<ResumptionTicketData?> decryptResumptionTicket({
    required List<int> ticketData,
    required SecretKey ticketKey,
  }) async {
    try {
      final aesGcm = AesGcm.with256bits();
      
      if (ticketData.length < 12 + 16) return null; // nonce(12) + tag(16) minimum
      
      final nonce = ticketData.sublist(0, 12);
      final cipherText = ticketData.sublist(12, ticketData.length - 16);
      final tag = ticketData.sublist(ticketData.length - 16);
      
      final box = SecretBox(cipherText, nonce: nonce, mac: Mac(tag));
      final plaintext = await aesGcm.decrypt(box, secretKey: ticketKey);
      
      final jsonStr = utf8.decode(plaintext);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      return ResumptionTicketData(
        resumptionMasterSecret: base64Decode(data['resumption_master_secret'] as String),
        clientNonce: base64Decode(data['client_nonce'] as String),
        serverNonce: base64Decode(data['server_nonce'] as String),
        createdAt: DateTime.fromMillisecondsSinceEpoch(data['created_at'] as int),
      );
    } catch (e) {
      return null;
    }
  }
}

class ResumptionTicketData {
  final List<int> resumptionMasterSecret;
  final List<int> clientNonce;
  final List<int> serverNonce;
  final DateTime createdAt;

  ResumptionTicketData({
    required this.resumptionMasterSecret,
    required this.clientNonce,
    required this.serverNonce,
    required this.createdAt,
  });

  bool isExpired({Duration maxAge = const Duration(days: 7)}) {
    return DateTime.now().difference(createdAt) > maxAge;
  }
}