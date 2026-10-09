/// Transfer configuration with feature flags for gradual rollout

class TransferConfig {
  /// Enable the new three-isolate architecture
  static const bool useIsolateArchitecture = true;

  /// Enable Android background transfers via Foreground Service
  static const bool enableAndroidBackground = true;

  /// Enable Windows background service
  static const bool enableWindowsService = true;

  /// Default chunk size in bytes (1 MB)
  static const int chunkSizeDefault = 1024 * 1024;

  /// Progress persistence interval (save every N chunks)
  static const int progressPersistInterval = 10;

  /// Maximum chunk size for large files (>10 GB) - 16 MB
  static const int chunkSizeLarge = 16 * 1024 * 1024;

  /// Medium chunk size for files 1-10 GB - 4 MB
  static const int chunkSizeMedium = 4 * 1024 * 1024;

  /// Small chunk size for files < 1 GB - 1 MB
  static const int chunkSizeSmall = 1024 * 1024;

  /// Threshold for large file chunking (10 GB)
  static const int largeFileThreshold = 10 * 1024 * 1024 * 1024;

  /// Threshold for medium file chunking (1 GB)
  static const int mediumFileThreshold = 1024 * 1024 * 1024;

  /// Active window size (chunks kept in memory per connection)
  static int activeWindowSize = 100;

  /// Chunk timeout in seconds
  static const int chunkTimeoutSeconds = 30;

  /// Max retries per chunk
  static const int maxRetries = 3;

  /// Enable bandwidth throttling by default
  static bool enableBandwidthThrottling = true;

  /// Default max concurrent transfers
  static int maxConcurrentTransfers = 10;

  /// Heartbeat interval
  static const int heartbeatIntervalSeconds = 5;

  /// Heartbeat timeout
  static const int heartbeatTimeoutSeconds = 15;

  /// Max missed heartbeats before disconnect
  static const int maxMissedHeartbeats = 3;

  /// Enable dynamic chunk sizing for large files
  static const bool enableDynamicChunking = true;

  /// Enable streaming hash verification
  static const bool enableStreamingHash = true;

  /// Enable mmap for zero-copy file reads
  static const bool enableMmap = true;

  /// Default download directory for incoming files (relative to app documents)
  static const String defaultDownloadDir = 'ConnectTransfers/Incoming';

  /// File chunk size (configurable at runtime)
  static int fileChunkSize = chunkSizeDefault;

  /// Maximum bytes per second (0 = unlimited)
  static int maxBytesPerSecond = 0;
}