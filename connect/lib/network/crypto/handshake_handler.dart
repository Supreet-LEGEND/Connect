import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:connect/network/crypto/device_identity.dart';
import 'package:connect/network/crypto/session_key_derivation.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class HandshakeMessage {
  final String type;
  final Map<String, dynamic> payload;

  HandshakeMessage({required this.type, required this.payload});

  String toJson() => jsonEncode({'type': type, 'payload': payload});

  static HandshakeMessage fromJson(String json) {
    final data = jsonDecode(json);
    return HandshakeMessage(
      type: data['type'] as String,
      payload: data['payload'] as Map<String, dynamic>,
    );
  }
}

class HandshakeResult {
  final SecretKey sessionKey;
  final SimplePublicKey peerIdentityPublicKey;
  final SimplePublicKey peerEphemeralPublicKey;
  final List<int> transcriptHash;

  HandshakeResult({
    required this.sessionKey,
    required this.peerIdentityPublicKey,
    required this.peerEphemeralPublicKey,
    required this.transcriptHash,
  });
}

class HandshakeHandler {
  final DeviceIdentity myIdentity;
  final TrustStore trustStore;
  final TrustPolicy trustPolicy;
  final SessionKeyDerivation _keyDerivation = SessionKeyDerivation();
  final X25519 _x25519 = X25519();
  final Random _random = Random.secure();

  HandshakeHandler({
    required this.myIdentity,
    required this.trustStore,
    this.trustPolicy = TrustPolicy.tofu,
  });

  static const int _maxHandshakeMessageSize = 16 * 1024; // 16KB
  static const Duration _handshakeMessageTimeout = Duration(seconds: 10);
  static const Duration _totalHandshakeTimeout = Duration(seconds: 30);

  Future<HandshakeResult> performHandshakeAsInitiator(Socket socket) async {
    final myEphemeralKeyPair = (await _x25519.newKeyPair()) as SimpleKeyPairData;
    final myIdentityPubBytes = myIdentity.identityPublicKey.bytes;
    final myEphemeralPubBytes = myEphemeralKeyPair.publicKey.bytes;

    final clientNonce = List<int>.generate(32, (_) => _random.nextInt(256));

    final initMessage = HandshakeMessage(
      type: 'handshake_init',
      payload: {
        'identityPubKey': base64Encode(myIdentityPubBytes),
        'ephemeralPubKey': base64Encode(myEphemeralPubBytes),
        'clientNonce': base64Encode(clientNonce),
        'protocolVersion': 1,
        'role': 'initiator',
      },
    );

    _sendJson(socket, initMessage.toJson());

    final responseJson = await _readJsonWithTimeout(socket);
    final response = HandshakeMessage.fromJson(responseJson);

    if (response.type != 'handshake_response') {
      throw StateError('Expected handshake_response, got ${response.type}');
    }

    final peerIdentityPubBytes = base64Decode(response.payload['identityPubKey'] as String);
    final peerEphemeralPubBytes = base64Decode(response.payload['ephemeralPubKey'] as String);
    final serverNonce = base64Decode(response.payload['serverNonce'] as String);
    final peerSignature = base64Decode(response.payload['signature'] as String);

    final peerIdentityPublicKey = SimplePublicKey(peerIdentityPubBytes, type: KeyPairType.ed25519);
    final peerEphemeralPublicKey = SimplePublicKey(peerEphemeralPubBytes, type: KeyPairType.x25519);

    // Build transcript for verification: version || role || clientNonce || serverNonce || both identity keys || both ephemeral keys
    final transcript = <int>[
      ..._intToBytes(1), // protocolVersion
      ..._stringToBytes('initiator'), // role
      ...clientNonce,
      ...serverNonce,
      ...myIdentityPubBytes,
      ...peerIdentityPubBytes,
      ...myEphemeralPubBytes,
      ...peerEphemeralPubBytes,
    ];
    final transcriptHash = sha256.convert(transcript).bytes;

    // Verify peer's signature over the transcript
    final isValid = await myIdentity.verify(peerIdentityPublicKey, transcriptHash, peerSignature);
    if (!isValid) {
      throw StateError('Peer signature verification failed');
    }

    // Verify peer against trust policy
    final peerFingerprint = _computeFingerprint(peerIdentityPublicKey);
    final (trusted, reason) = await trustStore.decideTrust(peerFingerprint, trustPolicy);
    if (!trusted) {
      throw StateError('Peer trust verification failed: $reason');
    }

    final sessionKey = await _keyDerivation.deriveSessionKey(
      myEphemeralKeyPair: myEphemeralKeyPair,
      peerEphemeralPublicKey: peerEphemeralPublicKey,
      salt: serverNonce, // Use server nonce as salt
      info: transcriptHash,
    );

    // Now send our signature over the transcript
    final mySignature = await myIdentity.sign(transcriptHash);
    final ackMessage = HandshakeMessage(
      type: 'handshake_ack',
      payload: {
        'signature': base64Encode(mySignature),
      },
    );
    _sendJson(socket, ackMessage.toJson());

    return HandshakeResult(
      sessionKey: sessionKey,
      peerIdentityPublicKey: peerIdentityPublicKey,
      peerEphemeralPublicKey: peerEphemeralPublicKey,
      transcriptHash: transcriptHash,
    );
  }

