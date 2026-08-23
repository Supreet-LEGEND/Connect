import 'package:connect/app/app_lifecyle.dart';
import 'package:connect/relay/permission_manager.dart';
import 'package:connect/relay/providers/connection_permission_providers.dart';
import 'package:connect/relay/providers/device_discovery_and_connection_providers.dart';
import 'package:connect/relay/providers/hotspot_status_provider.dart';
import 'package:connect/relay/providers/lifecycle_state_provider.dart';
import 'package:connect/relay/providers/wifi_status_provider.dart';
import 'package:connect/view/home_page.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


void main() {
  FlutterCryptography.enable();
  runApp(ProviderScope(child: const App()));
}

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  @override
  Widget build(BuildContext context) {
    // ensure permissions for wifi scan are ready
    PermissionManager.ensureWifiScanReady();

    // Subscribe to connectivity changes
    // final wifiConnectivityAsync = ref.watch(wifiStatusProvider);

    // listen to app lifecycle changes
    return AppLifecycleHandler(
      onStateChanged: (state) {
        // UPDATE REQUIRED PROVIDERS -------------------

        // ----------------------------------------------
        debugPrint('AppLifecycleState changed to: $state');
        if (state == AppLifecycleState.resumed) {
          ref.read(lifeCycleStateProvider.notifier).state =
              AppLifecycleState.resumed;
          // permission check -----------------------------
          ref.invalidate(hotspotStatusProvider);
          ref.invalidate(isWifiEnabledProvider);
          ref.invalidate(isWifiPermissionGrantedProvider);
          ref.invalidate(availableWifiNewtworksProvider);
          // -----------------------------------------------
        } else if (state == AppLifecycleState.inactive) {
          ref.read(lifeCycleStateProvider.notifier).state =
              AppLifecycleState.inactive;
        } else if (state == AppLifecycleState.paused) {
          ref.read(lifeCycleStateProvider.notifier).state =
              AppLifecycleState.paused;
        } else if (state == AppLifecycleState.hidden) {
          ref.read(lifeCycleStateProvider.notifier).state =
              AppLifecycleState.hidden;
        } else if (state == AppLifecycleState.detached) {
          ref.read(lifeCycleStateProvider.notifier).state =
              AppLifecycleState.detached;
        }
      },

      // Connectivity status update
      child: MaterialApp(
        title: 'Connect App',
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData.dark(),
        theme: ThemeData(primarySwatch: Colors.purple),
        routes: {'/': (context) => HomePage()},
      ),
    );
  }
}
