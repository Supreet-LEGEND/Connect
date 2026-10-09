import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/view/transfer_page.dart';
import 'package:connect/view/settings_page.dart';
import 'package:connect/view/about_page.dart';

class AppEndDrawer extends ConsumerWidget {
  const AppEndDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // Drawer Header
            DrawerHeader(
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(
                    Icons.cable,
                    size: 48,
                    color: colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Connect',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'File Transfer & Device Connection',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            
            // Navigation Items
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _DrawerItem(
                    icon: Icons.download_for_offline,
                    label: 'Transfers',
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).pushNamed('/transfers');
                    },
                  ),
                  _DrawerItem(
                    icon: Icons.settings,
                    label: 'Settings',
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).pushNamed('/settings');
                    },
                  ),
                  _DrawerItem(
                    icon: Icons.info_outline,
                    label: 'About',
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).pushNamed('/about');
                    },
                  ),
                  const Divider(),
                  _DrawerItem(
                    icon: Icons.help_outline,
                    label: 'Help & Feedback',
                    onTap: () {
                      Navigator.of(context).pop();
                      // TODO: Open help/feedback
                    },
                  ),
                ],
              ),
            ),
            
            // Footer
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    'Version 1.0.0',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Built with Flutter',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      leading: Icon(icon, color: colorScheme.onSurfaceVariant),
      title: Text(
        label,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: colorScheme.onSurface,
        ),
      ),
      onTap: onTap,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }
}