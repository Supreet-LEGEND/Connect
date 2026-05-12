import 'package:connect/view/widgets/device_discovery_and_connection_widget.dart';
import 'package:connect/view/widgets/wifi_connection_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Connecter',
          style: TextStyle(
            // fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),

        centerTitle: true,
      ),
      body: Container(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            ConnectionWidget(),
            SizedBox(height: 16),
            DeviceDiscoveryAndConnectionWidget(),
          ],
        ),
      ),
    );
  }
}
