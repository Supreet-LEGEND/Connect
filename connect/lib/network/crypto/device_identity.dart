import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class DeviceIdentity {
  SimpleKeyPairData? _identityKeyPair;
  String? _cachedIdentityKeyJson;
  final Completer<void> _initCompleter = Completer<void>();

  SimplePublicKey get identityPublicKey {
    final keyPair = _identityKeyPair;
    if (keyPair == null) {
      throw StateError('Identity key not initialized. Call initialize() first.');
    }
    return keyPair.publicKey;
  }

  SimpleKeyPairData get identityKeyPair {
    if (_identityKeyPair == null) {
      throw StateError('Identity key not initialized. Call initialize() first.');
    }
    return _identityKeyPair!;
  }

  String get fingerprint {
    final keyPair = _identityKeyPair;
    if (keyPair == null) {
      throw StateError('Identity key not initialized. Call initialize() first.');
    }
    final digest = sha256.convert(keyPair.publicKey.bytes);
    return base64Encode(digest.bytes);
  }

  Future<void> initialize() async {
    if (_initCompleter.isCompleted) {
      return _initCompleter.future;
    }

    try {
      if (await _loadKeyPair()) {
        _initCompleter.complete();
        return;
      }

      final ed25519 = Ed25519();
      final seed = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      _identityKeyPair = (await ed25519.newKeyPairFromSeed(seed)) as SimpleKeyPairData;

      _cachedIdentityKeyJson = jsonEncode({
        'seed': base64Encode(seed),
        'publicKey': base64Encode(_identityKeyPair!.publicKey.bytes),
      });
      await _persistKeyPair();
      _initCompleter.complete();
    } catch (e) {
      _initCompleter.completeError(e);
      rethrow;
    }
  }

  Future<List<int>> sign(List<int> data) async {
    if (_identityKeyPair == null) {
      throw StateError('Identity key not initialized');
    }
    final ed25519 = Ed25519();
    final signature = await ed25519.sign(data, keyPair: _identityKeyPair!);
    return signature.bytes;
  }

  Future<bool> verify(SimplePublicKey peerPublicKey, List<int> data, List<int> signature) async {
    try {
      final ed25519 = Ed25519();
      final sig = Signature(signature, publicKey: peerPublicKey);
      await ed25519.verify(data, signature: sig);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<String> getIdentityKeyJson() async {
    if (_cachedIdentityKeyJson == null) {
      if (_identityKeyPair == null) {
        throw StateError('Identity key not initialized');
      }
      final seedBytes = await _identityKeyPair!.extractPrivateKeyBytes();
      _cachedIdentityKeyJson = jsonEncode({
        'seed': base64Encode(seedBytes),
        'publicKey': base64Encode(_identityKeyPair!.publicKey.bytes),
      });
    }
    return _cachedIdentityKeyJson!;
  }

  Future<void> _persistKeyPair() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/device_identity.json');
    // Atomic write: write to temp file then rename
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(await getIdentityKeyJson());
    await tempFile.rename(file.path);
  }

  Future<bool> _loadKeyPair() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/device_identity.json');
      if (!await file.exists()) {
        return false;
      }
      final jsonStr = await file.readAsString();
      final Map<String, dynamic> data = jsonDecode(jsonStr);

      final seedBytes = base64Decode(data['seed'] as String);
      final storedPublicKeyBytes = base64Decode(data['publicKey'] as String);

      if (seedBytes.length != 32) {
        return false;
      }

      final ed25519 = Ed25519();
      _identityKeyPair = (await ed25519.newKeyPairFromSeed(seedBytes)) as SimpleKeyPairData;

      // Validate the public key matches what we stored
      if (!const ListEquality().equals(_identityKeyPair!.publicKey.bytes, storedPublicKeyBytes)) {
        // Stored data is corrupted/inconsistent - don't silently swap identity
        return false;
      }

      _cachedIdentityKeyJson = jsonStr;
      return true;
    } catch (e) {
      return false;
    }
  }
}