  Future<HandshakeResult> performHandshakeAsResponder(Socket socket) async {
    final initJson = await _readJsonWithTimeout(socket);
    final initMessage = HandshakeMessage.fromJson(initJson);

    if (initMessage.type != 'handshake_init') {
      throw StateError('Expected handshake_init, got ${initMessage.type}');
    }

    final peerIdentityPubBytes = base64Decode(initMessage.payload['identityPubKey'] as String);
    final peerEphemeralPubBytes = base64Decode(initMessage.payload['ephemeralPubKey'] as String);
    final clientNonce = base64Decode(initMessage.payload['clientNonce'] as String);
    final protocolVersion = initMessage.payload['protocolVersion'] as int? ?? 1;

    if (protocolVersion != 1) {
      throw StateError('Unsupported protocol version: $protocolVersion');
    }

    final peerIdentityPublicKey = SimplePublicKey(peerIdentityPubBytes, type: KeyPairType.ed25519);
    final peerEphemeralPublicKey = SimplePublicKey(peerEphemeralPubBytes, type: KeyPairType.x25519);

    final myEphemeralKeyPair = (await _x25519.newKeyPair()) as SimpleKeyPairData;
    final myIdentityPubBytes = myIdentity.identityPublicKey.bytes;
    final myEphemeralPubBytes = myEphemeralKeyPair.publicKey.bytes;

    final serverNonce = List<int>.generate(32, (_) => _random.nextInt(256));

    final transcript = <int>[
      ..._intToBytes(1), // protocolVersion
      ..._stringToBytes('responder'), // role
      ...clientNonce,
      ...serverNonce,
      ...peerIdentityPubBytes,
      ...myIdentityPubBytes,
      ...peerEphemeralPubBytes,
      ...myEphemeralPubBytes,
    ];
    final transcriptHash = sha256.convert(transcript).bytes;

    // Sign the transcript
    final mySignature = await myIdentity.sign(transcriptHash);

    final responseMessage = HandshakeMessage(
      type: 'handshake_response',
      payload: {
        'identityPubKey': base64Encode(myIdentityPubBytes),
        'ephemeralPubKey': base64Encode(myEphemeralPubBytes),
        'serverNonce': base64Encode(serverNonce),
        'protocolVersion': 1,
        'role': 'responder',
        'signature': base64Encode(mySignature),
      },
    );

    _sendJson(socket, responseMessage.toJson());

    // Wait for initiator's ack with their signature
    final ackJson = await _readJsonWithTimeout(socket);
    final ackMessage = HandshakeMessage.fromJson(ackJson);

    if (ackMessage.type != 'handshake_ack') {
      throw StateError('Expected handshake_ack, got ${ackMessage.type}');
    }

    final peerSignature = base64Decode(ackMessage.payload['signature'] as String);

    // Verify initiator's signature over the same transcript
    final isValid = await myIdentity.verify(peerIdentityPublicKey, transcriptHash, peerSignature);
    if (!isValid) {
      throw StateError('Initiator signature verification failed');
    }

    // Verify peer against trust policy
    final peerFingerprint = _computeFingerprint(peerIdentityPublicKey);
    final (trusted, reason) = await trustStore.decideTrust(peerFingerprint, trustPolicy);
    if (!trusted) {
      throw StateError('Peer trust verification failed: $reason');
    }

    final sessionKey = await _keyDerivation.deriveSessionKey(
      myEphemeralKeyPair: myEphemeralKeyPair,
      peerEphemeralPublicKey: peerEphemeralPublicKey,
      salt: clientNonce, // Use client nonce as salt
      info: transcriptHash,
    );

    return HandshakeResult(
      sessionKey: sessionKey,
      peerIdentityPublicKey: peerIdentityPublicKey,
      peerEphemeralPublicKey: peerEphemeralPublicKey,
      transcriptHash: transcriptHash,
    );
  }

  void _sendJson(Socket socket, String json) {
    final data = utf8.encode(json);
    final length = ByteData(4);
    length.setUint32(0, data.length, Endian.big);
    socket.add(length.buffer.asUint8List());
    socket.add(data);
  }

  Future<String> _readJsonWithTimeout(Socket socket) async {
    final lengthBytes = await _readExactWithTimeout(socket, 4);
    final length = ByteData.sublistView(Uint8List.fromList(lengthBytes)).getUint32(0, Endian.big);
    if (length > _maxHandshakeMessageSize) {
      throw StateError('Handshake message too large');
    }
    final data = await _readExactWithTimeout(socket, length);
    return utf8.decode(data);
  }

  Future<List<int>> _readExactWithTimeout(Socket socket, int length) async {
    final buffer = <int>[];
    final completer = Completer<List<int>>();
    
    StreamSubscription<List<int>>? subscription;
    
    subscription = socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        if (buffer.length >= length) {
          subscription?.cancel();
          completer.complete(buffer.sublist(0, length));
        }
      },
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.completeError(StateError('Socket closed'));
      },
      cancelOnError: true,
    );

    // Add timeout
    final timeout = Timer(_handshakeMessageTimeout, () {
      if (!completer.isCompleted) {
        subscription?.cancel();
        completer.completeError(TimeoutException('Handshake read timeout'));
      }
    });

    try {
      return await completer.future;
    } finally {
      timeout.cancel();
    }
  }

  List<int> _intToBytes(int value) {
    return [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
  }

  List<int> _stringToBytes(String value) {
    return utf8.encode(value);
  }

  String _computeFingerprint(SimplePublicKey key) {
    final digest = sha256.convert(key.bytes);
    return base64Encode(digest.bytes);
  }
}