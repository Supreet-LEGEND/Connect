import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connect/app/transfer_config.dart';
import 'package:connect/network/transfer/transfer_controller.dart';

// Settings keys
class _SettingsKeys {
  static const themeMode = 'theme_mode';
  static const maxConcurrentTransfers = 'max_concurrent_transfers';
  static const autoResumeOnStart = 'auto_resume_on_start';
  static const autoAcceptIncoming = 'auto_accept_incoming';
  static const defaultSaveLocation = 'default_save_location';
  static const chunkSize = 'chunk_size';
  static const enableBandwidthThrottling = 'enable_bandwidth_throttling';
  static const maxBytesPerSecond = 'max_bytes_per_second';
}

enum AppThemeMode {
  system,
  light,
  dark,
}

class AppSettings {
  final AppThemeMode themeMode;
  final int maxConcurrentTransfers;
  final bool autoResumeOnStart;
  final bool autoAcceptIncoming;
  final String defaultSaveLocation;
  final int chunkSize;
  final bool enableBandwidthThrottling;
  final int maxBytesPerSecond;

  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.maxConcurrentTransfers = 4,
    this.autoResumeOnStart = true,
    this.autoAcceptIncoming = false,
    this.defaultSaveLocation = '',
    this.chunkSize = 1024 * 1024, // 1 MB default
    this.enableBandwidthThrottling = true,
    this.maxBytesPerSecond = 0, // 0 = unlimited
  });

  AppSettings copyWith({
    AppThemeMode? themeMode,
    int? maxConcurrentTransfers,
    bool? autoResumeOnStart,
    bool? autoAcceptIncoming,
    String? defaultSaveLocation,
    int? chunkSize,
    bool? enableBandwidthThrottling,
    int? maxBytesPerSecond,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      maxConcurrentTransfers: maxConcurrentTransfers ?? this.maxConcurrentTransfers,
      autoResumeOnStart: autoResumeOnStart ?? this.autoResumeOnStart,
      autoAcceptIncoming: autoAcceptIncoming ?? this.autoAcceptIncoming,
      defaultSaveLocation: defaultSaveLocation ?? this.defaultSaveLocation,
      chunkSize: chunkSize ?? this.chunkSize,
      enableBandwidthThrottling: enableBandwidthThrottling ?? this.enableBandwidthThrottling,
      maxBytesPerSecond: maxBytesPerSecond ?? this.maxBytesPerSecond,
    );
  }

  ThemeMode get flutterThemeMode {
    switch (themeMode) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }
}

class SettingsNotifier extends Notifier<AppSettings> {
  TransferController? _transferController;

  void setTransferController(TransferController controller) {
    _transferController = controller;
  }

