import 'dart:math';

import 'package:cryptography/cryptography.dart';

class EncryptedPayload {
  final List<int> cipherText;
  final List<int> nonce;
  final List<int> mac;

  EncryptedPayload({
    required this.cipherText,
    required this.nonce,
    required this.mac,
  });
}

class CryptoService {
  final AesGcm algorithm;

  final SecretKey key;

  CryptoService({
    required this.key,
  }) : algorithm = AesGcm.with256bits();

  Future<EncryptedPayload> encrypt(
    List<int> plaintext,
  ) async {
    final nonce = _randomNonce();

    final box = await algorithm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );

    return EncryptedPayload(
      cipherText: box.cipherText,
      nonce: box.nonce,
      mac: box.mac.bytes,
    );
  }

  Future<List<int>> decrypt({
    required List<int> cipherText,
    required List<int> nonce,
    required List<int> mac,
  }) async {
    final box = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(mac),
    );

    return algorithm.decrypt(
      box,
      secretKey: key,
    );
  }

  List<int> _randomNonce() {
    final random = Random.secure();

    return List<int>.generate(
      12,
      (_) => random.nextInt(256),
    );
  }
}