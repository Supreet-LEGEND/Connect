import 'package:connect/network/transfer/transfer.dart';

class TransferChunk {
  final Transfer transfer;

  final int chunkIndex;
  final int offset;
  final List<int> data;

  TransferChunk({
    required this.transfer,
    required this.chunkIndex,
    required this.offset,
    required this.data,
  });
}