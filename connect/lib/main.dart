import 'package:connect/app/app_lifecyle.dart';
import 'package:connect/app/tcp_config.dart';
import 'package:connect/relay/permission_manager.dart';
import 'package:connect/relay/providers/connection_permission_providers.dart';
import 'package:connect/relay/providers/hotspot_status_provider.dart';
import 'package:connect/relay/providers/lifecycle_state_provider.dart';
import 'package:connect/relay/providers/settings_provider.dart';
import 'package:connect/relay/providers/transfer_providers.dart';
import 'package:connect/relay/providers/wifi_status_provider.dart';
import 'package:connect/view/about_page.dart';
import 'package:connect/view/home_page.dart';
import 'package:connect/view/settings_page.dart';
import 'package:connect/view/transfer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/view/theme/app_theme.dart';
import 'package:connect/network/storage/database_helper_factory.dart';
import 'dart:io' show Platform;

// Initialize sqflite FFI for Windows/Linux/macOS (required for database access)
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // Initialize sqflite FFI for Windows/Linux/macOS (required for database access)
  if (!Platform.isAndroid && !Platform.isIOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  
  // Initialize platform-specific database helper
  initializeDatabaseHelper();
  
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
    // Initialize device identity in background, then start transfer controller (which starts TCP server in network isolate)
    _initializeDeviceIdentityAndServer();
    // Ensure permissions for wifi scan are ready
    PermissionManager.ensureWifiScanReady();
  }

  Future<void> _initializeDeviceIdentityAndServer() async {
    try {
      await ref.read(deviceIdentityFutureProvider.future);
      debugPrint('Device identity initialized');
      // Start transfer controller (which initializes network isolate with TCP server)
      await ref.read(transferControllerProvider.future);
      debugPrint('Transfer controller initialized, TCP server started on port ${BaseTcpConfig.tcpPort}');
    } catch (e) {
      debugPrint('Failed to initialize device identity or transfer controller: $e');
    }
  }

  @override
  void dispose() {
    // Cleanup handled by Riverpod
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch theme mode from settings
    final themeMode = ref.watch(themeModeProvider);

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
        themeMode: themeMode,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        routes: {
          '/': (context) => const HomePage(),
          '/transfers': (context) => const TransferPage(),
          '/settings': (context) => const SettingsPage(),
          '/about': (context) => const AboutPage(),
        },
      ),
    );
  }
}