import 'dart:async';
import 'package:connect/app/tcp_config.dart';
import 'package:connect/network/connection_utils/device_connection_data_utils.dart';
import 'package:connect/core/device_discovery_and_connection/udp_broadcast_service.dart';
import 'package:connect/core/device_discovery_and_connection/udp_connection_request.dart';
import 'package:connect/relay/providers/device_discovery_and_connection_providers.dart';
import 'package:connect/relay/providers/transfer_providers.dart';
import 'package:connect/relay/providers/wifi_status_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DeviceDiscoveryAndConnectionWidget extends ConsumerStatefulWidget {
  const DeviceDiscoveryAndConnectionWidget({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _DeviceDiscoveryAndConnectionWidgetState();
}

class _DeviceDiscoveryAndConnectionWidgetState
    extends ConsumerState<DeviceDiscoveryAndConnectionWidget> {
  UdpDiscoveryService? _udpService;
  StreamSubscription? _udpServiceSubscription;

  @override
  void initState() {
    super.initState();
    _initializeUdpService();
  }

  Future<void> _initializeUdpService() async {
    final udpService = await ref.read(udpServiceFutureProvider.future);
    if (udpService != null) {
      _udpService = udpService;
      _setupUdpCallbacks();
      // Don't start UDP automatically - wait for user to press "Start Discovery"
      // await udpService.start();
      // ref.read(isDiscoveringProvider.notifier).state = true;
    }
  }

  void _setupUdpCallbacks() {
    final controller = ref.read(discoveryControllerProvider);
    final connectionSignalerAsync = ref.read(connectionSignalerFutureProvider);

    _udpService!.onConnectionRequest = (String senderIp) {
      debugPrint("Connection request from $senderIp");
      controller.onConnectionRequest(senderIp);
      showOnConnectionRequestDialog(
        context: context,
        senderIp: senderIp,
        ref: ref,
        udpService: _udpService!,
        connectionSignalerAsync: connectionSignalerAsync,
      );
    };

    _udpService!.onConnectionAccepted = (String senderIp) {
      debugPrint("Connection accepted from $senderIp");
      controller.onConnectionAccepted(senderIp);
      showOnConnectionAcceptedDialog(
        context: context,
        senderIp: senderIp,
        ref: ref,
        udpService: _udpService!,
        connectionSignalerAsync: connectionSignalerAsync,
      );
    };

    _udpService!.onConnectionDenied = (String senderIp) {
      debugPrint("Connection denied from $senderIp");
      controller.onConnectionDenied(senderIp);
      showOnConnectionDeniedDialog(
        context: context,
        senderIp: senderIp,
        ref: ref,
      );
    };

    _udpService!.onDisconnect = (String senderIp) async {
      await showOnDisconnectDialog(
        context: context,
        senderIp: senderIp,
        ref: ref,
      );
      controller.onDisconnect(senderIp);
    };

    _udpService!.onDevicesUpdated =
        (Map<String, DeviceConnectionInfo> ipDeviceMap) {
      debugPrint("Devices updated: ${ipDeviceMap.keys.join(", ")}");
      controller.onDevicesUpdated(ipDeviceMap);
    };
  }

  @override
  void dispose() {
    _udpService?.stopBroadcast();
    _udpService?.closeSockets();
    _udpServiceSubscription?.cancel();
    super.dispose();
  }

@override
  Widget build(BuildContext context) {
    // getting providers
    AsyncValue<UdpConnectionSignaler> connectionSignalerAsync = ref.watch(
      connectionSignalerFutureProvider,
    );

    // getting states
    Map<String, DeviceConnectionInfo> availableDevicesMap = ref.watch(
      availableDevicesProvider,
    );

    // wifi status async value
    AsyncValue<bool> wifiStatusAsync = ref.watch(wifiStatusProvider);
    final connectedDevicesMap = ref.watch(connectedDevicesProvider);
    bool isDiscovering = ref.watch(isDiscoveringProvider);
    bool isDiscovered = ref.watch(isDiscoveredProvider);
    final controller = ref.watch(discoveryControllerProvider);

    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.primary),
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: wifiStatusAsync.when(
        data: (isWifiEnabled) {
          if (!isWifiEnabled) {
            return const Text(
              "WiFi is disabled. Please enable WiFi to discover devices.",
            );
          }
          // Use the already initialized UDP service
          if (_udpService == null) {
            return const Text(
              "Initializing UDP service...",
            );
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isDiscovering
                    ? "Discovering Devices:"
                    : isDiscovered
                        ? "Available Devices:"
                        : "Discover Devices:",
              ),

              Divider(),

              if (availableDevicesMap.isEmpty && isDiscovered)
                const Text("No devices found.")
              else if (availableDevicesMap.isEmpty &&
                  !isDiscovered &&
                  !isDiscovering)
                const Text("Press 'Start Discovery' to find devices.")
              else
                Flexible(
                  child: ListView.builder(
                    itemCount: availableDevicesMap.length,
                    shrinkWrap: true,
                    itemBuilder: (context, index) {
                      String deviceIp = availableDevicesMap.keys.elementAt(
                        index,
                      );
                      DeviceConnectionInfo deviceInfo =
                          availableDevicesMap[deviceIp]!;
                      return ListTile(
                        onTap: () {
                          if (connectedDevicesMap.containsKey(deviceIp)) {
                            // confirm and send disconnect
                            confirmAndSendDisconnectToDevice(
                              deviceIp: deviceIp,
                              context: context,
                              ref: ref,
                              connectionSignalerAsync:
                                  connectionSignalerAsync,
                            );
                            return;
                          }
                          // send connection request
                          connectionSignalerAsync.whenData((
                            signaler,
                          ) {
                            signaler.sendConnectionRequest(
                              deviceIp,
                            );
                          });
                          debugPrint("Sent connection request to $deviceIp");
                        },
                        leading: Icon(
                          getPlatformIcon(platform: deviceInfo.platform),
                        ),
                        trailing: connectedDevicesMap.containsKey(deviceIp)
                            ? const Icon(Icons.link, color: Colors.green)
                            : null,
                        title: Text(deviceInfo.name),
                        subtitle: Text(deviceInfo.ip),
                      );
                    },
                  ),
                ),

              if (isDiscovering) CircularProgressIndicator(),

              if (availableDevicesMap.isNotEmpty) Divider(),

              StartDiscoveryButton(
                isDiscovering: isDiscovering,
                controller: controller,
              ),
            ],
          );
        },
        loading: () => const CircularProgressIndicator(),
        error: (err, stack) => Text('Error: $err'),
      ),
    );
  }
}

