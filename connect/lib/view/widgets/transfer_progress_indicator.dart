import 'package:flutter/material.dart';
import 'package:connect/network/transfer/transfer.dart';

class TransferProgressIndicator extends StatelessWidget {
  final Transfer transfer;
  final double? speedBytesPerSecond;
  final Duration? estimatedTimeRemaining;
  final bool showSpeedAndEta;

  const TransferProgressIndicator({
    super.key,
    required this.transfer,
    this.speedBytesPerSecond,
    this.estimatedTimeRemaining,
    this.showSpeedAndEta = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final progress = transfer.progress.clamp(0.0, 1.0);
    final isCompleted = transfer.isCompleted;
    final isFailed = transfer.isFailed;
    final isPaused = transfer.isPaused;

    Color progressColor;
    if (isFailed) {
      progressColor = colorScheme.error;
    } else if (isCompleted) {
      progressColor = Colors.green;
    } else if (isPaused) {
      progressColor = Colors.orange;
    } else {
      progressColor = colorScheme.primary;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(progressColor),
            semanticsLabel: 'Transfer progress',
            semanticsValue: '${(progress * 100).toStringAsFixed(0)}%',
          ),
        ),
        const SizedBox(height: 8),
        // Progress text and stats
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${(progress * 100).toStringAsFixed(1)}%',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: progressColor,
              ),
            ),
            if (showSpeedAndEta && (speedBytesPerSecond != null || estimatedTimeRemaining != null))
              Row(
                children: [
                  if (speedBytesPerSecond != null && speedBytesPerSecond! > 0) ...[
                    Icon(
                      Icons.speed,
                      size: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatSpeed(speedBytesPerSecond!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (estimatedTimeRemaining != null && estimatedTimeRemaining!.inSeconds > 0) ...[
                    Icon(
                      Icons.timer_outlined,
                      size: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatDuration(estimatedTimeRemaining!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ],
    );
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    } else if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }
}