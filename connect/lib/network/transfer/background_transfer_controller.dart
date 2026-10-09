// Cross-platform background transfer controller
// Uses platform-specific implementations for background transfers

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:connect/network/storage/database_helper.dart';
import 'package:connect/network/transfer/background_transfer_controller.dart';
import 'package:connect/app/transfer_config.dart';
import 'package:connect/app/tcp_config.dart';
import 'package:path_provider/path_provider.dart';

/// Platform-specific background transfer controller interface
abstract class BackgroundTransferController {
  /// Initialize the background transfer system
  Future<void> initialize();
  
  /// Start a background transfer
  Future<bool> startBackgroundTransfer({
    required String transferId,
    required String deviceId,
    required String filePath,
    required int fileSize,
    required String fileName,
  });
  
  /// Pause a background transfer
  Future<bool> pauseBackgroundTransfer(String transferId);
  
  /// Resume a background transfer
  Future<bool> resumeBackgroundTransfer(String transferId);
  
  /// Cancel a background transfer
  Future<bool> cancelBackgroundTransfer(String transferId);
  
  /// Get all active transfers from background service
  Future<List<BackgroundTransferInfo>> getActiveTransfers();
  
  /// Register for progress notifications
  Future<void> registerForNotifications({
    required String transferId,
    required String fileName,
    required int totalSize,
    required Function(BackgroundTransferProgress) onProgress,
    required Function(BackgroundTransferResult) onComplete,
  });
  
  /// Unregister from notifications
  Future<void> unregisterFromNotifications(String transferId);
  
  /// Notify background service of app foreground/background state
  Future<void> setAppInForeground(bool inForeground);
  
  /// Shutdown the background transfer system
  Future<void> shutdown();
  
  /// Check if background transfers are supported on this platform
  bool get isSupported;
}

/// Information about a background transfer
class BackgroundTransferInfo {
  final String transferId;
  final String deviceId;
  final String fileName;
  final int totalBytes;
  final int transferredBytes;
  final String status;
  final int speedBps;
  final bool isBackground;

  BackgroundTransferInfo({
    required this.transferId,
    required this.deviceId,
    required this.fileName,
    required this.totalBytes,
    required this.transferredBytes,
    required this.status,
    required this.speedBps,
    this.isBackground = false,
  });

  factory BackgroundTransferInfo.fromMap(Map<String, dynamic> map) {
    return BackgroundTransferInfo(
      transferId: map['transfer_id'] ?? map['transferId'] ?? '',
      deviceId: map['device_id'] ?? map['deviceId'] ?? '',
      fileName: map['file_name'] ?? map['fileName'] ?? '',
      totalBytes: map['total_bytes'] ?? map['totalBytes'] ?? 0,
      transferredBytes: map['transferred_bytes'] ?? map['transferredBytes'] ?? 0,
      status: map['status'] ?? 'unknown',
      speedBps: map['speed_bps'] ?? map['speedBps'] ?? 0,
      isBackground: map['is_background'] ?? map['isBackground'] ?? false,
    );
  }

  double get progress => totalBytes > 0 ? transferredBytes / totalBytes : 0.0;
}

/// Progress callback for background transfers
class BackgroundTransferProgress {
  final String transferId;
  final int progress; // 0-100
  final int speedBps;
  final String status;
  final int transferredBytes;
  final int totalBytes;

  BackgroundTransferProgress({
    required this.transferId,
    required this.progress,
    required this.speedBps,
    required this.status,
    required this.transferredBytes,
    required this.totalBytes,
  });
}

/// Result of a completed background transfer
class BackgroundTransferResult {
  final String transferId;
  final bool success;
  final String? error;
  final String? filePath;

  BackgroundTransferResult({
    required this.transferId,
    required this.success,
    this.error,
    this.filePath,
  });
}

/// Android implementation using Foreground Service
class AndroidBackgroundTransferController implements BackgroundTransferController {
  static const String _controlChannelName = 'connect/transfer_control';
  static const String _notificationChannelName = 'connect/transfer_notifications';
  
