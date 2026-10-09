import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/network/transfer/transfer.dart';
import 'package:connect/relay/providers/transfer_providers.dart';
import 'transfer_card.dart';

enum TransferFilter {
  all,
  active,
  completed,
  failed,
}

class TransferListView extends ConsumerStatefulWidget {
  final bool showOutgoing;
  final TransferFilter filter;

  const TransferListView({
    super.key,
    required this.showOutgoing,
    this.filter = TransferFilter.all,
  });

  @override
  ConsumerState<TransferListView> createState() => _TransferListViewState();
}

class _TransferListViewState extends ConsumerState<TransferListView> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final transfersAsync = ref.watch(activeTransfersProvider);

    return transfersAsync.when(
      data: (transfers) {
        final filteredTransfers = _filterTransfers(transfers);
        
        if (filteredTransfers.isEmpty) {
          return _buildEmptyState(context);
        }

        return RefreshIndicator(
          onRefresh: () async {
            // Invalidate the provider to refresh
            ref.invalidate(activeTransfersProvider);
          },
          child: ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            itemCount: filteredTransfers.length,
            itemBuilder: (context, index) {
              final transfer = filteredTransfers[index];
              return TransferCard(
                transfer: transfer,
                // TODO: Add speed and ETA from transfer controller events
              );
            },
          ),
        );
      },
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Error loading transfers',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                error.toString(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.invalidate(activeTransfersProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Transfer> _filterTransfers(Map<String, Transfer> transfersMap) {
    final transfers = transfersMap.values.toList();
    
    // Filter by direction (outgoing vs incoming)
    var filtered = transfers.where((t) {
      if (widget.showOutgoing) {
        return t is FileTransfer || t is MessageTransfer || t is ControlTransfer;
      } else {
        return t is ReceivingFileTransfer || t is ReceivingMessageTransfer || t is ReceivingControlTransfer;
      }
    }).toList();

    // Apply status filter
    switch (widget.filter) {
      case TransferFilter.active:
        filtered = filtered.where((t) => 
          t.status == TransferStatus.transferring || 
          t.status == TransferStatus.queued ||
          t.status == TransferStatus.paused ||
          t.status == TransferStatus.reconnecting
        ).toList();
        break;
      case TransferFilter.completed:
        filtered = filtered.where((t) => t.isCompleted).toList();
        break;
      case TransferFilter.failed:
        filtered = filtered.where((t) => t.isFailed).toList();
        break;
      case TransferFilter.all:
      default:
        break;
    }

    // Sort: active first (by progress), then completed, then failed
    filtered.sort((a, b) {
      // Active transfers first
      final aActive = a.status == TransferStatus.transferring || 
                      a.status == TransferStatus.queued ||
                      a.status == TransferStatus.paused ||
                      a.status == TransferStatus.reconnecting;
      final bActive = b.status == TransferStatus.transferring || 
                      b.status == TransferStatus.queued ||
                      b.status == TransferStatus.paused ||
                      b.status == TransferStatus.reconnecting;
      
      if (aActive && !bActive) return -1;
      if (!aActive && bActive) return 1;
      
      // Within active, sort by progress (descending)
      if (aActive && bActive) {
        return b.progress.compareTo(a.progress);
      }
      
      // Completed transfers next
      if (a.isCompleted && !b.isCompleted) return -1;
      if (!a.isCompleted && b.isCompleted) return 1;
      
      // Failed last
      return 0;
    });

    return filtered;
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    String message;
    IconData icon;

    if (widget.showOutgoing) {
      message = 'No outgoing transfers yet.\nStart by sending a file to a connected device.';
      icon = Icons.cloud_upload_outlined;
    } else {
      message = 'No incoming transfers.\nFiles received from other devices will appear here.';
      icon = Icons.cloud_download_outlined;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}