class StartDiscoveryButton extends ConsumerWidget {
  final bool isDiscovering;
  final DiscoveryController controller;

  const StartDiscoveryButton({
    super.key,
    required this.isDiscovering,
    required this.controller,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton(
      onPressed: () async {
        if (isDiscovering) {
          await controller.stopDiscovery();
        } else {
          ref.read(availableDevicesProvider.notifier).state = {};
          ref.read(isDiscoveredProvider.notifier).state = false;
          await controller.startDiscovery();
        }
      },
      child: Text(isDiscovering ? "Stop Discovery" : "Start Discovery"),
    );
  }
}

void showOnConnectionRequestDialog({
  required BuildContext context,
  required String senderIp,
  required WidgetRef ref,
  required UdpDiscoveryService udpService,
  required AsyncValue<UdpConnectionSignaler> connectionSignalerAsync,
}) {
  showDialog(
    context: context,
    builder: (context) {
      // get device info from available devices
      DeviceConnectionInfo deviceInfo =
          ref.read(availableDevicesProvider)[senderIp] ??
          DeviceConnectionInfo(
            name: "Unknown Device",
            ip: senderIp,
            platform: "unknown",
            lastSeen: DateTime.now(),
          );
      return AlertDialog(
        title: const Text("Connection Request"),
        content: Text("Device '${deviceInfo.name}' wants to connect. Accept?"),
        actions: [
          TextButton(
            onPressed: () {
              // Deny connection
              connectionSignalerAsync.whenData((signaler) {
                signaler.sendConnectionDenied(senderIp);
              });
              Navigator.of(context).pop();
            },
            child: const Text("Deny"),
          ),
          TextButton(
            onPressed: () async {
              // Accept connection
              connectionSignalerAsync.whenData((signaler) {
                signaler.sendConnectionAccepted(senderIp);
              });
              debugPrint("Accepted connection from $senderIp");
              // add device to connectedDevicesProvider
              ref.read(connectedDevicesProvider.notifier).update((state) {
                final newState = Map<String, DeviceConnectionInfo>.from(state);
                newState[deviceInfo.ip] = deviceInfo;
                return newState;
              });

              // Initiate TCP connection to the accepted device with fingerprint verification
              final tempDeviceId = '${deviceInfo.ip}:${BaseTcpConfig.tcpPort}';
              try {
                final connectionManager = await ref.read(connectionManagerProvider.future);
                final _ = await connectionManager.addDevice(
                  deviceId: tempDeviceId,
                  name: deviceInfo.name,
                  ip: deviceInfo.ip,
                  port: BaseTcpConfig.tcpPort,
                  identity: ref.read(deviceIdentityProvider),
                  onVerifyFingerprint: (fingerprint) async {
                    if (!context.mounted) return false;
                    return await showFingerprintVerificationDialog(
                      context: context,
                      deviceName: deviceInfo.name,
                      fingerprint: fingerprint,
                    );
                  },
                );

                debugPrint('TCP connection initiated and verified to $senderIp');
              } catch (e) {
                debugPrint('Failed to initiate TCP connection: $e');
                // Remove from connected devices on failure
                ref.read(connectedDevicesProvider.notifier).update((state) {
                  final newState = Map<String, DeviceConnectionInfo>.from(state);
                  newState.remove(deviceInfo.ip);
                  return newState;
                });
              }

              Navigator.of(context).pop();
            },
            child: const Text("Accept"),
          ),
        ],
      );
    },
  );
}

void showOnConnectionAcceptedDialog({
  required BuildContext context,
  required String senderIp,
  required WidgetRef ref,
  required UdpDiscoveryService udpService,
  required AsyncValue<UdpConnectionSignaler> connectionSignalerAsync,
}) {
  showDialog(
    context: context,
    builder: (context) {
      // get device info from available devices
      DeviceConnectionInfo deviceInfo =
          ref.read(availableDevicesProvider)[senderIp] ??
          DeviceConnectionInfo(
            name: "Unknown Device",
            ip: senderIp,
            platform: "unknown",
            lastSeen: DateTime.now(),
          );
      return AlertDialog(
        title: const Text("Connection Accepted"),
        content: Text("You have been connected to '${deviceInfo.name}'."),
        actions: [
          TextButton(
            onPressed: () async {
              debugPrint("Connection accepted from $senderIp");
              // add device to connectedDevicesProvider
              ref.read(connectedDevicesProvider.notifier).update((state) {
                final newState = Map<String, DeviceConnectionInfo>.from(state);
                newState[deviceInfo.ip] = deviceInfo;
                return newState;
              });

              // Initiate TCP connection to the accepted device with fingerprint verification
              final tempDeviceId = '${deviceInfo.ip}:${BaseTcpConfig.tcpPort}';
              try {
                final connectionManager = await ref.read(connectionManagerProvider.future);
                await connectionManager.addDevice(
                  deviceId: tempDeviceId,
                  name: deviceInfo.name,
                  ip: deviceInfo.ip,
                  port: BaseTcpConfig.tcpPort,
                  identity: ref.read(deviceIdentityProvider),
                  onVerifyFingerprint: (fingerprint) async {
                    if (!context.mounted) return false;
                    return await showFingerprintVerificationDialog(
                      context: context,
                      deviceName: deviceInfo.name,
                      fingerprint: fingerprint,
                    );
                  },
                );

                debugPrint('TCP connection initiated and verified to $senderIp');
              } catch (e) {
                debugPrint('Failed to initiate TCP connection: $e');
                // Remove from connected devices on failure
                ref.read(connectedDevicesProvider.notifier).update((state) {
                  final newState = Map<String, DeviceConnectionInfo>.from(state);
                  newState.remove(deviceInfo.ip);
                  return newState;
                });
              }

              Navigator.of(context).pop();
            },
            child: const Text("OK"),
          ),
        ],
      );
    },
  );
}

void showOnConnectionDeniedDialog({
  required BuildContext context,
  required WidgetRef ref,
  required String senderIp,
}) {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text("Connection Denied"),
        content: Text(
          "Your connection request to '${ref.read(availableDevicesProvider)[senderIp]?.name ?? senderIp}' was denied.",
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text("OK"),
          ),
        ],
      );
    },
  );
}

