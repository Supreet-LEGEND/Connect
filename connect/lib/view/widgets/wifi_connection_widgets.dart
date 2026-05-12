import 'dart:io';
import 'package:connect/core/hardware_connection_status/hardware_connection_status_manager.dart';
import 'package:connect/relay/providers/connection_permission_providers.dart';
import 'package:connect/relay/providers/hotspot_status_provider.dart';
import 'package:connect/relay/providers/wifi_status_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wifi_connection/wifi_connection.dart';

// CONNECTION WIDGET

class ConnectionWidget extends ConsumerStatefulWidget {
  const ConnectionWidget({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _ConnectionWidgetState();
}

class _ConnectionWidgetState extends ConsumerState<ConnectionWidget> {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: .center,
        mainAxisSize: .min,
        children: [
          // Show text
          Text(
            "Make connection first : ",
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),

          Divider(height: 20, thickness: 1.5),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 5,
            runAlignment: WrapAlignment.center,
            direction: Axis.horizontal,
            children: [
              Platform.isAndroid || Platform.isIOS
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: HotspotConnection(),
                    )
                  : Container(),
              WifiConnectionWidget(),
            ],
          ),
        ],
      ),
    );
  }
}

class HotspotConnection extends ConsumerStatefulWidget {
  const HotspotConnection({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _HotspotConnectionState();
}

class _HotspotConnectionState extends ConsumerState<HotspotConnection> {
  @override
  Widget build(BuildContext context) {
    final isHotspotEnabled = ref.watch(hotspotStatusProvider);
    return Container(
      padding: const EdgeInsets.all(10.0),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.primary),
        // borderRadius: BorderRadius.circular(8.0),
      ),
      child: isHotspotEnabled.when(
        data: (bool? isOn) {
          // isOn = null;
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: .min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: .min,
                children: [
                  Icon(
                    isOn == null
                        ? Icons.wifi_tethering_error
                        : isOn
                        ? Icons.wifi_tethering
                        : Icons.wifi_tethering_off,

                    color: isOn == null
                        ? Colors.amber
                        : isOn
                        ? Colors.green
                        : Colors.red,
                  ),
                  SizedBox(width: 5),
                  Text(
                    isOn == null
                        ? "Couldn't detect"
                        : isOn
                        ? 'Hotspot ON'
                        : 'Hotspot OFF',
                  ),
                ],
              ),
              SizedBox(height: 10),
              // hotspot settings button
              TextButton(
                onPressed: () {
                  WifiConnectionManager.openHotspotSettings();
                },
                style: TextButton.styleFrom(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.primaryContainer,
                ),
                child: Text(
                  isOn == null
                      ? "Open Hospot Settings"
                      : !isOn
                      ? "Enable Hotspot"
                      : "Hotspot is ON",
                ),
              ),
            ],
          );
        },
        error: (err, stack) => Center(child: Text("Error: $err")),
        loading: () => CircularProgressIndicator(
          color: Theme.of(context).progressIndicatorTheme.circularTrackColor,
        ),
      ),
    );
  }
}

class WifiConnectionWidget extends ConsumerWidget {
  const WifiConnectionWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWifiEnabledAsync = ref.watch(isWifiEnabledProvider);
    final availableWifiNetworksAsync = ref.watch(
      availableWifiNewtworksProvider,
    );
    final wifiConnectedStatusAsync = ref.watch(wifiStatusProvider);
    final isWifiPermissionGrantedAsync = ref.watch(
      isWifiPermissionGrantedProvider,
    );

    return Container(
      padding: EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.primary),
      ),

      child: isWifiEnabledAsync.when(
        data: (isOn) {
          return Column(
            mainAxisAlignment: .center,
            mainAxisSize: .min,
            children: [
              wifiConnectedStatusAsync.when(
                data: (isConnected) {
                  return Column(
                    mainAxisAlignment: .center,
                    mainAxisSize: .min,
                    crossAxisAlignment: .center,
                    children: [
                      Row(
                        mainAxisAlignment: .center,
                        mainAxisSize: .min,
                        children: [
                          Icon(
                            isOn == null && isConnected
                                ? Icons.wifi
                                : isOn == null && !isConnected
                                ? Icons.perm_scan_wifi
                                : isOn! || isConnected
                                ? Icons.wifi
                                : Icons.wifi_off,

                            color: isConnected
                                ? Colors.green
                                : isOn == null && !isConnected
                                ? Colors.amber
                                : !isConnected && isOn!
                                ? Colors.blueGrey
                                : Colors.red,
                          ),

                          SizedBox(width: 5),

                          Text(
                            isOn == null && isConnected
                                ? "Connected"
                                : isOn == null && !isConnected
                                ? "Couldn't Detect"
                                : isOn! && !isConnected
                                ? "Wifi ON"
                                : isConnected
                                ? "Connected"
                                : !isOn && !isConnected
                                ? "Wifi OFF"
                                : "Unhandled Condition",
                          ),
                        ],
                      ),
                      SizedBox(height: 10),

                      // show available networks
                      !isConnected && isOn!
                          ? isWifiPermissionGrantedAsync.when(
                              data: (isGranted) {
                                return isGranted
                                    ? availableWifiNetworksAsync.when(
                                        data: (wifiNames) {
                                          return wifiNames != null
                                              ? ListView.builder(
                                                  itemCount: wifiNames.length,
                                                  shrinkWrap: true,
                                                  scrollDirection:
                                                      Axis.vertical,
                                                  itemBuilder: (context, index) {
                                                    return ListTile(
                                                      titleAlignment:
                                                          ListTileTitleAlignment
                                                              .center,
                                                      title: Text(
                                                        wifiNames[index],
                                                      ),
                                                      onTap: () {
                                                        WifiConnection.openWifiSettings();
                                                      },
                                                    );
                                                  },
                                                )
                                              : Container();
                                        },
                                        error: (err, stack) =>
                                            Center(child: Text("Error: $err")),
                                        loading: () =>
                                            CircularProgressIndicator(
                                              color: Theme.of(context)
                                                  .progressIndicatorTheme
                                                  .circularTrackColor,
                                            ),
                                      )
                                    : Container();
                              },
                              error: (err, stack) =>
                                  Center(child: Text("Error: $err")),
                              loading: () => CircularProgressIndicator(
                                color: Theme.of(
                                  context,
                                ).progressIndicatorTheme.circularTrackColor,
                              ),
                            )
                          : Container(),

                      if (!isConnected) SizedBox(height: 10),

                      TextButton(
                        onPressed: () {
                          WifiConnectionManager.openWifiSettings();
                        },
                        style: TextButton.styleFrom(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer,
                        ),
                        child: Text(
                          isOn == null
                              ? "Open Wi-Fi Settings"
                              : !isOn
                              ? "Enable Wi-Fi"
                              : "Wi-Fi Settings",
                        ),
                      ),
                    ],
                  );
                },
                error: (err, stack) => Center(child: Text("Error: $err")),
                loading: () => CircularProgressIndicator(
                  color: Theme.of(
                    context,
                  ).progressIndicatorTheme.circularTrackColor,
                ),
              ),
            ],
          );
        },
        error: (err, stack) => Center(child: Text("Error: $err")),
        loading: () => CircularProgressIndicator(
          color: Theme.of(context).progressIndicatorTheme.circularTrackColor,
        ),
      ),
    );
  }
}
