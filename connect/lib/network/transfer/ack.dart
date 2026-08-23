class ChunkKey {
  final String transferId;
  final int chunkIndex;

  const ChunkKey(this.transferId, this.chunkIndex);

  @override
  bool operator ==(Object other) {
    return other is ChunkKey &&
        other.transferId == transferId &&
        other.chunkIndex == chunkIndex;
  }

  @override
  int get hashCode => Object.hash(transferId, chunkIndex);
}

class ChunkAck {
  final String transferId;
  final int chunkIndex;

  const ChunkAck({
    required this.transferId,
    required this.chunkIndex,
  });
}

