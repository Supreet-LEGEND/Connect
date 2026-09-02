import 'dart:async';
import 'dart:collection';
import 'package:connect/network/connection/connection_pool.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/network/transfer/transfer_job.dart';

// ============================================================================
// ENUMS & STATE MACHINES
// ============================================================================

/// Priority levels for transfer scheduling
enum SchedulerPriority {
  control,  // Highest priority (protocol messages)
  message,  // Medium priority (user messages)
  file,     // Lowest priority (large file transfers)
}

/// State machine for chunk lifecycle
enum ChunkState {
  queued,    // Waiting to be sent
  sending,   // Currently being sent
  acked,     // Successfully received and ACK'd
  failed,    // Failed (will retry)
  deadLetter, // Failed after max retries
}

// ============================================================================
// DATA CLASSES
// ============================================================================

/// Configuration for the transfer scheduler
class SchedulerConfig {
  /// Maximum number of retry attempts per chunk
  final int maxRetries;

  /// Maximum bytes per second per device (0 = unlimited)
  final int maxBytesPerSecond;

  /// Maximum chunks per second (0 = unlimited)
  final int maxChunksPerSecond;

  /// Base duration for exponential backoff (100ms default)
  final Duration retryBackoffBase;

  /// Maximum time to wait before chunk timeout (30s default)
  final Duration chunkTimeout;

  /// Maximum concurrent transfers per device
  final int maxConcurrentTransfers;

  /// Whether to enable bandwidth throttling
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

/// Wrapper for chunk with scheduling metadata
class ScheduledChunk {
  final String id;
  final TransferChunk chunk;
  final SchedulerPriority priority;

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
  });

  /// Duration since this chunk was created
  Duration get age => DateTime.now().difference(createdAt);

  /// Check if chunk has exceeded timeout
  bool isTimedOut(Duration timeout) {
    return sentAt != null &&
        DateTime.now().difference(sentAt!) > timeout;
  }

  /// Get string representation of state
  String get stateString => state.toString().split('.').last;
}

/// Statistics for a single connection worker
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

  /// Success rate as percentage (0-100)
  double get successRate {
    if (chunksProcessed == 0) return 0;
    return (successfulChunks / chunksProcessed) * 100;
  }

  /// Calculate throughput in KB/s
  double get throughputKBps {
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    if (elapsed == 0) return 0;
    return (totalBytesSent / 1024) / (elapsed / 1000);
  }

  /// Utilization as percentage (0-100)
  double get utilizationPercent {
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    if (elapsed == 0) return 0;
    // Rough estimate based on activity
    return (chunksProcessed / (elapsed / 100)).clamp(0, 100);
  }
}

/// Overall scheduler statistics
class SchedulerStats {
  int totalChunksSent = 0;
  int totalChunksFailed = 0;
  int totalRetries = 0;
  int totalChunksAcked = 0;
  int totalDeadLetters = 0;
  int totalBytesSent = 0;
  final DateTime startTime = DateTime.now();
  final Map<String, ConnectionStats> connectionStats = {};

  /// Overall success rate
  double get successRate {
    if (totalChunksSent == 0) return 0;
    return (totalChunksAcked / totalChunksSent) * 100;
  }

  /// Overall throughput in KB/s
  double get averageThroughputKBps {
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    if (elapsed == 0) return 0;
    return (totalBytesSent / 1024) / (elapsed / 1000);
  }

  /// Retry rate as percentage
  double get retryRate {
    if (totalChunksSent == 0) return 0;
    return (totalRetries / totalChunksSent) * 100;
  }
}

// ============================================================================
// EVENTS FOR MONITORING
// ============================================================================

/// Base class for scheduler events
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

// ============================================================================
// PRIORITY QUEUE
// ============================================================================

/// Queue that orders chunks by priority and creation time
class BoundedPriorityQueue {
  final Queue<ScheduledChunk> _controlQueue = Queue();
  final Queue<ScheduledChunk> _messageQueue = Queue();
  final Queue<ScheduledChunk> _fileQueue = Queue();

  /// Add chunk to appropriate priority queue
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

