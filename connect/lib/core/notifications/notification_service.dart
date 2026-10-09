// Cross-platform notification service
// Provides unified API for showing notifications across platforms

import 'dart:async';
import 'dart:io' show Platform, Process;
import 'dart:convert';

/// Notification types
enum NotificationType {
  info,
  success,
  warning,
  error,
  progress,
}

/// Notification data
class Notification {
  final String id;
  final String title;
  final String body;
  final NotificationType type;
  final Map<String, dynamic>? payload;
  final Duration? duration;
  final List<NotificationAction>? actions;

  Notification({
    required this.id,
    required this.title,
    required this.body,
    this.type = NotificationType.info,
    this.payload,
    this.duration,
    this.actions,
  });
}

/// Notification action
class NotificationAction {
  final String id;
  final String title;
  final bool isDestructive;

  NotificationAction({
    required this.id,
    required this.title,
    this.isDestructive = false,
  });
}

/// Callback for notification actions
typedef NotificationActionCallback = void Function(String notificationId, String actionId);

/// Cross-platform notification service
class NotificationService {
  static NotificationService? _instance;
  static NotificationService get instance => _instance ??= NotificationService._();
  
  NotificationService._();
  
  NotificationActionCallback? _onAction;
  final Map<String, _PlatformNotification> _activeNotifications = {};
  
  /// Initialize the notification service
  Future<void> initialize() async {
    if (Platform.isAndroid) {
      // Android uses foreground service notifications (handled by BackgroundTransferService)
    } else if (Platform.isIOS) {
      // iOS uses local notifications (flutter_local_notifications)
      await _initializeIOS();
    } else if (Platform.isWindows) {
      // Windows uses toast notifications
      await _initializeWindows();
    } else if (Platform.isMacOS) {
      // macOS uses NSUserNotification
      await _initializeMacOS();
    } else if (Platform.isLinux) {
      // Linux uses libnotify
      await _initializeLinux();
    }
  }
  
  /// Set callback for notification actions
  void setActionCallback(NotificationActionCallback callback) {
    _onAction = callback;
  }
  
  /// Show a notification
  Future<void> show(Notification notification) async {
    if (Platform.isAndroid) {
      // Android: handled by foreground service
      return;
    } else if (Platform.isIOS) {
      await _showIOS(notification);
    } else if (Platform.isWindows) {
      await _showWindows(notification);
    } else if (Platform.isMacOS) {
      await _showMacOS(notification);
    } else if (Platform.isLinux) {
      await _showLinux(notification);
    }
    
    _activeNotifications[notification.id] = _PlatformNotification(
      notification: notification,
      shownAt: DateTime.now(),
    );
  }
  
  /// Update an existing notification
  Future<void> update(Notification notification) async {
    if (Platform.isAndroid) {
      // Android: update foreground service notification
      return;
    } else if (Platform.isIOS) {
      await _updateIOS(notification);
    } else if (Platform.isWindows) {
      await _updateWindows(notification);
    } else if (Platform.isMacOS) {
      await _updateMacOS(notification);
    } else if (Platform.isLinux) {
      await _updateLinux(notification);
    }
    
    _activeNotifications[notification.id] = _PlatformNotification(
      notification: notification,
      shownAt: DateTime.now(),
    );
  }
  
  /// Hide/remove a notification
  Future<void> hide(String notificationId) async {
    if (Platform.isAndroid) {
      // Android: remove from foreground service
      return;
    } else if (Platform.isIOS) {
      await _hideIOS(notificationId);
    } else if (Platform.isWindows) {
      await _hideWindows(notificationId);
    } else if (Platform.isMacOS) {
      await _hideMacOS(notificationId);
    } else if (Platform.isLinux) {
      await _hideLinux(notificationId);
    }
    
    _activeNotifications.remove(notificationId);
  }
  
  /// Hide all notifications
  Future<void> hideAll() async {
    for (final id in _activeNotifications.keys) {
      await hide(id);
    }
  }
  
  /// Show progress notification for file transfer
  Future<void> showTransferProgress({
    required String transferId,
    required String fileName,
    required double progress, // 0.0 - 1.0
    required int speedBps,
    required String status,
    bool isBackground = false,
  }) async {
    final percentage = (progress * 100).round();
    final speedStr = _formatSpeed(speedBps);
    
    final notification = Notification(
      id: 'transfer_$transferId',
      title: isBackground ? 'Background Transfer' : 'File Transfer',
      body: '$fileName - $percentage% ($speedStr) - $status',
      type: NotificationType.progress,
      payload: {
        'transfer_id': transferId,
        'progress': progress,
        'speed': speedBps,
        'status': status,
      },
      actions: [
        NotificationAction(id: 'pause', title: 'Pause'),
        NotificationAction(id: 'cancel', title: 'Cancel', isDestructive: true),
      ],
    );
    
    await show(notification);
  }
  
