import 'dart:async';
import 'dart:collection';
import 'package:connect/network/connection/connection.dart';
import 'package:connect/network/connection/connection_pool.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/network/transfer/transfer_job.dart';

enum SchedulerPriority {
  control,
  message,
  file,
}

enum ChunkState {
  queued,
  sending,
  acked,
  failed,
  deadLetter,
}

class SchedulerConfig {
  final int maxRetries;
  final int maxBytesPerSecond;
  final int maxChunksPerSecond;
  final Duration retryBackoffBase;
  final Duration chunkTimeout;
  final int maxConcurrentTransfers;
  final bool enableBandwidthThrottling;

  const SchedulerConfig({
    this.maxRetries = 3,
    this.maxBytesPerSecond = 0,
    this.maxChunksPerSecond = 0,
    this.retryBackoffBase = const Duration(milliseconds: 100),
    this.chunkTimeout = const Duration(seconds: 30),
    this.maxConcurrentTransfers = 10,
    this.enableBandwidthThrottling = true,
  });
}

class ScheduledChunk {
  final String id;
  final TransferChunk chunk;
  final SchedulerPriority priority;
  final int connectionIndex;

  ChunkState state = ChunkState.queued;
  int retryCount = 0;
  final DateTime createdAt = DateTime.now();
  DateTime? sentAt;
  DateTime? ackedAt;
  DateTime? failedAt;
  Object? lastError;

  ScheduledChunk({
    required this.id,
    required this.chunk,
    this.priority = SchedulerPriority.file,
    required this.connectionIndex,
  });

  Duration get age => DateTime.now().difference(createdAt);

  bool isTimedOut(Duration timeout) {
    return sentAt != null && DateTime.now().difference(sentAt!) > timeout;
  }

  String get stateString => state.toString().split('.').last;
}

class ConnectionStats {
  final String connectionId;
  int chunksProcessed = 0;
  int failedChunks = 0;
  int successfulChunks = 0;
  int retriedChunks = 0;
  int totalBytesSent = 0;
  DateTime startTime = DateTime.now();
  DateTime? lastActivityTime;

  ConnectionStats({required this.connectionId});

  double get successRate {
    if (chunksProcessed == 0) return 0;
    return (successfulChunks / chunksProcessed) * 100;
  }

  double get throughputKBps {
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    if (elapsed == 0) return 0;
    return (totalBytesSent / 1024) / (elapsed / 1000);
  }

  double get utilizationPercent {
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    if (elapsed == 0) return 0;
    return (chunksProcessed / (elapsed / 100)).clamp(0, 100);
  }
}

class SchedulerStats {
  int totalChunksSent = 0;
  int totalChunksFailed = 0;
  int totalRetries = 0;
  int totalChunksAcked = 0;
  int totalDeadLetters = 0;
  int totalBytesSent = 0;
  final DateTime startTime = DateTime.now();
  final Map<String, ConnectionStats> connectionStats = {};

  double get successRate {
    if (totalChunksSent == 0) return 0;
    return (totalChunksAcked / totalChunksSent) * 100;
  }

  double get averageThroughputKBps {
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    if (elapsed == 0) return 0;
    return (totalBytesSent / 1024) / (elapsed / 1000);
  }

  double get retryRate {
    if (totalChunksSent == 0) return 0;
    return (totalRetries / totalChunksSent) * 100;
  }
}

abstract class SchedulerEvent {
  final DateTime timestamp = DateTime.now();
}

class ChunkQueuedEvent extends SchedulerEvent {
  final ScheduledChunk chunk;
  ChunkQueuedEvent(this.chunk);
}

class ChunkSentEvent extends SchedulerEvent {
  final ScheduledChunk chunk;
  final String connectionId;
  ChunkSentEvent(this.chunk, this.connectionId);
}

class ChunkAckedEvent extends SchedulerEvent {
  final String chunkId;
  final Duration latency;
  ChunkAckedEvent(this.chunkId, this.latency);
}

class TransferCompletedEvent extends SchedulerEvent {
  final String transferId;
  TransferCompletedEvent(this.transferId);
}

class ChunkFailedEvent extends SchedulerEvent {
  final String chunkId;
  final Object error;
  final int retryCount;
  ChunkFailedEvent(this.chunkId, this.error, this.retryCount);
}

