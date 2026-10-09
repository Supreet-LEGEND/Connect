// Auto-resume settings widget
// UI for configuring auto-resume behavior

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/relay/providers/auto_resume_provider.dart';

class AutoResumeSettingsWidget extends ConsumerWidget {
  const AutoResumeSettingsWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(autoResumeConfigProvider);
    final theme = Theme.of(context);
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.autorenew,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Auto-Resume Transfers',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Master toggle
            SwitchListTile(
              title: const Text('Enable Auto-Resume'),
              subtitle: const Text(
                'Automatically resume incomplete transfers when app starts or conditions are met',
              ),
              value: config.enabled,
              onChanged: (value) => ref.read(autoResumeConfigProvider.notifier).setEnabled(value),
              secondary: Icon(
                config.enabled ? Icons.check_circle : Icons.cancel,
                color: config.enabled ? Colors.green : Colors.grey,
              ),
            ),
            
            const Divider(),
            
            // WiFi only
            SwitchListTile(
              title: const Text('WiFi Only'),
              subtitle: const Text(
                'Only resume transfers when connected to WiFi (saves mobile data)',
              ),
              value: config.wifiOnly,
              onChanged: config.enabled 
                  ? (value) => ref.read(autoResumeConfigProvider.notifier).setWifiOnly(value)
                  : null,
            ),
            
            // Charging only
            SwitchListTile(
              title: const Text('Charging Only'),
              subtitle: const Text(
                'Only resume transfers when device is charging (saves battery)',
              ),
              value: config.chargingOnly,
              onChanged: config.enabled
                  ? (value) => ref.read(autoResumeConfigProvider.notifier).setChargingOnly(value)
                  : null,
            ),
            
            const Divider(),
            
            // Max concurrent transfers
            ListTile(
              title: const Text('Max Concurrent Transfers'),
              subtitle: Text(
                'Maximum number of simultaneous background transfers (${config.maxConcurrentTransfers})',
              ),
              trailing: DropdownButton<int>(
                value: config.maxConcurrentTransfers,
                items: List.generate(10, (i) => i + 1).map((i) => DropdownMenuItem(
                  value: i,
                  child: Text(i.toString()),
                )).toList(),
                onChanged: config.enabled
                    ? (value) => ref.read(autoResumeConfigProvider.notifier).setMaxConcurrentTransfers(value!)
                    : null,
              ),
            ),
            
            const Divider(),
            
            // Notifications
            SwitchListTile(
              title: const Text('Notify on Complete'),
              subtitle: const Text('Show notification when a transfer finishes'),
              value: config.notifyOnComplete,
              onChanged: config.enabled
                  ? (value) => ref.read(autoResumeConfigProvider.notifier).setNotifyOnComplete(value)
                  : null,
            ),
            
            SwitchListTile(
              title: const Text('Notify on Error'),
              subtitle: const Text('Show notification when a transfer fails'),
              value: config.notifyOnError,
              onChanged: config.enabled
                  ? (value) => ref.read(autoResumeConfigProvider.notifier).setNotifyOnError(value)
                  : null,
            ),
            
            const SizedBox(height: 16),
            
            // Info text
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'How Auto-Resume Works',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildInfoRow('•', 'Transfers paused or interrupted are saved automatically'),
                  _buildInfoRow('•', 'On app restart, incomplete transfers are detected'),
                  _buildInfoRow('•', 'Resume conditions: ${config.enabled ? "enabled" : "disabled"}'),
                  if (config.wifiOnly) _buildInfoRow('•', 'Requires WiFi connection'),
                  if (config.chargingOnly) _buildInfoRow('•', 'Requires device charging'),
                  _buildInfoRow('•', 'Max ${config.maxConcurrentTransfers} concurrent transfers'),
                  _buildInfoRow('•', 'Check interval: every 5 minutes'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildInfoRow(String bullet, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(bullet, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 4),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

/// Quick auto-resume toggle for app bar or drawer
class AutoResumeToggle extends ConsumerWidget {
  const AutoResumeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(autoResumeConfigProvider);
    
    return IconButton(
      icon: Icon(
        config.enabled ? Icons.autorenew : Icons.autorenew,
        color: config.enabled ? Theme.of(context).colorScheme.primary : Colors.grey,
      ),
      tooltip: config.enabled ? 'Auto-resume enabled' : 'Auto-resume disabled',
      onPressed: () => ref.read(autoResumeConfigProvider.notifier).setEnabled(!config.enabled),
    );
  }
}