import 'dart:io';
import 'package:connect/network/connection/connection_manager.dart';
import 'package:connect/network/connection/peer_registry.dart';
import 'package:connect/network/connection/tcp_server.dart';
import 'package:connect/network/transfer/receive_transfer_manager.dart';
import 'package:connect/network/transfer/send_transfer_manager.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/network/transfer/transfer_cache_manager.dart';
import 'package:connect/network/crypto/device_identity.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:connect/network/storage/database_helper.dart';
import 'package:connect/app/tcp_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';

// Device Identity
final deviceIdentityProvider = Provider<DeviceIdentity>((ref) => DeviceIdentity());

final deviceIdentityFutureProvider = FutureProvider<DeviceIdentity>((ref) async {
  final identity = ref.read(deviceIdentityProvider);
  await identity.initialize();
  return identity;
});

// Trust Store
final trustStoreProvider = FutureProvider<TrustStore>((ref) async {
  final store = TrustStore();
  await store.load();
  return store;
});

final trustPolicyProvider = Provider<TrustPolicy>((ref) => TrustPolicy.tofu);

// Peer Registry
class PeerRegistryNotifier extends Notifier<PeerRegistry> {
  @override
  PeerRegistry build() {
    final registry = PeerRegistry();
    ref.onDispose(() => registry.dispose());
    return registry;
  }
}

final peerRegistryProvider = NotifierProvider<PeerRegistryNotifier, PeerRegistry>(() => PeerRegistryNotifier());

final peerRegistryFutureProvider = FutureProvider<PeerRegistry>((ref) async {
  final registry = ref.watch(peerRegistryProvider);
  await registry.load();
  return registry;
});

// Connection Manager
final connectionManagerProvider = FutureProvider<ConnectionManager>((ref) async {
  final trustStore = await ref.watch(trustStoreProvider.future);
  final trustPolicy = ref.watch(trustPolicyProvider);
  final registry = ref.watch(peerRegistryProvider);
  final manager = ConnectionManager(
    trustStore: trustStore,
    trustPolicy: trustPolicy,
    peerRegistry: registry,
  );
  ref.onDispose(() => manager.closeAll());
  return manager;
});

// Send Transfer Manager
final sendTransferManagerProvider = FutureProvider<SendTransferManager>((ref) async {
  final connectionManager = await ref.watch(connectionManagerProvider.future);
  final manager = SendTransferManager(
    connectionManager: connectionManager,
    db: await DatabaseHelper.init(),
  );
  ref.onDispose(() => manager.dispose());
  return manager;
});

// Receive Transfer Manager
final downloadDirectoryProvider = FutureProvider<Directory>((ref) async {
  final appDir = await getApplicationDocumentsDirectory();
  final downloadDir = Directory('${appDir.path}/connect_transfers');
  if (!await downloadDir.exists()) {
    await downloadDir.create(recursive: true);
  }
  return downloadDir;
});

final progressDirectoryProvider = FutureProvider<Directory>((ref) async {
  final appDir = await getApplicationDocumentsDirectory();
  final progressDir = Directory('${appDir.path}/connect_transfers/progress');
  if (!await progressDir.exists()) {
    await progressDir.create(recursive: true);
  }
  return progressDir;
});

final receiveTransferManagerProvider = FutureProvider<ReceiveTransferManager>((ref) async {
  final directory = await ref.watch(downloadDirectoryProvider.future);
  final progressDir = await ref.watch(progressDirectoryProvider.future);
  final db = await DatabaseHelper.init();
  return ReceiveTransferManager(directory: directory, db: db);
});

// TCP Server
final tcpServerProvider = FutureProvider<TcpServer>((ref) async {
  final identity = await ref.watch(deviceIdentityFutureProvider.future);
  final trustStore = await ref.watch(trustStoreProvider.future);
  final receiveManager = await ref.watch(receiveTransferManagerProvider.future);

  final server = TcpServer(
    port: BaseTcpConfig.tcpPort,
    identity: identity,
    trustStore: trustStore,
    onConnection: (incomingConnection, health) async {
      await receiveManager.registerConnection(incomingConnection, health);
    },
  );

  await server.start();
  return server;
});

// Active Transfers
final activeTransfersProvider = StateProvider.autoDispose<Map<String, Transfer>>((ref) => {});

// Transfer Cache Manager
final transferCacheManagerProvider = FutureProvider<TransferCacheManager>((ref) async {
  final progressDir = await ref.watch(progressDirectoryProvider.future);
  final manager = TransferCacheManager(progressDir: progressDir);
  await manager.start();
  return manager;
});