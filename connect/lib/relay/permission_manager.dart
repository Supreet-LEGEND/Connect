import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';

class PermissionManager {
  // Request a single permission
  static Future<PermissionStatus> requestPermission(
    Permission permission,
  ) async {
    // Check current status
    PermissionStatus status = await permission.status;

    if (status.isGranted) return status;

    // Request permission
    status = await permission.request();

    // If permanently denied, open app settings
    if (status.isPermanentlyDenied) {
      await openAppSettings();
    }
    return status;
  }

  // Request multiple permissions
  static Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    Map<Permission, PermissionStatus> results = {};

    for (var p in permissions) {
      results[p] = await requestPermission(p);
    }

    return results;
  }

  // Check if a single permission is granted
  static Future<bool> isGranted(Permission permission) async {
    return await permission.status.isGranted;
  }

  // Check if ALL permissions in list are granted
  static Future<bool> areAllGranted(List<Permission> permissions) async {
    for (var p in permissions) {
      if (!await isGranted(p)) return false;
    }
    return true;
  }

  // Ensures a permission is granted (returns bool)
  static Future<bool> ensure(Permission permission) async {
    final status = await requestPermission(permission);
    return status.isGranted;
  }

  // Ensures multiple permissions are granted (returns bool)
  static Future<bool> ensureAll(List<Permission> permissions) async {
    final res = await requestPermissions(permissions);
    return res.values.every((s) => s.isGranted);
  }

  // ----------------------------
  // GPS / LOCATION SERVICE LOGIC
  // ----------------------------

  /// Checks whether GPS (Location Services) is enabled.
  static Future<bool> isGpsEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  /// Request user to turn ON GPS by opening settings
  static Future<void> openGpsSettings() async {
    await Geolocator.openLocationSettings();
  }

  /// Ensures both LOCATION permission + GPS enabled.
  static Future<bool> ensureLocationReady() async {
    // Step 1: Request Location Permission
    final hasPermission = await ensure(Permission.location);

    if (!hasPermission) {
      return false;
    }

    // Step 2: Check if GPS (Location Services) is ON
    final gpsOn = await isGpsEnabled();
    if (!gpsOn) {
      await openGpsSettings();
      return false;
    }

    return true;
  }

  // ----------------------------
  // WIFI SCAN HELPERS
  // ----------------------------

  static Future<bool> isWifiPermissionGranted() async {
    return await isGpsEnabled() && await isGranted(Permission.location);
  }

  /// This combines everything needed before scanning WiFi.
  static Future<bool> ensureWifiScanReady() async {
    return await ensureLocationReady();
  }
}
