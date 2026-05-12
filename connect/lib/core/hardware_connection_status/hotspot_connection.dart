import 'dart:io';

import 'package:flutter/material.dart' show debugPrint;
import 'package:flutter/services.dart';

class HotspotNative {
  static const MethodChannel _channel = MethodChannel('hotspot_status');

  /// Call native to open hotspot settings (system UI).
  static Future<bool?> openHotspotSettings() async {
    if (Platform.isAndroid) {
      try {
        final res = await _channel.invokeMethod<bool>('openHotspotSettings');
        return res ?? false;
      } on PlatformException catch (e) {
        debugPrint('openHotspotSettings error: $e');
        return false;
      }
    }
    return null;
  }

  /// Query native if hotspot/AP is enabled.
  static Future<bool?> isHotspotEnabled() async {
    if (Platform.isAndroid) {
      try {
        final res = await _channel.invokeMethod<bool>('isHotspotEnabled');
        return res ?? false;
      } on PlatformException catch (e) {
        debugPrint('isHotspotEnabled error: $e');
        return false;
      }
    }
    return null;
  }
}