  late final MethodChannel _controlChannel;
  late final MethodChannel _notificationChannel;
  
  final Map<String, _TransferCallbacks> _callbacks = {};
  
  @override
  Future<void> initialize() async {
    _controlChannel = const MethodChannel(_controlChannelName);
    _notificationChannel = const MethodChannel(_notificationChannelName);
    
    // Set up method call handler for notifications
    _notificationChannel.setMethodCallHandler(_handleNotificationCall);
  }
  
  @override
  Future<bool> startBackgroundTransfer({
    required String transferId,
    required String deviceId,
    required String filePath,
    required int fileSize,
    required String fileName,
  }) async {
    try {
      await _controlChannel.invokeMethod('startBackgroundTransfer', {
        'transferId': transferId,
        'deviceId': deviceId,
        'filePath': filePath,
        'fileSize': fileSize,
        'fileName': fileName,
      });
      return true;
    } catch (e) {
      debugPrint('Failed to start background transfer: $e');
      return false;
    }
  }
  
  @override
  Future<bool> pauseBackgroundTransfer(String transferId) async {
    try {
      await _controlChannel.invokeMethod('pauseBackgroundTransfer', {
        'transferId': transferId,
      });
      return true;
    } catch (e) {
      return false;
    }
  }
  
  @override
  Future<bool> resumeBackgroundTransfer(String transferId) async {
    try {
      await _controlChannel.invokeMethod('resumeBackgroundTransfer', {
        'transferId': transferId,
      });
      return true;
    } catch (e) {
      return false;
    }
  }
  
  @override
  Future<bool> cancelBackgroundTransfer(String transferId) async {
    try {
      await _controlChannel.invokeMethod('cancelBackgroundTransfer', {
        'transferId': transferId,
      });
      return true;
    } catch (e) {
      return false;
    }
  }
  
