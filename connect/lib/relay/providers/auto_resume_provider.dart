// Auto-resume settings provider and logic
// Manages user preferences for auto-resuming transfers

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connect/network/storage/database_helper.dart';
import 'package:connect/network/transfer/background_transfer_controller.dart';
import 'package:connect/relay/providers/transfer_providers.dart';

/// Auto-resume configuration
class AutoResumeConfig {
  final bool enabled;
  final bool wifiOnly;
  final bool chargingOnly;
  final int maxConcurrentTransfers;
  final bool notifyOnComplete;
  final bool notifyOnError;
  
  const AutoResumeConfig({
    this.enabled = true,
    this.wifiOnly = true,
    this.chargingOnly = false,
    this.maxConcurrentTransfers = 3,
    this.notifyOnComplete = true,
    this.notifyOnError = true,
  });
  
  AutoResumeConfig copyWith({
    bool? enabled,
    bool? wifiOnly,
    bool? chargingOnly,
    int? maxConcurrentTransfers,
    bool? notifyOnComplete,
    bool? notifyOnError,
  }) {
    return AutoResumeConfig(
      enabled: enabled ?? this.enabled,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      chargingOnly: chargingOnly ?? this.chargingOnly,
      maxConcurrentTransfers: maxConcurrentTransfers ?? this.maxConcurrentTransfers,
      notifyOnComplete: notifyOnComplete ?? this.notifyOnComplete,
      notifyOnError: notifyOnError ?? this.notifyOnError,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'wifiOnly': wifiOnly,
    'chargingOnly': chargingOnly,
    'maxConcurrentTransfers': maxConcurrentTransfers,
    'notifyOnComplete': notifyOnComplete,
    'notifyOnError': notifyOnError,
  };
  
  factory AutoResumeConfig.fromJson(Map<String, dynamic> json) => AutoResumeConfig(
    enabled: json['enabled'] ?? true,
    wifiOnly: json['wifiOnly'] ?? true,
    chargingOnly: json['chargingOnly'] ?? false,
    maxConcurrentTransfers: json['maxConcurrentTransfers'] ?? 3,
    notifyOnComplete: json['notifyOnComplete'] ?? true,
    notifyOnError: json['notifyOnError'] ?? true,
  );
}

/// Auto-resume settings notifier
class AutoResumeConfigNotifier extends Notifier<AutoResumeConfig> {
  static const _prefsKey = 'auto_resume_config';
  
  @override
  AutoResumeConfig build() {
    _loadConfig();
    return const AutoResumeConfig();
  }
  
  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_prefsKey);
    if (json != null) {
      state = AutoResumeConfig.fromJson(jsonDecode(json));
    }
  }
  
  Future<void> updateConfig(AutoResumeConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(config.toJson()));
    state = config;
  }
  
  Future<void> setEnabled(bool enabled) async {
    await updateConfig(state.copyWith(enabled: enabled));
  }
  
  Future<void> setWifiOnly(bool wifiOnly) async {
    await updateConfig(state.copyWith(wifiOnly: wifiOnly));
  }
  
  Future<void> setChargingOnly(bool chargingOnly) async {
    await updateConfig(state.copyWith(chargingOnly: chargingOnly));
  }
  
  Future<void> setMaxConcurrentTransfers(int count) async {
    await updateConfig(state.copyWith(maxConcurrentTransfers: count.clamp(1, 10)));
  }
  
  Future<void> setNotifyOnComplete(bool notify) async {
    await updateConfig(state.copyWith(notifyOnComplete: notify));
  }
  
  Future<void> setNotifyOnError(bool notify) async {
    await updateConfig(state.copyWith(notifyOnError: notify));
  }
}

/// Auto-resume settings provider
final autoResumeConfigProvider = NotifierProvider<AutoResumeConfigNotifier, AutoResumeConfig>(() {
  return AutoResumeConfigNotifier();
});

/// Auto-resume manager - handles checking and resuming incomplete transfers
class AutoResumeManager {
  final AutoResumeConfig _config;
  final BackgroundTransferController _controller;
  
