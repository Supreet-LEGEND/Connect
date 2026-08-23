import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'package:connect/network/connection/device_session.dart';
import 'package:connect/network/connection_utils/async_semaphore.dart';
import 'package:connect/network/transfer/send_transfer.dart';
import 'package:connect/network/transfer/transfer_job.dart';

import '../connection/connection_manager.dart';

class TransferManager {
  final ConnectionManager
      connectionManager;

  final Map<String, Transfer>
      _transfers = {};

  final StreamController<Transfer>
      _updates =
      StreamController<Transfer>
          .broadcast();

  TransferManager({
    required this.connectionManager,
  });

  Stream<Transfer> get updates =>
      _updates.stream;

  Future<void> registerDevice(
    DeviceSession device,
  ) async {

  Future<Transfer> sendFile({
    required String deviceId,
    required File file,
  }) async {
    final device =
        connectionManager.get(
      deviceId,
    );

    if (device == null) {
      throw StateError(
        'Device not connected',
      );
    }

    final scheduler =
        _schedulers[deviceId];

    if (scheduler == null) {
      throw StateError(
        'Device scheduler not started',
      );
    }

    final size =
        await file.length();

    final transfer =
        Transfer(
      id: _generateId(),
      deviceId: deviceId,
      type: TransferType.file,
      filePath: file.path,
      fileName:
          file.uri.pathSegments.last,
      totalBytes: size,
    );

    _transfers[transfer.id] =
        transfer;

    transfer.status =
        TransferStatus.transferring;

    _updates.add(transfer);

    await device.pool
        .connections.first
        .sendControl(
      type: 'file_start',
      metadata: {
        'transferId':
            transfer.id,
        'fileName':
            transfer.fileName,
        'fileSize':
            transfer.totalBytes,
      },
    );

    await _produceChunks(
      file: file,
      transfer: transfer,
      scheduler: scheduler,
    );

    return transfer;
  }

  Future<void> _produceChunks({
    required File file,
    required Transfer transfer,
    // required DeviceScheduler scheduler,
  }) async {
    const chunkSize =
        1024 * 1024;

    final fileSize =
        await file.length();

    final raf = await file.open(
      mode: FileMode.read,
    );

    final semaphore =
        AsyncSemaphore(16);

    try {
      int offset = 0;
      int index = 0;

      while (offset < fileSize) {
        await semaphore.acquire();

        final length =
            min(
          chunkSize,
          fileSize - offset,
        );

        await raf.setPosition(
          offset,
        );

        final bytes =
            await raf.read(length);

        final chunk =
            TransferChunk(
          transfer: transfer,
          chunkIndex: index,
          offset: offset,
          data: bytes,
        );

        // scheduler.add(chunk);

        // In a production implementation,
        // release this only after the worker
        // successfully completes the chunk.
        semaphore.release();

        offset += bytes.length;
        index++;
      }
    } finally {
      await raf.close();
    }
  }

//   Future<void> produceFileChunks(
//   Transfer transfer,
//   ConnectionSession connection,
// ) async {
//   final file = File(transfer.filePath);

//   final randomAccess = await file.open(
//     mode: FileMode.read,
//   );

//   try {
//     await randomAccess.setPosition(
//       transfer.nextChunk * transfer.chunkSize,
//     );

//     final semaphore = AsyncSemaphore(8);

//     final pending = <Future<void>>[];

//     while (transfer.nextChunk <
//         transfer.totalChunks) {

//       await semaphore.acquire();

//       final chunkIndex = transfer.nextChunk;

//       final data = await randomAccess.read(
//         transfer.chunkSize,
//       );

//       if (data.isEmpty) {
//         semaphore.release();
//         break;
//       }

//       final chunk = Uint8List.fromList(data);

//       final future = _sendChunkAndRelease(
//         semaphore,
//         connection,
//         transfer,
//         chunkIndex,
//         chunk,
//       );

//       pending.add(future);

//       transfer.nextChunk++;
//     }

//     await Future.wait(pending);
//   } finally {
//     await randomAccess.close();
//   }
// }

  String _generateId() {
    return DateTime.now()
        .microsecondsSinceEpoch
        .toString();
  }

  Future<void> dispose() async {
    for (final scheduler
        in _schedulers.values) {
      await scheduler.stop();
    }

    await _updates.close();
  }
}