  @override
  Future<List<BackgroundTransferInfo>> getActiveTransfers() async {
    try {
      final result = await _controlChannel.invokeMethod('getActiveTransfers');
      if (result is Map) {
        return result.entries.map((e) => BackgroundTransferInfo.fromMap(
          Map<String, dynamic>.from(e.value),
        )).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }
  
  @override
  Future<void> registerForNotifications({
    required String transferId,
    required String fileName,
    required int totalSize,
    required Function(BackgroundTransferProgress) onProgress,
    required Function(BackgroundTransferResult) onComplete,
  }) async {
    _callbacks[transferId] = _TransferCallbacks(
      onProgress: onProgress,
      onComplete: onComplete,
    );
    
    await _notificationChannel.invokeMethod('registerTransfer', {
      'transferId': transferId,
      'fileName': fileName,
      'totalSize': totalSize,
    });
  }
  
  @override
  Future<void> unregisterFromNotifications(String transferId) async {
    _callbacks.remove(transferId);
    await _notificationChannel.invokeMethod('unregisterTransfer', {
      'transferId': transferId,
    });
  }
  
  @override
  Future<void> setAppInForeground(bool inForeground) async {
    await _notificationChannel.invokeMethod('setAppInForeground', {
      'inForeground': inForeground,
    });
  }
  
  @override
  Future<void> shutdown() async {
    _callbacks.clear();
  }
  
  @override
  bool get isSupported => Platform.isAndroid;
  
  Future<dynamic> _handleNotificationCall(MethodCall call) async {
    final args = call.arguments as Map<dynamic, dynamic>?;
    if (args == null) return;
    
    switch (call.method) {
      case 'updateTransferProgress':
        final transferId = args['transferId'] as String?;
        final progress = args['progress'] as int? ?? 0;
        final speed = args['speed'] as int? ?? 0;
        final totalSize = args['totalSize'] as int? ?? 0;
        
        final callback = _callbacks[transferId];
        if (callback != null) {
          callback.onProgress(BackgroundTransferProgress(
            transferId: transferId!,
            progress: progress,
            speedBps: speed,
            status: 'transferring',
            transferredBytes: (totalSize * progress / 100).round(),
            totalBytes: totalSize,
          ));
        }
        break;
      case 'transferComplete':
        final transferId = args['transferId'] as String?;
        final success = args['success'] as bool? ?? false;
        final error = args['error'] as String?;
        final filePath = args['filePath'] as String?;
        
        final callback = _callbacks.remove(transferId);
        if (callback != null) {
          callback.onComplete(BackgroundTransferResult(
            transferId: transferId!,
            success: success,
            error: error,
            filePath: filePath,
          ));
        }
        break;
    }
  }
}

class _TransferCallbacks {
  final Function(BackgroundTransferProgress) onProgress;
  final Function(BackgroundTransferResult) onComplete;
  
  _TransferCallbacks({
    required this.onProgress,
    required this.onComplete,
  });
}

/// iOS implementation using BGProcessingTask
class IOSBackgroundTransferController implements BackgroundTransferController {
  static const String _channelName = 'connect/transfer_control';
  
  late final MethodChannel _channel;
  
  @override
  Future<void> initialize() async {
    _channel = const MethodChannel(_channelName);
  }
  
  @override
  Future<bool> startBackgroundTransfer({
    required String transferId,
    required String deviceId,
    required String filePath,
    required int fileSize,
    required String fileName,
  }) async {
    // iOS doesn't support true background transfers for custom protocols
    // Transfers run in foreground only
    debugPrint('iOS: Transfers run in foreground only');
    return false;
  }
  
  @override
  Future<bool> pauseBackgroundTransfer(String transferId) async {
    return false;
  }
  
  @override
  Future<bool> resumeBackgroundTransfer(String transferId) async {
    return false;
  }
  
  @override
  Future<bool> cancelBackgroundTransfer(String transferId) async {
    return false;
  }
  
  @override
  Future<List<BackgroundTransferInfo>> getActiveTransfers() async {
    try {
      final result = await _channel.invokeMethod('getActiveTransfers');
      if (result is List) {
        return result.map((e) => BackgroundTransferInfo.fromMap(
          Map<String, dynamic>.from(e),
        )).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }
  
  @override
  Future<void> registerForNotifications({
    required String transferId,
    required String fileName,
    required int totalSize,
    required Function(BackgroundTransferProgress) onProgress,
    required Function(BackgroundTransferResult) onComplete,
  }) async {
    // iOS uses local notifications for progress updates
    // Handled by Flutter local notifications plugin
  }
  
  @override
  Future<void> unregisterFromNotifications(String transferId) async {
    // Handled by Flutter local notifications plugin
  }
  
  @override
  Future<void> setAppInForeground(bool inForeground) async {
    // Notify iOS of app state for background task scheduling
    if (!inForeground) {
      // App went to background - schedule checkpoint
      // This is handled by AppDelegate
    }
  }
  
  @override
  Future<void> shutdown() async {
    // Nothing to do for iOS
  }
  
  @override
  bool get isSupported => Platform.isIOS;
}

/// Desktop implementation using native background services
class DesktopBackgroundTransferController implements BackgroundTransferController {
  NamedPipeClient? _pipeClient;
  final Map<String, _TransferCallbacks> _callbacks = {};
  StreamController<BackgroundTransferProgress>? _progressController;
  StreamController<BackgroundTransferResult>? _resultController;
  Timer? _pollTimer;
  
  @override
  Future<void> initialize() async {
    _progressController = StreamController<BackgroundTransferProgress>.broadcast();
    _resultController = StreamController<BackgroundTransferResult>.broadcast();
    
    await _connectToBackgroundService();
    
    // Listen for progress updates from background service
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollForUpdates();
    });
  }
  
  Future<void> _connectToBackgroundService() async {
    if (Platform.isWindows) {
      _pipeClient = NamedPipeClient(r'\\.\pipe\connect_transfer');
    } else {
      _pipeClient = NamedPipeClient('/var/run/connect_transfer.sock');
    }
    
    try {
      await _pipeClient!.connect();
    } catch (e) {
      debugPrint('Failed to connect to background service: $e');
    }
  }
  
  Future<void> _pollForUpdates() async {
    if (_pipeClient == null) return;
    
    try {
      final response = await _pipeClient!.send(IpcMessage(
        type: 'get_all_transfers',
        payload: jsonEncode({}),
      ));
      
      if (response.type == 'transfer_list') {
        final data = jsonDecode(response.payload);
        final transfers = (data['transfers'] as List).map((e) => 
          BackgroundTransferInfo.fromMap(Map<String, dynamic>.from(e))
        ).toList();
        
        // Notify callbacks
        for (final transfer in transfers) {
          final callback = _callbacks[transfer.transferId];
          if (callback != null) {
            callback.onProgress(BackgroundTransferProgress(
              transferId: transfer.transferId,
              progress: (transfer.progress * 100).round(),
              speedBps: transfer.speedBps,
              status: transfer.status,
              transferredBytes: transfer.transferredBytes,
              totalBytes: transfer.totalBytes,
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('Error polling for updates: $e');
    }
  }
  
  @override
  Future<bool> startBackgroundTransfer({
    required String transferId,
    required String deviceId,
    required String filePath,
    required int fileSize,
    required String fileName,
  }) async {
    if (_pipeClient == null) return false;
    
    try {
      await _pipeClient!.send(IpcMessage(
        type: 'start_transfer',
        payload: jsonEncode({
          'transfer_id': transferId,
          'device_id': deviceId,
          'file_path': filePath,
          'file_size': fileSize,
          'file_name': fileName,
        }),
      ));
      return true;
    } catch (e) {
      debugPrint('Failed to start background transfer: $e');
      return false;
    }
  }
  
  @override
  Future<bool> pauseBackgroundTransfer(String transferId) async {
    if (_pipeClient == null) return false;
    
    try {
      await _pipeClient!.send(IpcMessage(
        type: 'pause_transfer',
        payload: jsonEncode({'transfer_id': transferId}),
      ));
      return true;
    } catch (e) {
      return false;
    }
  }
  
  @override
  Future<bool> resumeBackgroundTransfer(String transferId) async {
    if (_pipeClient == null) return false;
    
    try {
      await _pipeClient!.send(IpcMessage(
        type: 'resume_transfer',
        payload: jsonEncode({'transfer_id': transferId}),
      ));
      return true;
    } catch (e) {
      return false;
    }
  }
  
  @override
  Future<bool> cancelBackgroundTransfer(String transferId) async {
    if (_pipeClient == null) return false;
    
    try {
      await _pipeClient!.send(IpcMessage(
        type: 'cancel_transfer',
        payload: jsonEncode({'transfer_id': transferId}),
      ));
      return true;
    } catch (e) {
      return false;
    }
  }
  
  @override
  Future<List<BackgroundTransferInfo>> getActiveTransfers() async {
    if (_pipeClient == null) return [];
    
    try {
      final response = await _pipeClient!.send(IpcMessage(
        type: 'get_all_transfers',
        payload: jsonEncode({}),
      ));
      
      if (response.type == 'transfer_list') {
        final data = jsonDecode(response.payload);
        return (data['transfers'] as List).map((e) => 
          BackgroundTransferInfo.fromMap(Map<String, dynamic>.from(e))
        ).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }
  
  @override
  Future<void> registerForNotifications({
    required String transferId,
    required String fileName,
    required int totalSize,
    required Function(BackgroundTransferProgress) onProgress,
    required Function(BackgroundTransferResult) onComplete,
  }) async {
    _callbacks[transferId] = _TransferCallbacks(
      onProgress: onProgress,
      onComplete: onComplete,
    );
    
    if (_pipeClient != null) {
      await _pipeClient!.send(IpcMessage(
        type: 'register_notifications',
        payload: jsonEncode({
          'transfer_id': transferId,
          'file_name': fileName,
          'total_size': totalSize,
        }),
      ));
    }
  }
  
  @override
  Future<void> unregisterFromNotifications(String transferId) async {
    _callbacks.remove(transferId);
    
    if (_pipeClient != null) {
      await _pipeClient!.send(IpcMessage(
        type: 'unregister_notifications',
        payload: jsonEncode({'transfer_id': transferId}),
      ));
    }
  }
  
  @override
  Future<void> setAppInForeground(bool inForeground) async {
    if (_pipeClient != null) {
      await _pipeClient!.send(IpcMessage(
        type: 'app_in_foreground',
        payload: jsonEncode({'in_foreground': inForeground}),
      ));
    }
  }
  
  @override
  Future<void> shutdown() async {
    _callbacks.clear();
    _pollTimer?.cancel();
    await _pipeClient?.disconnect();
    _pipeClient = null;
    await _progressController?.close();
    await _resultController?.close();
  }
  
  @override
  bool get isSupported => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// Named pipe client for Windows/Linux/macOS
class NamedPipeClient {
  final String pipePath;
  bool _connected = false;
  
  NamedPipeClient(this.pipePath);
  
  Future<void> connect() async {
    // Implementation depends on platform
    // Windows: named pipe
    // Linux/macOS: Unix domain socket
    _connected = true;
  }
  
  Future<IpcResponse> send(IpcMessage message) async {
    if (!_connected) {
      throw StateError('Not connected');
    }
    // Simulate response for now - real implementation would communicate via named pipe/socket
    switch (message.type) {
      case 'get_all_transfers':
        return IpcResponse(
          type: 'transfer_list',
          payload: jsonEncode({'transfers': []}),
        );
      case 'start_transfer':
        return IpcResponse(type: 'success', payload: jsonEncode({}));
      case 'pause_transfer':
        return IpcResponse(type: 'success', payload: jsonEncode({}));
      case 'resume_transfer':
        return IpcResponse(type: 'success', payload: jsonEncode({}));
      case 'cancel_transfer':
        return IpcResponse(type: 'success', payload: jsonEncode({}));
      case 'register_notifications':
        return IpcResponse(type: 'success', payload: jsonEncode({}));
      case 'unregister_notifications':
        return IpcResponse(type: 'success', payload: jsonEncode({}));
      case 'app_in_foreground':
        return IpcResponse(type: 'success', payload: jsonEncode({}));
      default:
        return IpcResponse(type: 'error', payload: jsonEncode({'message': 'Unknown message type'}));
    }
  }
  
  Future<void> disconnect() async {
    _connected = false;
  }
}

class IpcMessage {
  final String type;
  final String payload;
  
  IpcMessage({required this.type, required this.payload});
  
  Map<String, dynamic> toJson() => {
    'type': type,
    'payload': payload,
  };
  
  factory IpcMessage.fromJson(Map<String, dynamic> json) {
    return IpcMessage(
      type: json['type'] as String,
      payload: json['payload'] as String,
    );
  }
}

class IpcResponse {
  final String type;
  final String payload;
  
  IpcResponse({required this.type, required this.payload});
  
  Map<String, dynamic> toJson() => {
    'type': type,
    'payload': payload,
  };
  
  factory IpcResponse.fromJson(Map<String, dynamic> json) {
    return IpcResponse(
      type: json['type'] as String,
      payload: json['payload'] as String,
    );
  }
}

/// Factory to get the appropriate platform implementation
BackgroundTransferController createBackgroundTransferController() {
  if (Platform.isAndroid) {
    return AndroidBackgroundTransferController();
  } else if (Platform.isIOS) {
    return IOSBackgroundTransferController();
  } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    return DesktopBackgroundTransferController();
  }
  throw UnsupportedError('Platform not supported for background transfers');
}