  /// Remove and return highest priority chunk (or null if empty)
  ScheduledChunk? removeFirst() {
    if (_controlQueue.isNotEmpty) {
      return _controlQueue.removeFirst();
    }
    if (_messageQueue.isNotEmpty) {
      return _messageQueue.removeFirst();
    }
    if (_fileQueue.isNotEmpty) {
      return _fileQueue.removeFirst();
    }
    return null;
  }

  /// Check if queue is empty
  bool get isEmpty =>
      _controlQueue.isEmpty &&
      _messageQueue.isEmpty &&
      _fileQueue.isEmpty;

  /// Get total chunks across all queues
  int get length =>
      _controlQueue.length +
      _messageQueue.length +
      _fileQueue.length;

  /// Clear all queues
  void clear() {
    _controlQueue.clear();
    _messageQueue.clear();
    _fileQueue.clear();
  }

  /// Get queue sizes for monitoring
  Map<String, int> getQueueSizes() {
    return {
      'control': _controlQueue.length,
      'message': _messageQueue.length,
      'file': _fileQueue.length,
    };
  }
}

// ============================================================================
// MAIN SCHEDULER
// ============================================================================

/// Production-grade transfer scheduler with load balancing, prioritization, and retry logic
class TransferScheduler {
  final ConnectionPool pool;
  final SchedulerConfig config;

  /// Priority queue for chunks
  final BoundedPriorityQueue queue = BoundedPriorityQueue();

  /// Track all scheduled chunks
  final Map<String, ScheduledChunk> _allChunks = {};

  /// Track paused transfers
  final Set<String> _pausedTransfers = {};

  /// Connection statistics
  final Map<String, ConnectionStats> _connectionStats = {};

  /// Global scheduler statistics
  late SchedulerStats stats;

  /// Event stream for monitoring
  final StreamController<SchedulerEvent> _eventController =
      StreamController<SchedulerEvent>.broadcast();

  /// Bandwidth tracking
  DateTime _bandwidthWindowStart = DateTime.now();
  int _bytesInCurrentWindow = 0;
  DateTime _chunkWindowStart = DateTime.now();
  int _chunksInCurrentWindow = 0;

  /// Scheduler state
  bool _running = false;
  final List<Future<void>> _workerFutures = [];

  /// Load balancing state
  int _lastConnectionIndex = 0;

  TransferScheduler({
    required this.pool,
    this.config = const SchedulerConfig(),
  }) {
    stats = SchedulerStats();
    _initializeConnectionStats();
  }

  /// Get event stream
  Stream<SchedulerEvent> get events => _eventController.stream;

  /// Initialize statistics for each connection
  void _initializeConnectionStats() {
    for (int i = 0; i < pool.connections.length; i++) {
      final conn = pool.connections[i];
      _connectionStats[conn.id] =
          ConnectionStats(connectionId: conn.id);
    }
  }

  /// Start the scheduler and worker threads
  Future<void> start() async {
    if (_running) {
      return;
    }

    _running = true;

    // Start a worker for each connection
    for (final connection in pool.connections) {
      final workerFuture = _runWorker(connection);
      _workerFutures.add(workerFuture);
    }
  }

  /// Stop the scheduler gracefully
  Future<void> stop() async {
    _running = false;
    await Future.wait(_workerFutures);
    queue.clear();
  }

