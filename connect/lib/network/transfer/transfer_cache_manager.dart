import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TransferCacheManager {
  final Directory progressDir;
  final Duration maxAge;
  final int maxSizeBytes;

  Timer? _cleanupTimer;

  TransferCacheManager({
    required this.progressDir,
    this.maxAge = const Duration(days: 7),
    this.maxSizeBytes = 1024 * 1024 * 1024, // 1 GB
  });

  Future<void> start({Duration interval = const Duration(hours: 1)}) async {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(interval, (_) => cleanup());
    // Run initial cleanup
    await cleanup();
  }

  Future<void> cleanup() async {
    if (!await progressDir.exists()) return;

    final now = DateTime.now();
    final files = progressDir.listSync().whereType<File>().where((f) => f.path.endsWith('.progress'));

    final fileInfos = <_FileInfo>[];

    for (final file in files) {
      try {
        final stat = await file.stat();
        final jsonStr = await file.readAsString();
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final lastUpdatedStr = data['lastUpdated'] as String?;
        final lastUpdated = lastUpdatedStr != null ? DateTime.parse(lastUpdatedStr) : stat.modified;
        
        fileInfos.add(_FileInfo(
          file: file,
          size: stat.size,
          lastUpdated: lastUpdated,
          transferId: data['transferId'] as String?,
        ));
      } catch (e) {
        // Skip corrupted files
        try {
          await file.delete();
        } catch (_) {}
      }
    }

    // Sort by last updated (oldest first)
    fileInfos.sort((a, b) => a.lastUpdated.compareTo(b.lastUpdated));

    // Remove by age
    for (final info in fileInfos) {
      if (now.difference(info.lastUpdated) > maxAge) {
        await _deleteTransferFiles(info.transferId);
      }
    }

    // Remove by size (keep under maxSizeBytes)
    int currentSize = fileInfos.fold(0, (sum, info) => sum + info.size);
    for (final info in fileInfos) {
      if (currentSize <= maxSizeBytes) break;
      await _deleteTransferFiles(info.transferId);
      currentSize -= info.size;
    }
  }

  Future<void> _deleteTransferFiles(String? transferId) async {
    if (transferId == null) return;
    
    final progressFile = File('${progressDir.path}/$transferId.progress');

    try {
      if (await progressFile.exists()) {
        await progressFile.delete();
      }
      
      // Find and delete .part files
      final partFiles = progressDir.parent.listSync().whereType<File>().where((f) => f.path.contains(transferId));
      for (final file in partFiles) {
        await file.delete();
      }
    } catch (e) {
      // Ignore errors
    }
  }

  void stop() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  void dispose() {
    stop();
  }
}

class _FileInfo {
  final File file;
  final int size;
  final DateTime lastUpdated;
  final String? transferId;

  _FileInfo({
    required this.file,
    required this.size,
    required this.lastUpdated,
    required this.transferId,
  });
}