class ChunkRetryEvent extends SchedulerEvent {
  final String chunkId;
  final int retryCount;
  final Duration backoffDuration;
  ChunkRetryEvent(this.chunkId, this.retryCount, this.backoffDuration);
}

class TransferPausedEvent extends SchedulerEvent {
  final String transferId;
  TransferPausedEvent(this.transferId);
}

class TransferResumedEvent extends SchedulerEvent {
  final String transferId;
  TransferResumedEvent(this.transferId);
}

class TransferCancelledEvent extends SchedulerEvent {
  final String transferId;
  final String reason;
  TransferCancelledEvent(this.transferId, this.reason);
}

class BandwidthThrottledEvent extends SchedulerEvent {
  final int waitMilliseconds;
  final int availableBytes;
  BandwidthThrottledEvent(this.waitMilliseconds, this.availableBytes);
}

class _ConnectionQueue {
  final Queue<ScheduledChunk> _controlQueue = Queue();
  final Queue<ScheduledChunk> _messageQueue = Queue();
  final Queue<ScheduledChunk> _fileQueue = Queue();

  void add(ScheduledChunk chunk) {
    switch (chunk.priority) {
      case SchedulerPriority.control:
        _controlQueue.add(chunk);
        break;
      case SchedulerPriority.message:
        _messageQueue.add(chunk);
        break;
      case SchedulerPriority.file:
        _fileQueue.add(chunk);
        break;
    }
  }

  ScheduledChunk? removeFirst() {
    if (_controlQueue.isNotEmpty) return _controlQueue.removeFirst();
    if (_messageQueue.isNotEmpty) return _messageQueue.removeFirst();
    if (_fileQueue.isNotEmpty) return _fileQueue.removeFirst();
    return null;
  }

  bool get isEmpty => _controlQueue.isEmpty && _messageQueue.isEmpty && _fileQueue.isEmpty;

  int get length => _controlQueue.length + _messageQueue.length + _fileQueue.length;

  void clear() {
    _controlQueue.clear();
    _messageQueue.clear();
    _fileQueue.clear();
  }

  Map<String, int> getQueueSizes() {
    return {
      'control': _controlQueue.length,
      'message': _messageQueue.length,
      'file': _fileQueue.length,
    };
  }
}

class TransferScheduler {
  final ConnectionPool pool;
  final SchedulerConfig config;
  final int numConnections;
  final List<_ConnectionQueue> _connectionQueues;
  final Map<String, ScheduledChunk> _allChunks = {};
  final Map<String, Map<String, int>> _transferChunkCounts = {};
  final Set<String> _pausedTransfers = {};
  final Map<String, ConnectionStats> _connectionStats = {};
  late SchedulerStats stats;
  final StreamController<SchedulerEvent> _eventController = StreamController<SchedulerEvent>.broadcast();
  DateTime _bandwidthWindowStart = DateTime.now();
  int _bytesInCurrentWindow = 0;
  DateTime _chunkWindowStart = DateTime.now();
  int _chunksInCurrentWindow = 0;
  bool _running = false;
  final List<Future<void>> _workerFutures = [];
  final void Function(Transfer transfer)? onTransferProgress;
  final void Function(String transferId)? onTransferCompleted;

  TransferScheduler({
    required this.pool,
    this.config = const SchedulerConfig(),
    this.onTransferProgress,
    this.onTransferCompleted,
  }) : numConnections = pool.connections.length,
       _connectionQueues = List.generate(pool.connections.length, (_) => _ConnectionQueue()) {
    stats = SchedulerStats();
    _initializeConnectionStats();
  }

  Stream<SchedulerEvent> get events => _eventController.stream;

  void _initializeConnectionStats() {
    for (int i = 0; i < pool.connections.length; i++) {
      final conn = pool.connections[i];
      _connectionStats[conn.id] = ConnectionStats(connectionId: conn.id);
    }
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    for (int i = 0; i < pool.connections.length; i++) {
      final connection = pool.connections[i];
      _workerFutures.add(_runWorker(connection, i));
    }
    _startTimeoutSweep();
  }

  Future<void> stop() async {
    _running = false;
    await Future.wait(_workerFutures);
    for (final q in _connectionQueues) q.clear();
  }

