import 'package:connect/network/connection_utils/device_connection_data_utils.dart';
import 'package:connect/core/device_discovery_and_connection/udp_broadcast_service.dart';
import 'package:connect/core/device_discovery_and_connection/udp_connection_request.dart';
import 'package:connect/relay/providers/device_discovery_and_connection_providers.dart';
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
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // getting providers
    AsyncValue<UdpDiscoveryService?> udpServiceAsync = ref.watch(
      udpServiceFutureProvider,
    );
    AsyncValue<ConnectionManager> connectionManagerAsync = ref.watch(
      connectionManagerFutureProvider,
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
          return udpServiceAsync.when(
            data: (udpService) {
              // update udpServiceProvider
              // ref.read(udpServiceProvider.notifier).state = udpService;

              if (udpService == null) {
                return const Text(
                  "Unable to initialize UDP service. No IP found.",
                );
              }

              // SET ALL THE CALLBACKS
              // 1. onConnectionRequest
              udpService.onConnectionRequest = (String senderIp) {
                print("Connection request from $senderIp");
                showOnConnectionRequestDialog(
                  context: context,
                  senderIp: senderIp,
                  ref: ref,
                  udpService: udpService,
                  connectionManagerAsync: connectionManagerAsync,
                );
              };
              // 2. onConnectionAccepted
              udpService.onConnectionAccepted = (String senderIp) {
                print("Connection accepted from $senderIp");
                showOnConnectionAcceptedDialog(
                  context: context,
                  senderIp: senderIp,
                  ref: ref,
                  udpService: udpService,
                  connectionManagerAsync: connectionManagerAsync,
                );
              };
              // 3. onConnectionDenied
              udpService.onConnectionDenied = (String senderIp) {
                print("Connection denied from $senderIp");
                showOnConnectionDeniedDialog(
                  context: context,
                  ref: ref,
                  senderIp: senderIp,
                );
              };
              // 4. onDisconnect
              udpService.onDisconnect = (String senderIp) async {
                await showOnDisconnectDialog(
                  context: context,
                  senderIp: senderIp,
                  ref: ref,
                );
                // remove device from connectedDevicesProvider
                ref.read(connectedDevicesProvider.notifier).update((state) {
                  final newState = Map<String, DeviceConnectionInfo>.from(
                    state,
                  );
                  newState.remove(senderIp);
                  return newState;
                });
                print("Disconnected from $senderIp");
                print(
                  "connectedDevicesMap after disconnect: ${connectedDevicesMap.keys.join(", ")}",
                );
              };

              // 5. onDevicesUpdated
              udpService.onDevicesUpdated =
                  (Map<String, DeviceConnectionInfo> ipDeviceMap) {
                    print("Devices updated: ${ipDeviceMap.keys.join(", ")}");
                    ref.read(availableDevicesProvider.notifier).state =
                        Map<String, DeviceConnectionInfo>.from(ipDeviceMap);
                    if (ipDeviceMap.isNotEmpty) {
                      ref.read(isDiscoveredProvider.notifier).state = true;
                    }
                  };

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
                                  connectionManagerAsync:
                                      connectionManagerAsync,
                                );
                                return;
                              }
                              // send connection request
                              connectionManagerAsync.whenData((
                                connectionManager,
                              ) {
                                connectionManager.sendConnectionRequest(
                                  deviceIp,
                                );
                              });
                              print("Sent connection request to $deviceIp");
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
                    udpService: udpService,
                  ),
                ],
              );
            },
            loading: () => const CircularProgressIndicator(),
            error: (err, stack) => Text('Error: $err'),
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

  final UdpDiscoveryService udpService;

  const StartDiscoveryButton({
    super.key,
    required this.isDiscovering,
    required this.udpService,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton(
      onPressed: () async {
        if (isDiscovering) {
          udpService.stopBroadcast();
          ref.read(isDiscoveringProvider.notifier).state = false;
        } else {
          ref.read(availableDevicesProvider.notifier).state = {};
          ref.read(isDiscoveredProvider.notifier).state = false;
          await udpService.start();
          ref.read(isDiscoveringProvider.notifier).state = true;
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
  required AsyncValue<ConnectionManager> connectionManagerAsync,
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
              connectionManagerAsync.whenData((connectionManager) {
                connectionManager.sendConnectionDenied(senderIp);
              });
              Navigator.of(context).pop();
            },
            child: const Text("Deny"),
          ),
          TextButton(
            onPressed: () {
              // Accept connection
              connectionManagerAsync.whenData((connectionManager) {
                connectionManager.sendConnectionAccepted(senderIp);
              });
              print("Accepted connection from $senderIp");
              // add device to connectedDevicesProvider
              ref.read(connectedDevicesProvider.notifier).update((state) {
                final newState = Map<String, DeviceConnectionInfo>.from(state);
                newState[deviceInfo.ip] = deviceInfo;
                return newState;
              });

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
  required AsyncValue<ConnectionManager> connectionManagerAsync,
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
            onPressed: () {
              print("Connection accepted from $senderIp");
              // add device to connectedDevicesProvider
              ref.read(connectedDevicesProvider.notifier).update((state) {
                final newState = Map<String, DeviceConnectionInfo>.from(state);
                newState[deviceInfo.ip] = deviceInfo;
                return newState;
              });
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
  required AsyncValue<ConnectionManager> connectionManagerAsync,
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
              connectionManagerAsync.whenData((connectionManager) {
                connectionManager.sendDisconnect(deviceIp);
              });
              // remove device from connectedDevicesProvider
              ref.read(connectedDevicesProvider.notifier).update((state) {
                final newState = Map<String, DeviceConnectionInfo>.from(state);
                newState.remove(deviceIp);
                return newState;
              });

              print(
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