Future<void> showOnDisconnectDialog({
  required BuildContext context,
  required WidgetRef ref,
  required String senderIp,
}) async {
  await showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text("Disconnected"),
        content: Text(
          "You have been disconnected from '${ref.read(connectedDevicesProvider)[senderIp]?.name ?? senderIp}'.",
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text("OK"),
          ),
        ],
      );
    },
  );
}

void confirmAndSendDisconnectToDevice({
  required BuildContext context,
  required WidgetRef ref,
  required String deviceIp,
  required AsyncValue<UdpConnectionSignaler> connectionSignalerAsync,
}) {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text("Disconnect"),
        content: Text(
          "Are you sure you want to disconnect from '${ref.read(connectedDevicesProvider)[deviceIp]?.name ?? deviceIp}'?",
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              // send disconnect message
              connectionSignalerAsync.whenData((signaler) {
                signaler.sendDisconnect(deviceIp);
              });
              // remove device from connectedDevicesProvider
              ref.read(connectedDevicesProvider.notifier).update((state) {
                final newState = Map<String, DeviceConnectionInfo>.from(state);
                newState.remove(deviceIp);
                return newState;
              });

              debugPrint(
                "connected devices after disconnect: ${ref.read(connectedDevicesProvider).keys.join(", ")}",
              );
              Navigator.of(context).pop();
            },
            child: const Text("Disconnect"),
          ),
        ],
      );
    },
  );
}

