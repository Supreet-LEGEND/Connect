import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/relay/providers/transfer_providers.dart';

class TransferActions extends ConsumerWidget {
  final Transfer transfer;

  const TransferActions({
    super.key,
    required this.transfer,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isCompleted = transfer.isCompleted;
    final isFailed = transfer.isFailed;
    final isPaused = transfer.isPaused;
    final isTransferring = transfer.status == TransferStatus.transferring;
    final isQueued = transfer.status == TransferStatus.queued;
    final isReconnecting = transfer.status == TransferStatus.reconnecting;

    // Get controller for actions
    final controllerAsync = ref.watch(transferControllerProvider);

    return controllerAsync.when(
      data: (controller) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pause button
          if (isTransferring || isQueued || isReconnecting)
            IconButton(
              icon: const Icon(Icons.pause),
              tooltip: 'Pause',
              onPressed: () async {
                await controller.pauseTransfer(transfer.id);
              },
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.primaryContainer,
                foregroundColor: colorScheme.onPrimaryContainer,
              ),
            ),
          
          // Resume button
          if (isPaused)
            IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Resume',
              onPressed: () async {
                await controller.resumeTransfer(transfer.id);
              },
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.primaryContainer,
                foregroundColor: colorScheme.onPrimaryContainer,
              ),
            ),
          
          // Cancel button (for active/paused/queued transfers)
          if (!isCompleted && !isFailed)
            IconButton(
              icon: const Icon(Icons.cancel),
              tooltip: 'Cancel',
              onPressed: () async {
                final confirmed = await _showCancelDialog(context);
                if (confirmed && context.mounted) {
                  await controller.cancelTransfer(transfer.id, 'User cancelled');
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.errorContainer,
                foregroundColor: colorScheme.onErrorContainer,
              ),
            ),
          
          // Retry button (for failed transfers)
          if (isFailed)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Retry',
              onPressed: () async {
                // For failed transfers, we'd need to re-initiate
                // This depends on the transfer type
                await _handleRetry(context, ref, controller);
              },
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.primaryContainer,
                foregroundColor: colorScheme.onPrimaryContainer,
              ),
            ),
        ],
      ),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Future<bool> _showCancelDialog(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Transfer'),
        content: const Text('Are you sure you want to cancel this transfer?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep Transfer'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel Transfer'),
          ),
        ],
      ),
    ) ?? false;
  }

  Future<void> _handleRetry(
    BuildContext context,
    WidgetRef ref,
    dynamic controller,
  ) async {
    // For failed transfers, the user would need to initiate a new transfer
    // This is a placeholder for retry logic
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Retry not yet implemented. Please start a new transfer.')),
    );
  }
}