  /// Show transfer complete notification
  Future<void> showTransferComplete({
    required String transferId,
    required String fileName,
    required bool success,
    String? error,
  }) async {
    final notification = Notification(
      id: 'transfer_complete_$transferId',
      title: success ? 'Transfer Complete' : 'Transfer Failed',
      body: success 
          ? '$fileName transferred successfully'
          : 'Failed: ${error ?? "Unknown error"}',
      type: success ? NotificationType.success : NotificationType.error,
      payload: {
        'transfer_id': transferId,
        'success': success,
        'error': error,
      },
      duration: const Duration(seconds: 10),
    );
    
    await show(notification);
  }
  
  /// Show connection request notification
  Future<void> showConnectionRequest({
    required String deviceId,
    required String deviceName,
  }) async {
    final notification = Notification(
      id: 'connection_request_$deviceId',
      title: 'Connection Request',
      body: '$deviceName wants to connect',
      type: NotificationType.info,
      payload: {
        'device_id': deviceId,
        'device_name': deviceName,
      },
      actions: [
        NotificationAction(id: 'accept', title: 'Accept'),
        NotificationAction(id: 'deny', title: 'Deny', isDestructive: true),
      ],
    );
    
    await show(notification);
  }
  
  // Platform-specific implementations
  
  Future<void> _initializeIOS() async {
    // Initialize flutter_local_notifications
  }
  
  Future<void> _initializeWindows() async {
    // Initialize windows toast notifications
  }
  
  Future<void> _initializeMacOS() async {
    // Initialize macOS notifications
  }
  
  Future<void> _initializeLinux() async {
    // Initialize libnotify
  }
  
  Future<void> _showIOS(Notification notification) async {
    // Use flutter_local_notifications
  }
  
  Future<void> _updateIOS(Notification notification) async {
    // Update iOS notification
  }
  
  Future<void> _hideIOS(String id) async {
    // Remove iOS notification
  }
  
  Future<void> _showWindows(Notification notification) async {
    // Use windows toast notifications via FFI or platform channel
  }
  
  Future<void> _updateWindows(Notification notification) async {
    // Update Windows toast
  }
  
  Future<void> _hideWindows(String id) async {
    // Hide Windows toast
  }
  
  Future<void> _showMacOS(Notification notification) async {
    // Use macOS UserNotifications framework via platform channel
  }
  
  Future<void> _updateMacOS(Notification notification) async {
    // Update macOS notification
  }
  
  Future<void> _hideMacOS(String id) async {
    // Hide macOS notification
  }
  
  Future<void> _showLinux(Notification notification) async {
    // Use libnotify / notify-send
    try {
      final args = ['notify-send'];
      
      if (notification.duration != null) {
        args.addAll(['-t', notification.duration!.inMilliseconds.toString()]);
      }
      
      args.add(notification.title);
      args.add(notification.body);
      
      await Process.run('notify-send', args);
    } catch (e) {
      // notify-send not available
    }
  }
  
  Future<void> _updateLinux(Notification notification) async {
    // Update Linux notification
  }
  
  Future<void> _hideLinux(String id) async {
    // Hide Linux notification
  }
  
  String _formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond} B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
  }
}

class _PlatformNotification {
  final Notification notification;
  final DateTime shownAt;
  
  _PlatformNotification({
    required this.notification,
    required this.shownAt,
  });
}

/// Platform-specific notification implementations
/// These would be implemented in separate platform-specific files

/// Windows: Uses ToastNotificationManager via FFI
class WindowsNotificationService {
  static Future<void> showToast({
    required String title,
    required String body,
    String? iconPath,
    Duration? duration,
    List<NotificationAction>? actions,
  }) async {
    // Implementation using windows-ffi or platform channel
  }
  
  static Future<void> hideToast(String id) async {
    // Hide specific toast
  }
}

/// macOS: Uses UserNotifications framework
class MacOSNotificationService {
  static Future<void> showNotification({
    required String title,
    required String body,
    String? subtitle,
    String? identifier,
    List<NotificationAction>? actions,
  }) async {
    // Implementation via platform channel to Swift
  }
  
  static Future<void> hideNotification(String identifier) async {
    // Remove notification
  }
}

/// Linux: Uses libnotify / notify-send
class LinuxNotificationService {
  static Future<void> showNotification({
    required String title,
    required String body,
    String? icon,
    int? timeoutMs,
    List<NotificationAction>? actions,
  }) async {
    final args = ['notify-send'];
    
    if (timeoutMs != null) {
      args.addAll(['-t', timeoutMs.toString()]);
    }
    
    if (icon != null) {
      args.addAll(['-i', icon]);
    }
    
    args.add(title);
    args.add(body);
    
    try {
      await Process.run('notify-send', args);
    } catch (e) {
      // notify-send not available
    }
  }
  
  static Future<void> updateNotification(String id, String title, String body) async {
    // notify-send with --replace-id
  }
  
  static Future<void> hideNotification(String id) async {
    // notify-send --close
  }
}

/// iOS: Uses flutter_local_notifications
// Implementation in Dart using flutter_local_notifications plugin