  /// Worker thread that processes chunks
  Future<void> _runWorker(dynamic connection) async {
    while (_running) {
      try {
        // Get next chunk (respects priority)
        final scheduledChunk = queue.removeFirst();

        if (scheduledChunk == null) {
          // No chunks, wait a bit
          await Future.delayed(const Duration(milliseconds: 50));
          continue;
        }

        // Check if transfer is paused
        if (_pausedTransfers
            .contains(scheduledChunk.chunk.transfer.id)) {
          // Requeue for later
          queue.add(scheduledChunk);
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }

        // Apply rate limiting
        await _applyRateLimit(scheduledChunk.chunk.data.length);

        // Send the chunk
        scheduledChunk.state = ChunkState.sending;
        scheduledChunk.sentAt = DateTime.now();

        try {
          // TODO: Actual send implementation
          // await connection.send(
          //   type: 'file_chunk',
          //   metadata: {
          //     'transferId': scheduledChunk.chunk.transfer.id,
          //     'chunkIndex': scheduledChunk.chunk.chunkIndex,
          //     'offset': scheduledChunk.chunk.offset,
          //     'length': scheduledChunk.chunk.data.length,
          //   },
          //   plaintext: scheduledChunk.chunk.data,
          // );

          _emitEvent(ChunkSentEvent(scheduledChunk, connection.id));
          _recordChunkSent(scheduledChunk, connection.id);
        } catch (e) {
          // Handle send error
          await _handleChunkError(scheduledChunk, e);
        }
      } catch (e) {
        // Log worker error but continue
        print('Scheduler worker error: $e');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  /// Handle chunk send error with retry logic
  Future<void> _handleChunkError(
    ScheduledChunk chunk,
    Object error,
  ) async {
    chunk.lastError = error;
    chunk.failedAt = DateTime.now();
    stats.totalChunksFailed++;

    if (chunk.retryCount < config.maxRetries) {
      // Retry with exponential backoff
      await _retryChunk(chunk);
    } else {
      // Max retries exceeded
      chunk.state = ChunkState.deadLetter;
      stats.totalDeadLetters++;
      _emitEvent(ChunkFailedEvent(
        chunk.id,
        error,
        chunk.retryCount,
      ));
    }
  }

  /// Retry a chunk with exponential backoff
  Future<void> _retryChunk(ScheduledChunk chunk) async {
    chunk.retryCount++;
    final backoffDuration = _getBackoffDuration(chunk.retryCount);

    _emitEvent(ChunkRetryEvent(
      chunk.id,
      chunk.retryCount,
      backoffDuration,
    ));

    stats.totalRetries++;

    // Wait before retrying
    await Future.delayed(backoffDuration);

    // Requeue chunk
    chunk.state = ChunkState.queued;
    queue.add(chunk);
  }

  /// Calculate exponential backoff duration
  Duration _getBackoffDuration(int retryCount) {
    final ms = (config.retryBackoffBase.inMilliseconds *
            (1 << (retryCount - 1)))
        .toInt();
    // Cap at 1 second
    return Duration(milliseconds: ms.clamp(0, 1000));
  }

  /// Apply rate limiting for bandwidth and chunk rate
  Future<void> _applyRateLimit(int byteSize) async {
    if (!config.enableBandwidthThrottling) {
      return;
    }

    // Check bytes per second limit
    if (config.maxBytesPerSecond > 0) {
      final now = DateTime.now();
      if (now.difference(_bandwidthWindowStart).inSeconds >= 1) {
        _bandwidthWindowStart = now;
        _bytesInCurrentWindow = 0;
      }

      if (_bytesInCurrentWindow + byteSize >
          config.maxBytesPerSecond) {
        final waitMs = 100;
        _emitEvent(BandwidthThrottledEvent(
          waitMs,
          config.maxBytesPerSecond - _bytesInCurrentWindow,
        ));
        await Future.delayed(Duration(milliseconds: waitMs));
      }

      _bytesInCurrentWindow += byteSize;
    }

    // Check chunks per second limit
    if (config.maxChunksPerSecond > 0) {
      final now = DateTime.now();
      if (now.difference(_chunkWindowStart).inSeconds >= 1) {
        _chunkWindowStart = now;
        _chunksInCurrentWindow = 0;
      }

      if (_chunksInCurrentWindow >= config.maxChunksPerSecond) {
        await Future.delayed(
          const Duration(milliseconds: 50),
        );
      }

      _chunksInCurrentWindow++;
    }
  }

  /// Select least loaded connection for next chunk
  dynamic _selectLeastLoadedConnection() {
    if (pool.connections.isEmpty) {
      throw StateError('No connections available');
    }

    dynamic leastLoaded = pool.connections[0];
    int minChunks = _connectionStats[leastLoaded.id]?.chunksProcessed ?? 0;

    for (final conn in pool.connections) {
      final stats = _connectionStats[conn.id];
      final chunks = stats?.chunksProcessed ?? 0;
      if (chunks < minChunks) {
        leastLoaded = conn;
        minChunks = chunks;
      }
    }

    return leastLoaded;
  }

  /// Round-robin connection selection
  dynamic _selectRoundRobinConnection() {
    if (pool.connections.isEmpty) {
      throw StateError('No connections available');
    }

    final conn = pool.connections[_lastConnectionIndex];
    _lastConnectionIndex =
        (_lastConnectionIndex + 1) % pool.connections.length;
    return conn;
  }

  /// Add chunk to scheduler
  void addChunk(
    TransferChunk chunk, {
    SchedulerPriority priority = SchedulerPriority.file,
  }) {
    final scheduledChunk = ScheduledChunk(
      id: '${chunk.transfer.id}_${chunk.chunkIndex}',
      chunk: chunk,
      priority: priority,
    );

    _allChunks[scheduledChunk.id] = scheduledChunk;
    queue.add(scheduledChunk);
    stats.totalChunksSent++;

    _emitEvent(ChunkQueuedEvent(scheduledChunk));
  }

  /// Record successful chunk transmission
  void _recordChunkSent(
    ScheduledChunk chunk,
    String connectionId,
  ) {
    final connStats = _connectionStats[connectionId];
    if (connStats != null) {
      connStats.chunksProcessed++;
      connStats.totalBytesSent += chunk.chunk.data.length;
      connStats.lastActivityTime = DateTime.now();
    }
  }

  /// Mark chunk as ACK'd
  void recordChunkAck(String chunkId) {
    final chunk = _allChunks[chunkId];
    if (chunk == null) return;

    chunk.state = ChunkState.acked;
    chunk.ackedAt = DateTime.now();

    stats.totalChunksAcked++;

    final latency = chunk.ackedAt!.difference(chunk.sentAt!);
    _emitEvent(ChunkAckedEvent(chunkId, latency));

    // Update connection stats
    for (final connStats in _connectionStats.values) {
      connStats.successfulChunks++;
    }
  }

  /// Pause a transfer (doesn't dequeue existing chunks)
  void pauseTransfer(String transferId) {
    _pausedTransfers.add(transferId);
    _emitEvent(TransferPausedEvent(transferId));
  }

  /// Resume a paused transfer
  void resumeTransfer(String transferId) {
    _pausedTransfers.remove(transferId);
    _emitEvent(TransferResumedEvent(transferId));
  }

  /// Cancel a transfer (removes all its chunks)
  void cancelTransfer(String transferId, String reason) {
    _pausedTransfers.remove(transferId);

    // Remove all chunks for this transfer
    final chunksToRemove = _allChunks.entries
        .where((e) => e.value.chunk.transfer.id == transferId)
        .map((e) => e.key)
        .toList();

    for (final chunkId in chunksToRemove) {
      _allChunks.remove(chunkId);
    }

    _emitEvent(TransferCancelledEvent(transferId, reason));
  }

  /// Get chunk by ID
  ScheduledChunk? getChunk(String chunkId) {
    return _allChunks[chunkId];
  }

  /// Get current queue status
  List<ScheduledChunk> getQueueStatus() {
    return _allChunks.values.toList();
  }

  /// Get queue sizes by priority
  Map<String, int> getQueueSizes() {
    return queue.getQueueSizes();
  }

  /// Get comprehensive statistics
  SchedulerStats getStatistics() {
    stats.connectionStats.clear();
    stats.connectionStats.addAll(_connectionStats);
    return stats;
  }

  /// Get connection-specific statistics
  ConnectionStats? getConnectionStats(String connectionId) {
    return _connectionStats[connectionId];
  }

  /// Set bandwidth limit (0 = unlimited)
  void setBandwidthLimit(int bytesPerSecond) {
    // Would need to create a new config or make config mutable
    // For now, this is a placeholder
  }

  /// Emit event to listeners
  void _emitEvent(SchedulerEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  /// Clean up resources
  Future<void> dispose() async {
    await stop();
    await _eventController.close();
  }
}