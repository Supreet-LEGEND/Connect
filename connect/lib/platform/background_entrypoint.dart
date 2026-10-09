import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:ui' show RootIsolateToken;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:connect/network/connection/connection_manager.dart';
import 'package:connect/network/connection/peer_registry.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:connect/network/storage/database_helper_desktop.dart';
import 'package:connect/network/transfer/isolate/commands.dart';
import 'package:connect/network/transfer/isolate/network_commands.dart';
import 'package:connect/network/transfer/isolate/transfer_isolate.dart';
import 'package:connect/network/connection/isolate/network_isolate.dart';
import 'package:connect/app/tcp_config.dart';

/// Background transfer entrypoint for platform-specific background execution
///
/// This file is the entrypoint for:
/// - Android Foreground Service
/// - Windows Background Service
/// - Linux systemd service
/// - macOS launchd agent
///
/// It initializes the same three-isolate architecture as the foreground app
/// but with minimal UI dependencies.

Future<void> backgroundTransferEntrypoint() async {
  // Initialize sqflite FFI for Windows/Linux/macOS (required for database access in background isolate)
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final args = Platform.executableArguments;
  final params = _parseArgs(args);

  if (params == null) {
    stderr.writeln('Invalid background entrypoint arguments');
    exit(1);
  }

  // Initialize database first
  await DatabaseHelperDesktop.instance.init();

  // Load peer registry for deviceId resolution
  final peerRegistry = PeerRegistry();
  await peerRegistry.load();

  // Convert peer registry to JSON for Network Isolate (fingerprint -> deviceId)
  final peerRegistryJson = jsonEncode(
    peerRegistry.peers.map(
      (deviceId, peer) => MapEntry(peer.fingerprint, deviceId),
    ),
  );

  // Initialize ConnectionManager for device validation
  final trustStore = TrustStore();
  await trustStore.load();
  final connectionManager = ConnectionManager(
    trustStore: trustStore,
    trustPolicy: params.trustPolicy,
    peerRegistry: peerRegistry,
  );

  // Set up receive ports for inter-isolate communication
  final mainReceivePort = ReceivePort();
  final networkReceivePort = ReceivePort();
  final transferReceivePort = ReceivePort();

  // Start Network isolate first with peer registry
  final networkIsolate = await Isolate.spawn(
    networkIsolateEntrypoint,
    NetworkIsolateParams(
      mainSendPort: networkReceivePort.sendPort,
      identityPrivateKeyPem: params.identityPrivateKeyPem,
      trustStoreJson: params.trustStoreJson,
      trustPolicy: params.trustPolicy,
      listenPort: BaseTcpConfig.tcpPort,
      peerRegistryJson: peerRegistryJson,
    ),
  );

  // Wait for Network isolate to be ready using Completer (ReceivePort is single-subscription)
  final networkReadyCompleter = Completer<SendPort>();
  late StreamSubscription networkSub;
  networkSub = networkReceivePort.listen((message) {
    if (!networkReadyCompleter.isCompleted && message is SendPort) {
      networkReadyCompleter.complete(message);
    }
  });

  final networkSendPort = await networkReadyCompleter.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => throw TimeoutException('Network isolate handshake timeout'),
  );
  networkSub.cancel();

  // Start Transfer isolate with Network isolate's send port
  final transferIsolate = await Isolate.spawn(
    transferIsolateEntrypoint,
    TransferIsolateParams(
      networkSendPort: networkSendPort,
      mainSendPort: mainReceivePort.sendPort,
      rootIsolateToken: RootIsolateToken.instance!,
    ),
  );

  // Wait for Transfer isolate to be ready using Completer
  final transferReadyCompleter = Completer<SendPort>();
  late StreamSubscription transferSub;
  transferSub = transferReceivePort.listen((message) {
    if (!transferReadyCompleter.isCompleted && message is SendPort) {
      transferReadyCompleter.complete(message);
    }
  });

  final transferSendPort = await transferReadyCompleter.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => throw TimeoutException('Transfer isolate handshake timeout'),
  );
  transferSub.cancel();

  // Resume pending transfers if any
  if (params.transferIdsToResume.isNotEmpty) {
    await _resumeTransfers(transferSendPort, params.transferIdsToResume, peerRegistry, trustStore);
  }

  // Listen for events from both isolates
  mainReceivePort.listen((message) {
    // Forward events to platform-specific handlers if needed
    if (message is TransferEvent) {
      // Could forward to platform notification system
    } else if (message is NetworkEvent) {
      // Could forward to platform notification system
    }
  });

  // Keep the isolate alive
  await Future.delayed(const Duration(days: 365));
}