  @override
  AppSettings build() {
    // Return default settings initially, load async
    _loadSettings();
    return const AppSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final settings = AppSettings(
        themeMode: AppThemeMode.values.byName(
          prefs.getString(_SettingsKeys.themeMode) ?? 'system',
        ),
        maxConcurrentTransfers: prefs.getInt(_SettingsKeys.maxConcurrentTransfers) ?? 4,
        autoResumeOnStart: prefs.getBool(_SettingsKeys.autoResumeOnStart) ?? true,
        autoAcceptIncoming: prefs.getBool(_SettingsKeys.autoAcceptIncoming) ?? false,
        defaultSaveLocation: prefs.getString(_SettingsKeys.defaultSaveLocation) ?? '',
        chunkSize: prefs.getInt(_SettingsKeys.chunkSize) ?? (1024 * 1024),
        enableBandwidthThrottling: prefs.getBool(_SettingsKeys.enableBandwidthThrottling) ?? true,
        maxBytesPerSecond: prefs.getInt(_SettingsKeys.maxBytesPerSecond) ?? 0,
      );
      
      state = settings;
      
      // Apply to TransferConfig
      _applyToTransferConfig(settings);
    } catch (e) {
      // Use defaults on error
      state = const AppSettings();
    }
  }

  void _applyToTransferConfig(AppSettings settings) {
    TransferConfig.maxConcurrentTransfers = settings.maxConcurrentTransfers;
    TransferConfig.fileChunkSize = settings.chunkSize;
    TransferConfig.enableBandwidthThrottling = settings.enableBandwidthThrottling;
    TransferConfig.maxBytesPerSecond = settings.maxBytesPerSecond;
  }

  Future<void> _saveSettings(AppSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      await prefs.setString(_SettingsKeys.themeMode, settings.themeMode.name);
      await prefs.setInt(_SettingsKeys.maxConcurrentTransfers, settings.maxConcurrentTransfers);
      await prefs.setBool(_SettingsKeys.autoResumeOnStart, settings.autoResumeOnStart);
      await prefs.setBool(_SettingsKeys.autoAcceptIncoming, settings.autoAcceptIncoming);
      await prefs.setString(_SettingsKeys.defaultSaveLocation, settings.defaultSaveLocation);
      await prefs.setInt(_SettingsKeys.chunkSize, settings.chunkSize);
      await prefs.setBool(_SettingsKeys.enableBandwidthThrottling, settings.enableBandwidthThrottling);
      await prefs.setInt(_SettingsKeys.maxBytesPerSecond, settings.maxBytesPerSecond);
      
      _applyToTransferConfig(settings);
      _sendConfigToIsolates(settings);
    } catch (e) {
      // Ignore save errors
    }
  }

  void _sendConfigToIsolates(AppSettings settings) {
    _transferController?.sendConfigUpdate(
      chunkSize: settings.chunkSize,
      maxConcurrentTransfers: settings.maxConcurrentTransfers,
      enableBandwidthThrottling: settings.enableBandwidthThrottling,
      maxBytesPerSecond: settings.maxBytesPerSecond,
    );
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    final newSettings = state.copyWith(themeMode: mode);
    state = newSettings;
    await _saveSettings(newSettings);
  }

  Future<void> setMaxConcurrentTransfers(int value) async {
    final clampedValue = value.clamp(1, 10);
    final newSettings = state.copyWith(maxConcurrentTransfers: clampedValue);
    state = newSettings;
    await _saveSettings(newSettings);
  }

  Future<void> setAutoResumeOnStart(bool value) async {
    final newSettings = state.copyWith(autoResumeOnStart: value);
    state = newSettings;
    await _saveSettings(newSettings);
  }

  Future<void> setAutoAcceptIncoming(bool value) async {
    final newSettings = state.copyWith(autoAcceptIncoming: value);
    state = newSettings;
    await _saveSettings(newSettings);
  }

  Future<void> setChunkSize(int value) async {
    final clampedValue = value.clamp(64 * 1024, 10 * 1024 * 1024); // 64KB - 10MB
    final newSettings = state.copyWith(chunkSize: clampedValue);
    state = newSettings;
    await _saveSettings(newSettings);
  }

  Future<void> setBandwidthThrottling(bool enabled, [int maxBytesPerSecond = 0]) async {
    final newSettings = state.copyWith(
      enableBandwidthThrottling: enabled,
      maxBytesPerSecond: enabled ? maxBytesPerSecond : 0,
    );
    state = newSettings;
    await _saveSettings(newSettings);
  }

  Future<void> setDefaultSaveLocation(String path) async {
    final newSettings = state.copyWith(defaultSaveLocation: path);
    state = newSettings;
    await _saveSettings(newSettings);
  }

  Future<void> resetToDefaults() async {
    final defaults = const AppSettings();
    state = defaults;
    await _saveSettings(defaults);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(() => SettingsNotifier());

// Provider for theme mode to use in MaterialApp
final themeModeProvider = Provider<ThemeMode>((ref) {
  return ref.watch(settingsProvider).flutterThemeMode;
});