  Future<void> _runWorker(Connection connection, int connectionIndex) async {
    final queue = _connectionQueues[connectionIndex];
    while (_running) {
      try {
        final scheduledChunk = queue.removeFirst();
        if (scheduledChunk == null) {
          await Future.delayed(const Duration(milliseconds: 50));
          continue;
        }
        if (scheduledChunk.connectionIndex != connectionIndex) {
          _connectionQueues[scheduledChunk.connectionIndex].add(scheduledChunk);
          continue;
        }
        if (_pausedTransfers.contains(scheduledChunk.chunk.transfer.id)) {
          queue.add(scheduledChunk);
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }
        await _applyRateLimit(scheduledChunk.chunk.data.length);
        scheduledChunk.state = ChunkState.sending;
        scheduledChunk.sentAt = DateTime.now();
        try {
          await connection.send(
            type: 'file_chunk',
            metadata: {
              'transferId': scheduledChunk.chunk.transfer.id,
              'chunkIndex': scheduledChunk.chunk.chunkIndex,
              'offset': scheduledChunk.chunk.offset,
              'length': scheduledChunk.chunk.data.length,
            },
            plaintext: scheduledChunk.chunk.data,
          );
          _emitEvent(ChunkSentEvent(scheduledChunk, connection.id));
          _recordChunkSent(scheduledChunk, connection.id);
        } catch (e) {
          await _handleChunkError(scheduledChunk, e);
        }
      } catch (e) {
        print('Scheduler worker error: $e');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _handleChunkError(ScheduledChunk chunk, Object error) async {
    chunk.lastError = error;
    chunk.failedAt = DateTime.now();
    stats.totalChunksFailed++;
    if (chunk.retryCount < config.maxRetries) {
      await _retryChunk(chunk);
    } else {
      chunk.state = ChunkState.deadLetter;
      stats.totalDeadLetters++;
      _emitEvent(ChunkFailedEvent(chunk.id, error, chunk.retryCount));
      _checkTransferCompletion(chunk.chunk.transfer.id);
    }
  }

  Future<void> _retryChunk(ScheduledChunk chunk) async {
    chunk.retryCount++;
    final backoffDuration = _getBackoffDuration(chunk.retryCount);
    _emitEvent(ChunkRetryEvent(chunk.id, chunk.retryCount, backoffDuration));
    stats.totalRetries++;
    await Future.delayed(backoffDuration);
    chunk.state = ChunkState.queued;
    _connectionQueues[chunk.connectionIndex].add(chunk);
  }

  Duration _getBackoffDuration(int retryCount) {
    final ms = (config.retryBackoffBase.inMilliseconds * (1 << (retryCount - 1))).toInt();
    return Duration(milliseconds: ms.clamp(0, 1000));
  }

  Future<void> _applyRateLimit(int byteSize) async {
    if (!config.enableBandwidthThrottling) return;
    if (config.maxBytesPerSecond > 0) {
      final now = DateTime.now();
      if (now.difference(_bandwidthWindowStart).inSeconds >= 1) {
        _bandwidthWindowStart = now;
        _bytesInCurrentWindow = 0;
      }
      if (_bytesInCurrentWindow + byteSize > config.maxBytesPerSecond) {
        final waitMs = 100;
        _emitEvent(BandwidthThrottledEvent(waitMs, config.maxBytesPerSecond - _bytesInCurrentWindow));
        await Future.delayed(Duration(milliseconds: waitMs));
      }
      _bytesInCurrentWindow += byteSize;
    }
    if (config.maxChunksPerSecond > 0) {
      final now = DateTime.now();
      if (now.difference(_chunkWindowStart).inSeconds >= 1) {
        _chunkWindowStart = now;
        _chunksInCurrentWindow = 0;
      }
      if (_chunksInCurrentWindow >= config.maxChunksPerSecond) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      _chunksInCurrentWindow++;
    }
  }

  void _startTimeoutSweep() {
    Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_running) { timer.cancel(); return; }
      _checkTimeouts();
    });
  }

  void _checkTimeouts() {
    final now = DateTime.now();
    for (final chunk in _allChunks.values) {
      if (chunk.state == ChunkState.sending && chunk.sentAt != null && now.difference(chunk.sentAt!) > config.chunkTimeout) {
        chunk.state = ChunkState.queued;
        _connectionQueues[chunk.connectionIndex].add(chunk);
        stats.totalRetries++;
        _emitEvent(ChunkRetryEvent(chunk.id, chunk.retryCount + 1, Duration.zero));
      }
    }
  }

