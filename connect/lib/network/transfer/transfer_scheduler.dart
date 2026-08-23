// import 'dart:async';

// import '../connection/connection_pool.dart';
// import '../transfer/transfer.dart';
// import '../transfer/transfer_job.dart';

// class DeviceScheduler {
//   final ConnectionPool pool;

//   final AsyncQueue<TransferChunk>
//       queue =
//       AsyncQueue<TransferChunk>();

//   bool _running = false;

//   DeviceScheduler({
//     required this.pool,
//   });

//   Future<void> start() async {
//     if (_running) {
//       return;
//     }

//     _running = true;

//     for (final connection
//         in pool.connections) {
//       _runWorker(connection);
//     }
//   }

//   Future<void> _runWorker(
//     connection,
//   ) async {
//     while (_running) {
//       final job =
//           await queue.next();

//       if (!_running) {
//         return;
//       }

//       try {
//         await connection.send(
//           type: 'file_chunk',
//           metadata: {
//             'transferId':
//                 job.transfer.id,
//             'chunkIndex':
//                 job.chunkIndex,
//             'offset':
//                 job.offset,
//             'length':
//                 job.data.length,
//           },
//           plaintext: job.data,
//         );

//         job.transfer
//                 .transferredBytes +=
//             job.data.length;
//       } catch (e) {
//         // Requeue the job.
//         queue.add(job);

//         await Future.delayed(
//           const Duration(
//             milliseconds: 200,
//           ),
//         );
//       }
//     }
//   }

//   void add(
//     TransferChunk chunk,
//   ) {
//     queue.add(chunk);
//   }

//   Future<void> stop() async {
//     _running = false;
//   }
// }