IconData getPlatformIcon({required String platform}) {
  switch (platform.toLowerCase()) {
    case 'android':
      return Icons.android;
    case 'ios':
      return Icons.phone_iphone;
    case 'windows':
      return Icons.window_sharp;
    case 'macos':
      return Icons.laptop_mac;
    case 'linux':
      return Icons.laptop;
    default:
      return Icons.devices;
  }
}

Future<bool> showFingerprintVerificationDialog({
  required BuildContext context,
  required String deviceName,
  required String fingerprint,
}) async {
  return await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Verify Device Identity'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Device: $deviceName'),
          const SizedBox(height: 8),
          const Text('Please verify the fingerprint matches on both devices:'),
          const SizedBox(height: 12),
          SelectableText(
            _formatFingerprintForDisplay(fingerprint),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'If the fingerprints match on both devices, tap "Verify". '
            'If they do not match, tap "Reject" - this could indicate a man-in-the-middle attack.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Reject'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Verify'),
        ),
      ],
    ),
  ) ?? false;
}

String _formatFingerprintForDisplay(String fingerprint) {
  // Format with line breaks every 8 groups for readability
  final groups = <String>[];
  for (int i = 0; i < fingerprint.length; i += 2) {
    groups.add(fingerprint.substring(i, i + 2));
  }
  final lines = <String>[];
  for (int i = 0; i < groups.length; i += 8) {
    lines.add(groups.sublist(i, (i + 8).clamp(0, groups.length)).join(':'));
  }
  return lines.join('\n');
}