  void addChunk(TransferChunk chunk, {SchedulerPriority priority = SchedulerPriority.file}) {
    final connectionIndex = chunk.chunkIndex % numConnections;
    final scheduledChunk = ScheduledChunk(
      id: '${chunk.transfer.id}_${chunk.chunkIndex}',
      chunk: chunk,
      priority: priority,
      connectionIndex: connectionIndex,
    );
    _allChunks[scheduledChunk.id] = scheduledChunk;
    _connectionQueues[connectionIndex].add(scheduledChunk);
    stats.totalChunksSent++;
    final counts = _transferChunkCounts.putIfAbsent(chunk.transfer.id, () => {'total': 0, 'acked': 0});
    counts['total'] = counts['total']! + 1;
    _emitEvent(ChunkQueuedEvent(scheduledChunk));
  }

  void _recordChunkSent(ScheduledChunk chunk, String connectionId) {
    final connStats = _connectionStats[connectionId];
    if (connStats != null) {
      connStats.chunksProcessed++;
      connStats.totalBytesSent += chunk.chunk.data.length;
      connStats.lastActivityTime = DateTime.now();
    }
  }

  void recordChunkAck(String chunkId) {
    final chunk = _allChunks[chunkId];
    if (chunk == null) return;
    chunk.state = ChunkState.acked;
    chunk.ackedAt = DateTime.now();
    stats.totalChunksAcked++;
    final latency = chunk.ackedAt!.difference(chunk.sentAt!);
    _emitEvent(ChunkAckedEvent(chunkId, latency));
    for (final connStats in _connectionStats.values) connStats.successfulChunks++;
    final transfer = chunk.chunk.transfer;
    if (transfer is FileTransfer) {
      transfer.transferredBytes += chunk.chunk.data.length;
      if (onTransferProgress != null) onTransferProgress!(transfer);
    }
    _checkTransferCompletion(chunk.chunk.transfer.id);
  }

  void _checkTransferCompletion(String transferId) {
    final counts = _transferChunkCounts[transferId];
    if (counts == null) return;
    counts['acked'] = counts['acked']! + 1;
    if (counts['acked']! >= counts['total']!) {
      _transferChunkCounts.remove(transferId);
      _emitEvent(TransferCompletedEvent(transferId));
      if (onTransferCompleted != null) onTransferCompleted!(transferId);
    }
  }

  void pauseTransfer(String transferId) {
    _pausedTransfers.add(transferId);
    _emitEvent(TransferPausedEvent(transferId));
  }

  void resumeTransfer(String transferId) {
    _pausedTransfers.remove(transferId);
    _emitEvent(TransferResumedEvent(transferId));
  }

  void cancelTransfer(String transferId, String reason) {
    _pausedTransfers.remove(transferId);
    final chunksToRemove = _allChunks.entries.where((e) => e.value.chunk.transfer.id == transferId).map((e) => e.key).toList();
    for (final chunkId in chunksToRemove) {
      final chunk = _allChunks.remove(chunkId);
      if (chunk != null) chunk.state = ChunkState.deadLetter;
    }
    _transferChunkCounts.remove(transferId);
    _emitEvent(TransferCancelledEvent(transferId, reason));
  }

  ScheduledChunk? getChunk(String chunkId) => _allChunks[chunkId];
  List<ScheduledChunk> getQueueStatus() => _allChunks.values.toList();
  Map<String, Map<String, int>> getQueueSizes() {
    final result = <String, Map<String, int>>{};
    for (int i = 0; i < _connectionQueues.length; i++) result['connection_$i'] = _connectionQueues[i].getQueueSizes();
    return result;
  }

  SchedulerStats getStatistics() {
    stats.connectionStats.clear();
    stats.connectionStats.addAll(_connectionStats);
    return stats;
  }

  ConnectionStats? getConnectionStats(String connectionId) => _connectionStats[connectionId];

  void _emitEvent(SchedulerEvent event) {
    if (!_eventController.isClosed) _eventController.add(event);
  }

  Future<void> dispose() async {
    await stop();
    await _eventController.close();
  }
}