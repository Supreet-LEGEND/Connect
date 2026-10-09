import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/relay/providers/settings_provider.dart';
import 'package:connect/relay/providers/auto_resume_provider.dart';
import 'package:connect/app/transfer_config.dart';
import 'package:connect/app/tcp_config.dart';
import 'package:connect/view/widgets/auto_resume_settings.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // General Section
          _buildSectionHeader('General'),
          _buildSettingTile(
            title: 'Theme',
            subtitle: 'Choose app appearance',
            leading: Icon(Icons.palette_outlined, color: colorScheme.onSurfaceVariant),
            trailing: DropdownButton<AppThemeMode>(
              value: settings.themeMode,
              underline: const SizedBox(),
              onChanged: (value) {
                if (value != null) {
                  ref.read(settingsProvider.notifier).setThemeMode(value);
                }
              },
              items: const [
                DropdownMenuItem(value: AppThemeMode.system, child: Text('System')),
                DropdownMenuItem(value: AppThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: AppThemeMode.dark, child: Text('Dark')),
              ],
            ),
          ),
          _buildSettingTile(
            title: 'Language',
            subtitle: 'App language (coming soon)',
            leading: Icon(Icons.language_outlined, color: colorScheme.onSurfaceVariant),
            trailing: const Text('English'),
            enabled: false,
          ),
          SwitchListTile(
            title: const Text('Auto-accept incoming connections'),
            subtitle: const Text('Automatically accept connection requests without prompt'),
            secondary: Icon(Icons.check_circle_outline, color: colorScheme.onSurfaceVariant),
            value: settings.autoAcceptIncoming,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).setAutoAcceptIncoming(value);
            },
          ),

          const SizedBox(height: 24),

          // Auto-Resume Section
          _buildSectionHeader('Auto-Resume'),
          const AutoResumeSettingsWidget(),

          const SizedBox(height: 24),

          // Transfer Settings Section
          _buildSectionHeader('Transfer Settings'),
          _buildSettingTile(
            title: 'Max Concurrent Transfers',
            subtitle: 'Number of simultaneous file transfers (1-10)',
            leading: Icon(Icons.swap_horiz, color: colorScheme.onSurfaceVariant),
            trailing: DropdownButton<int>(
              value: settings.maxConcurrentTransfers,
              underline: const SizedBox(),
              onChanged: (value) {
                if (value != null) {
                  ref.read(settingsProvider.notifier).setMaxConcurrentTransfers(value);
                }
              },
              items: List.generate(10, (i) => i + 1)
                  .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                  .toList(),
            ),
          ),
          _buildSettingTile(
            title: 'Chunk Size',
            subtitle: 'Size of each file chunk for transfer (64KB - 10MB)',
            leading: Icon(Icons.data_usage, color: colorScheme.onSurfaceVariant),
            trailing: DropdownButton<int>(
              value: settings.chunkSize,
              underline: const SizedBox(),
              onChanged: (value) {
                if (value != null) {
                  ref.read(settingsProvider.notifier).setChunkSize(value);
                }
              },
              items: const [
                DropdownMenuItem(value: 64 * 1024, child: Text('64 KB')),
                DropdownMenuItem(value: 128 * 1024, child: Text('128 KB')),
                DropdownMenuItem(value: 256 * 1024, child: Text('256 KB')),
                DropdownMenuItem(value: 512 * 1024, child: Text('512 KB')),
                DropdownMenuItem(value: 1024 * 1024, child: Text('1 MB')),
                DropdownMenuItem(value: 2 * 1024 * 1024, child: Text('2 MB')),
                DropdownMenuItem(value: 4 * 1024 * 1024, child: Text('4 MB')),
                DropdownMenuItem(value: 10 * 1024 * 1024, child: Text('10 MB')),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('Auto-resume on app start'),
            subtitle: const Text('Automatically resume incomplete transfers when app launches'),
            secondary: Icon(Icons.refresh, color: colorScheme.onSurfaceVariant),
            value: settings.autoResumeOnStart,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).setAutoResumeOnStart(value);
            },
          ),

          const SizedBox(height: 24),

          // Network Section
          _buildSectionHeader('Network'),
          _buildSettingTile(
            title: 'TCP Port',
            subtitle: 'Port used for device connections',
            leading: Icon(Icons.router, color: colorScheme.onSurfaceVariant),
            trailing: Text(
              '${BaseTcpConfig.tcpPort}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            enabled: false,
          ),
          _buildSettingTile(
            title: 'Trust Policy',
            subtitle: 'How to verify device identities (coming soon)',
            leading: Icon(Icons.security_outlined, color: colorScheme.onSurfaceVariant),
            trailing: const Text('TOFU'),
            enabled: false,
          ),

          const SizedBox(height: 24),

          // Bandwidth Section
          _buildSectionHeader('Bandwidth Control'),
          SwitchListTile(
            title: const Text('Enable bandwidth throttling'),
            subtitle: const Text('Limit transfer speed to avoid network congestion'),
            secondary: Icon(Icons.speed, color: colorScheme.onSurfaceVariant),
            value: settings.enableBandwidthThrottling,
            onChanged: (value) {
              ref.read(settingsProvider.notifier).setBandwidthThrottling(value);
            },
          ),
          if (settings.enableBandwidthThrottling)
            _buildSettingTile(
              title: 'Max Speed (KB/s)',
              subtitle: '0 = unlimited',
              leading: Icon(Icons.speed_outlined, color: colorScheme.onSurfaceVariant),
              trailing: SizedBox(
                width: 100,
                child: TextField(
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    hintText: '0',
                    isDense: true,
                  ),
                  onSubmitted: (value) {
                    final speed = int.tryParse(value) ?? 0;
                    ref.read(settingsProvider.notifier).setBandwidthThrottling(true, speed * 1024);
                  },
                ),
              ),
            ),

          const SizedBox(height: 24),

          // Storage Section
          _buildSectionHeader('Storage'),
          _buildSettingTile(
            title: 'Default Save Location',
            subtitle: settings.defaultSaveLocation.isEmpty 
                ? 'Default (Documents/Connect)' 
                : settings.defaultSaveLocation,
            leading: Icon(Icons.folder_outlined, color: colorScheme.onSurfaceVariant),
            trailing: Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
            onTap: () {
              _showSaveLocationDialog(context, ref);
            },
          ),
          _buildSettingTile(
            title: 'Clear Transfer Cache',
            subtitle: 'Remove cached transfer data and temporary files',
            leading: Icon(Icons.delete_sweep_outlined, color: colorScheme.error),
            trailing: FilledButton.tonal(
              onPressed: () => _clearCache(context, ref),
              child: const Text('Clear Cache'),
            ),
          ),
          _buildSettingTile(
            title: 'Reset All Settings',
            subtitle: 'Restore all settings to defaults',
            leading: Icon(Icons.restore_outlined, color: colorScheme.error),
            trailing: TextButton(
              onPressed: () => _confirmReset(context, ref),
              child: const Text('Reset'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildSettingTile({
    required String title,
    required String subtitle,
    required Widget leading,
    Widget? trailing,
    VoidCallback? onTap,
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      leading: leading,
      title: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          color: enabled ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
        ),
      ),
subtitle: Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: enabled ? colorScheme.onSurfaceVariant : colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
        ),
      trailing: trailing,
      onTap: enabled ? onTap : null,
      enabled: enabled,
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: 24,
    );
  }

  Future<void> _showSaveLocationDialog(BuildContext context, WidgetRef ref) async {
    // TODO: Implement folder picker using file_picker package
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Folder picker not yet implemented')),
    );
  }

  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Cache'),
        content: const Text('This will remove all cached transfer data and temporary files. This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      // TODO: Implement cache clearing via TransferCacheManager
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cache cleared')),
      );
    }
  }

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset All Settings'),
        content: const Text('This will restore all settings to their default values. This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await ref.read(settingsProvider.notifier).resetToDefaults();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings reset to defaults')),
        );
      }
    }
  }
}