Future<void> _resumeTransfers(SendPort transferSendPort, List<String> transferIds, PeerRegistry peerRegistry, TrustStore trustStore) async {
  final db = await DatabaseHelperDesktop.instance.init();
  
  for (final transferId in transferIds) {
    try {
      // Check outgoing progress
      final outgoingResult = await db.query(
        'outgoing_progress',
        where: 'transfer_id = ?',
        whereArgs: [transferId],
      );
      
      if (outgoingResult.isNotEmpty) {
        // Resume outgoing transfer - validate device first
        final data = outgoingResult.first;
        final deviceId = data['device_id'] as String;
        
        // Validate device is still in peer registry (still trusted)
        if (!peerRegistry.hasPeer(deviceId)) {
          print('Skipping transfer $transferId: device $deviceId no longer in peer registry');
          // Mark as failed in DB
          await db.update(
            'outgoing_progress',
            {'status': 'failed', 'error': 'Device no longer trusted'},
            where: 'transfer_id = ?',
            whereArgs: [transferId],
          );
          continue;
        }
        
        transferSendPort.send(SendFileCommand(
          transferId: transferId,
          deviceId: deviceId,
          filePath: data['file_path'] as String,
          fileName: data['file_name'] as String,
          fileSize: data['total_bytes'] as int,
        ));
        continue;
      }

      // Check incoming progress
      final incomingResult = await db.query(
        'incoming_progress',
        where: 'transfer_id = ?',
        whereArgs: [transferId],
      );
      
      if (incomingResult.isNotEmpty) {
        // Resume incoming transfer - validate device first
        final data = incomingResult.first;
        final deviceId = data['device_id'] as String;
        
        // Validate device is still trusted
        if (!peerRegistry.hasPeer(deviceId) && trustStore.getEntry(deviceId) == null) {
          print('Skipping incoming transfer $transferId: device $deviceId not trusted');
          await db.update(
            'incoming_progress',
            {'status': 'failed', 'error': 'Device not trusted'},
            where: 'transfer_id = ?',
            whereArgs: [transferId],
          );
          continue;
        }
        
        // Get device info for reconnection
        final peer = peerRegistry.getPeer(deviceId);
        if (peer != null) {
          // Trigger connection to device so incoming transfer can resume
          transferSendPort.send(ConnectDeviceCommand(
            deviceId: deviceId,
            host: peer.lastKnownIp ?? '',
            port: peer.lastKnownPort ?? BaseTcpConfig.tcpPort,
            fingerprint: deviceId,
            trustPolicy: TrustPolicy.tofu,
          ));
          print('Triggered reconnection for incoming transfer $transferId to device $deviceId');
        } else {
          print('Incoming transfer $transferId will resume when peer reconnects (no endpoint known)');
        }
      }
    } catch (e) {
      print('Failed to resume transfer $transferId: $e');
    }
  }
}

class _BackgroundParams {
  final String identityPrivateKeyPem;
  final String trustStoreJson;
  final TrustPolicy trustPolicy;
  final List<String> transferIdsToResume;

  _BackgroundParams({
    required this.identityPrivateKeyPem,
    required this.trustStoreJson,
    required this.trustPolicy,
    required this.transferIdsToResume,
  });
}

_BackgroundParams? _parseArgs(List<String> args) {
  // Parse command line arguments
  // Expected format:
  // --identity-key=<pem> --trust-store=<json> --trust-policy=<policy> --resume=<transferId1>,<transferId2>,...

  String? identityKey;
  String? trustStore;
  TrustPolicy trustPolicy = TrustPolicy.tofu;
  final transferIds = <String>[];

  for (final arg in args) {
    if (arg.startsWith('--identity-key=')) {
      identityKey = arg.substring('--identity-key='.length);
    } else if (arg.startsWith('--trust-store=')) {
      trustStore = arg.substring('--trust-store='.length);
    } else if (arg.startsWith('--trust-policy=')) {
      final policy = arg.substring('--trust-policy='.length);
      trustPolicy = TrustPolicy.values.byName(policy);
    } else if (arg.startsWith('--resume=')) {
      final ids = arg.substring('--resume='.length).split(',');
      transferIds.addAll(ids);
    }
  }

  if (identityKey == null || trustStore == null) {
    return null;
  }

  return _BackgroundParams(
    identityPrivateKeyPem: identityKey,
    trustStoreJson: trustStore,
    trustPolicy: trustPolicy,
    transferIdsToResume: transferIds,
  );
}