import 'dart:io';
import 'package:connect/network/connection/connection_manager.dart';
import 'package:connect/network/connection/peer_registry.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/network/transfer/transfer_controller.dart';
import 'package:connect/network/transfer/background_transfer_controller.dart';
import 'package:connect/network/crypto/device_identity.dart';
import 'package:connect/network/crypto/trust_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/relay/providers/settings_provider.dart';

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

// Transfer Controller (new isolate-based architecture)
final transferControllerProvider = FutureProvider<TransferController>((ref) async {
  final connectionManager = await ref.watch(connectionManagerProvider.future);
  final identity = await ref.watch(deviceIdentityFutureProvider.future);
  final trustStore = await ref.watch(trustStoreProvider.future);
  final trustPolicy = ref.watch(trustPolicyProvider);

  final controller = TransferController(
    connectionManager: connectionManager,
    identity: identity,
    trustStore: trustStore,
    trustPolicy: trustPolicy,
  );

  await controller.initialize();

  // Wire up settings notifier to send config updates to isolates
  ref.read(settingsProvider.notifier).setTransferController(controller);

  ref.onDispose(() => controller.shutdown());

  return controller;
});

// Active Transfers - now streams from TransferController events
final activeTransfersProvider = StreamProvider.autoDispose<Map<String, Transfer>>((ref) async* {
  final controller = await ref.watch(transferControllerProvider.future);
  yield controller.activeTransfers;

  await for (final _ in controller.events) {
    yield controller.activeTransfers;
  }
});

// Background Transfer Controller
final backgroundTransferControllerProvider = Provider<BackgroundTransferController>((ref) {
  return createBackgroundTransferController();
});