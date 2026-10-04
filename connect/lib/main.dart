import 'package:connect/app/app_lifecyle.dart';
import 'package:connect/app/tcp_config.dart';
import 'package:connect/relay/permission_manager.dart';
import 'package:connect/relay/providers/connection_permission_providers.dart';
import 'package:connect/relay/providers/hotspot_status_provider.dart';
import 'package:connect/relay/providers/lifecycle_state_provider.dart';
import 'package:connect/relay/providers/transfer_providers.dart';
import 'package:connect/relay/providers/wifi_status_provider.dart';
import 'package:connect/view/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


void main() {
  runApp(ProviderScope(child: const App()));
}

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  @override
  void initState() {
    super.initState();
    // Initialize device identity in background, then start TCP server
    _initializeDeviceIdentityAndServer();
  }

  Future<void> _initializeDeviceIdentityAndServer() async {
    try {
      await ref.read(deviceIdentityFutureProvider.future);
      debugPrint('Device identity initialized');
      // Start TCP server
      await ref.read(tcpServerProvider.future);
      debugPrint('TCP server started on port ${BaseTcpConfig.tcpPort}');
    } catch (e) {
      debugPrint('Failed to initialize device identity or TCP server: $e');
    }
  }

  @override
  void dispose() {
    // Cleanup handled by Riverpod
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ensure permissions for wifi scan are ready
    PermissionManager.ensureWifiScanReady();

    return AppLifecycleHandler(
      onStateChanged: (state) {
        debugPrint('AppLifecycleState changed to: $state');
        if (state == AppLifecycleState.resumed) {
          ref.read(lifeCycleStateProvider.notifier).state =
              AppLifecycleState.resumed;
          ref.invalidate(hotspotStatusProvider);
          ref.invalidate(isWifiEnabledProvider);
          ref.invalidate(isWifiPermissionGrantedProvider);
          ref.invalidate(availableWifiNewtworksProvider);
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