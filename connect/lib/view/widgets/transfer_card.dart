import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/relay/providers/transfer_providers.dart';
import 'transfer_progress_indicator.dart';
import 'transfer_actions.dart';

class TransferCard extends ConsumerWidget {
  final Transfer transfer;
  final double? speedBytesPerSecond;
  final Duration? estimatedTimeRemaining;
  final VoidCallback? onTap;

  const TransferCard({
    super.key,
    required this.transfer,
    this.speedBytesPerSecond,
    this.estimatedTimeRemaining,
    this.onTap,
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

    // Determine card color based on status
    Color? cardColor;
    if (isFailed) {
      cardColor = colorScheme.errorContainer.withValues(alpha: 0.3);
    } else if (isCompleted) {
      cardColor = colorScheme.primaryContainer.withValues(alpha: 0.3);
    } else if (isPaused) {
      cardColor = colorScheme.secondaryContainer.withValues(alpha: 0.3);
    }

    // Get file name and size
    String fileName = 'Unknown file';
    int? totalBytes;
    int? transferredBytes;
    String? deviceName;

    if (transfer is FileTransfer) {
      final ft = transfer as FileTransfer;
      fileName = ft.fileName ?? 'Unknown file';
      totalBytes = ft.totalBytes;
      transferredBytes = ft.transferredBytes;
    } else if (transfer is ReceivingFileTransfer) {
      final ft = transfer as ReceivingFileTransfer;
      fileName = ft.fileName;
      totalBytes = ft.fileSize;
      transferredBytes = (ft.fileSize * ft.progress).round();
    }

    // Get device name from connection manager if available
    deviceName = _getDeviceName(transfer.deviceId);

    // Status chip
    Widget statusChip = _buildStatusChip(context);

    return Card(
      color: cardColor,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: File name and status
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            if (deviceName != null) ...[
                              Icon(
                                Icons.device_unknown,
                                size: 14,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                deviceName,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const SizedBox(width: 12),
                            statusChip,
                          ],
                        ),
                      ],
                    ),
                  ),
                  TransferActions(transfer: transfer),
                ],
              ),
              
              const SizedBox(height: 12),
              
              // Progress bar and stats
              TransferProgressIndicator(
                transfer: transfer,
                speedBytesPerSecond: speedBytesPerSecond,
                estimatedTimeRemaining: estimatedTimeRemaining,
              ),
              
              if (totalBytes != null && totalBytes! > 0) ...[
                const SizedBox(height: 8),
                // Byte count
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${_formatBytes(transferredBytes ?? 0)} / ${_formatBytes(totalBytes!)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (isTransferring || isReconnecting)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                        ),
                      ),
                  ],
                ),
              ],
              
              // Error message if failed
              if (isFailed && transfer.error != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          transfer.error.toString(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final status = transfer.status;

    Color chipColor;
    Color textColor;
    String label;
    IconData icon;

    switch (status) {
      case TransferStatus.completed:
        chipColor = Colors.green.withValues(alpha: 0.2);
        textColor = Colors.green;
        label = 'Completed';
        icon = Icons.check_circle;
        break;
      case TransferStatus.failed:
        chipColor = colorScheme.errorContainer;
        textColor = colorScheme.onErrorContainer;
        label = 'Failed';
        icon = Icons.error;
        break;
      case TransferStatus.paused:
        chipColor = Colors.orange.withValues(alpha: 0.2);
        textColor = Colors.orange;
        label = 'Paused';
        icon = Icons.pause_circle;
        break;
      case TransferStatus.transferring:
        chipColor = colorScheme.primaryContainer;
        textColor = colorScheme.onPrimaryContainer;
        label = 'Transferring';
        icon = Icons.cloud_upload;
        break;
      case TransferStatus.queued:
        chipColor = colorScheme.surfaceContainerHighest;
        textColor = colorScheme.onSurfaceVariant;
        label = 'Queued';
        icon = Icons.schedule;
        break;
      case TransferStatus.reconnecting:
        chipColor = colorScheme.secondaryContainer;
        textColor = colorScheme.onSecondaryContainer;
        label = 'Reconnecting';
        icon = Icons.sync;
        break;
      case TransferStatus.cancelled:
        chipColor = colorScheme.surfaceContainerHighest;
        textColor = colorScheme.onSurfaceVariant;
        label = 'Cancelled';
        icon = Icons.cancel;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: chipColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: textColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _getDeviceName(String deviceId) {
    // TODO: Get device name from connection manager or peer registry
    // For now, return a shortened device ID
    if (deviceId.length > 12) {
      return '${deviceId.substring(0, 8)}...${deviceId.substring(deviceId.length - 4)}';
    }
    return deviceId;
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '$bytes B';
    }
  }
}