  Timer? _checkTimer;
  bool _isRunning = false;
  bool _isChecking = false;
  
  AutoResumeManager({
    required AutoResumeConfig config,
    required BackgroundTransferController controller,
  }) : _config = config, _controller = controller;
  
  /// Start periodic checks for incomplete transfers
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    
    // Initial check
    _checkAndResume();
    
    // Periodic check every 5 minutes
    _checkTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _checkAndResume();
    });
  }
  
  void stop() {
    _isRunning = false;
    _checkTimer?.cancel();
    _checkTimer = null;
  }
  
  Future<void> _checkAndResume() async {
    if (!_config.enabled) return;
    if (_isChecking) return;
    
    _isChecking = true;
    
    try {
      // Check network conditions
      if (_config.wifiOnly) {
        final isWifi = await _isConnectedToWifi();
        if (!isWifi) {
          debugPrint('Auto-resume: Not on WiFi, skipping');
          return;
        }
      }
      
      if (_config.chargingOnly) {
        final isCharging = await _isDeviceCharging();
        if (!isCharging) {
          debugPrint('Auto-resume: Not charging, skipping');
          return;
        }
      }
      
      // Get incomplete transfers from database
      final db = await DatabaseHelper.instance.init();
      final incomplete = await db.query(
        'outgoing_progress',
        where: 'status IN (?, ?)',
        whereArgs: ['in_progress', 'paused'],
      );
      
      debugPrint('Auto-resume: Found ${incomplete.length} incomplete transfers');
      
      // Filter by max concurrent
      final toResume = incomplete.take(_config.maxConcurrentTransfers).toList();
      
      for (final transfer in toResume) {
        await _resumeTransfer(transfer);
      }
    } catch (e) {
      debugPrint('Auto-resume error: $e');
    } finally {
      _isChecking = false;
    }
  }
  
  Future<bool> _isConnectedToWifi() async {
    // Platform-specific implementation
    if (Platform.isAndroid) {
      // Use connectivity_plus or platform channel
      return true; // Placeholder
    }
    return true;
  }
  
  Future<bool> _isDeviceCharging() async {
    // Platform-specific implementation
    return true; // Placeholder
  }
  
  Future<void> _resumeTransfer(Map<String, dynamic> transfer) async {
    final transferId = transfer['transfer_id'] as String;
    final deviceId = transfer['device_id'] as String;
    final filePath = transfer['file_path'] as String;
    final fileSize = transfer['total_bytes'] as int;
    final fileName = transfer['file_name'] as String? ?? 'unknown';
    
    debugPrint('Auto-resuming transfer: $transferId');
    
    try {
      await _controller.startBackgroundTransfer(
        transferId: transferId,
        deviceId: deviceId,
        filePath: filePath,
        fileSize: fileSize,
        fileName: fileName,
      );
      
      // Update status in database
      final db = await DatabaseHelper.instance.init();
      await db.update(
        'outgoing_progress',
        {'status': 'in_progress'},
        where: 'transfer_id = ?',
        whereArgs: [transferId],
      );
    } catch (e) {
      debugPrint('Failed to auto-resume $transferId: $e');
    }
  }
}

/// Provider for auto-resume manager
final autoResumeManagerProvider = Provider<AutoResumeManager>((ref) {
  final config = ref.watch(autoResumeConfigProvider);
  final controller = ref.watch(backgroundTransferControllerProvider);
  return AutoResumeManager(
    config: config,
    controller: controller,
  );
});

/// Watch auto-resume config changes and start/stop manager
final autoResumeManagerStateProvider = Provider<AutoResumeManager>((ref) {
  final manager = ref.watch(autoResumeManagerProvider);
  final config = ref.watch(autoResumeConfigProvider);
  
  // Start/stop based on config
  ref.listen<AutoResumeConfig>(autoResumeConfigProvider, (prev, next) {
    if (prev?.enabled != next.enabled) {
      if (next.enabled) {
        manager.start();
      } else {
        manager.stop();
      }
    }
  });
  
  return manager;
});