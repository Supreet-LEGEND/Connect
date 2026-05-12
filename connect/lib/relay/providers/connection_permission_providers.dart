import 'package:connect/relay/permission_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final isWifiPermissionGrantedProvider = FutureProvider.autoDispose<bool>((
  ref,
) async {
  return PermissionManager.isWifiPermissionGranted();
});
