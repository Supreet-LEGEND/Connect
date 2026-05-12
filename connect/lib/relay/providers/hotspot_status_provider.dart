import 'dart:io';
import 'package:connect/core/hardware_connection_status/hotspot_connection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

// provider to get hotspot status
final hotspotStatusProvider = FutureProvider.autoDispose<bool?>((ref) async {
  return await HotspotNative.isHotspotEnabled();
});

// provider to open hotspot settings
final hotspotSettingsOpenerProvider = FutureProvider.autoDispose<bool?>((
  ref,
) async {
  return await HotspotNative.openHotspotSettings();
});

// should we show the hotspot status widget
class ShouldShowHotspotStatusWidgetNotifier extends StateNotifier<bool> {
  ShouldShowHotspotStatusWidgetNotifier() : super(false);

  void setShouldShow(bool value) {
    state = value;
  }

  void toggle() {
    state = !state;
  }

  void showIfAndroidOrIos() {
    if (Platform.isAndroid || Platform.isIOS) {
      state = true;
    } else {
      state = false;
    }
  }

  void showIfHotspotOff() async {
    final isHotspotOn = await HotspotNative.isHotspotEnabled();
    state = !isHotspotOn!;
  }
}

final shouldShowHotspotStatusWidgetProvider =
    StateNotifierProvider.autoDispose<
      ShouldShowHotspotStatusWidgetNotifier,
      bool
    >((ref) {
      return ShouldShowHotspotStatusWidgetNotifier();
    });
