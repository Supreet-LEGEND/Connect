import 'dart:io';

import 'package:connect/network/transfer/receive_transfer.dart';

class ReceiveTransferManager {
  final Directory directory;

  final Map<String, ReceivingTransfer>
      _transfers = {};

  ReceiveTransferManager({
    required this.directory,
  });

  Future<void> handle({
    required String type,
    required Map<String, dynamic> header,
    required List<int> payload,
    required IncomingConnection connection,
  }) async {
    switch (type) {
      case 'file_start':
        await _handleFileStart(
          header,
        );
        break;

      case 'file_chunk':
        await _handleChunk(
          header,
          payload,
          connection,
        );
        break;

      case 'file_end':
        await _handleFileEnd(
          header,
        );
        break;

      case 'transfer_cancel':
        await _handleCancel(
          header,
        );
        break;

      case 'message':
        await _handleMessage(
          header,
          payload,
        );
        break;
    }
  }

  Future<void> _handleFileStart(
    Map<String, dynamic> header,
  ) async {
    final id =
        header['transferId'] as String;

    final name =
        header['fileName'] as String;

    final size =
        header['fileSize'] as int;

    final path = '${directory.path}/'
        '${id}_$name.part';

    final file = await File(path)
        .open(
      mode: FileMode.write,
    );

    final transfer =
        ReceivingTransfer(
      id: id,
      fileName: name,
      fileSize: size,
      file: file,
    );

    _transfers[id] = transfer;
  }

  Future<void> _handleChunk(
    Map<String, dynamic> header,
    List<int> payload,
    IncomingConnection connection,
  ) async {
    final id =
        header['transferId'] as String;

    final chunkIndex =
        header['chunkIndex'] as int;

    final offset =
        header['offset'] as int;

    final length =
        header['length'] as int;

    final transfer =
        _transfers[id];

    if (transfer == null) {
      throw StateError(
        'Unknown transfer',
      );
    }

    if (payload.length != length) {
      throw StateError(
        'Invalid payload length',
      );
    }

    if (offset < 0 ||
        offset + length >
            transfer.fileSize) {
      throw StateError(
        'Invalid chunk range',
      );
    }

    if (transfer.receivedChunks
        .contains(chunkIndex)) {
      await connection.sendAck(
        transferId: id,
        chunkIndex: chunkIndex,
      );

      return;
    }

    await transfer.file
        .setPosition(offset);

    await transfer.file.writeFrom(
      payload,
    );

    transfer.receivedChunks
        .add(chunkIndex);

    await connection.sendAck(
      transferId: id,
      chunkIndex: chunkIndex,
    );
  }

  Future<void> _handleFileEnd(
    Map<String, dynamic> header,
  ) async {
    final id =
        header['transferId'] as String;

    final transfer =
        _transfers.remove(id);

    if (transfer == null) {
      return;
    }

    await transfer.file.flush();
    await transfer.file.close();

    // TODO:
    // SHA-256 the .part file.
    //
    // If correct:
    // rename .part -> final file.
  }

  Future<void> _handleCancel(
    Map<String, dynamic> header,
  ) async {
    final id =
        header['transferId'] as String;

    final transfer =
        _transfers.remove(id);

    await transfer?.file.close();
  }

  Future<void> _handleMessage(
    Map<String, dynamic> header,
    List<int> payload,
  ) async {
    // Decode/process your message here.
  }
}