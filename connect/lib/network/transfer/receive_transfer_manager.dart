import 'dart:async';
import 'dart:io';

import 'package:connect/network/connection/incoming_connection.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/network/transfer/transfer_manager.dart';

/// Manages incoming file transfers from remote devices
/// 
/// Tracks received transfers and coordinates with bounded queue.
/// Sends size information to sender for backpressure feedback.
class ReceiveTransferManager extends BaseTransferManager {
  final Directory directory;

  /// Track bytes received per transfer for backpressure feedback
  final Map<String, int> _bytesReceivedPerTransfer = {};

  ReceiveTransferManager({
    required this.directory,
  });

  @override
  Future<void> registerDevice(DeviceSession device) async {
    // Receive side doesn't need per-device queues
    // But could track device-level statistics here
  }

  /// Register an incoming connection and start listening to its frames
  /// 
  /// This method should be called when a new connection is accepted.
  /// It subscribes to the connection's frame stream and processes
  /// all incoming frames for transfer operations.
  Future<void> registerConnection(
    IncomingConnection connection,
  ) async {
    await connection.start();

    // Subscribe to all frames from this connection
    connection.frames.listen(
      (frame) async {
        await _handleFrame(
          type: frame['type'] as String,
          header: frame['header'] as Map<String, dynamic>,
          payload: frame['payload'] as List<int>,
          connection: frame['connection'] as IncomingConnection,
        );
      },
      onError: (error) {
        // TODO: Log error
      },
      onDone: () {
        // Connection closed
      },
    );
  }

  /// Handle a single frame from a connection
  Future<void> _handleFrame({
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
        ReceivingFileTransfer(
      id: id,
      deviceId: '', // TODO: Get actual device ID from connection context
      fileName: name,
      fileSize: size,
      file: file,
    );

    transfers[transfer.id] = transfer;
    _bytesReceivedPerTransfer[id] = 0;
    transfer.status = TransferStatus.transferring;
    emitUpdate(transfer);
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
        transfers[id] as ReceivingFileTransfer?;

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

    // Track bytes received for backpressure feedback
    _bytesReceivedPerTransfer[id] = (_bytesReceivedPerTransfer[id] ?? 0) + length;

    emitUpdate(transfer);

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
        transfers.remove(id) as ReceivingFileTransfer?;

    if (transfer == null) {
      return;
    }

    await transfer.file.flush();
    await transfer.file.close();

    _bytesReceivedPerTransfer.remove(id);

    transfer.status = TransferStatus.completed;
    emitUpdate(transfer);

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
        transfers.remove(id) as ReceivingFileTransfer?;

    await transfer?.file.close();
    _bytesReceivedPerTransfer.remove(id);

    if (transfer != null) {
      transfer.status = TransferStatus.cancelled;
      emitUpdate(transfer);
    }
  }

  Future<void> _handleMessage(
    Map<String, dynamic> header,
    List<int> payload,
  ) async {
    // Decode/process message here.
  }
}