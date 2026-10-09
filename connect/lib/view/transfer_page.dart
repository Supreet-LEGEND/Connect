import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect/view/widgets/transfer_list_view.dart';

class TransferPage extends ConsumerStatefulWidget {
  const TransferPage({super.key});

  @override
  ConsumerState<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends ConsumerState<TransferPage> 
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isWide = MediaQuery.of(context).size.width >= 600;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfers'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(
              icon: Icon(Icons.cloud_upload_outlined),
              text: 'Outgoing',
            ),
            Tab(
              icon: Icon(Icons.cloud_download_outlined),
              text: 'Incoming',
            ),
          ],
        ),
        actions: [
          // Filter button
          PopupMenuButton<TransferFilter>(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filter transfers',
            onSelected: (filter) {
              // TODO: Implement filter state management
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: TransferFilter.all,
                child: Text('All'),
              ),
              const PopupMenuItem(
                value: TransferFilter.active,
                child: Text('Active'),
              ),
              const PopupMenuItem(
                value: TransferFilter.completed,
                child: Text('Completed'),
              ),
              const PopupMenuItem(
                value: TransferFilter.failed,
                child: Text('Failed'),
              ),
            ],
          ),
        ],
      ),
      body: isWide 
          ? _buildWideLayout()
          : _buildNarrowLayout(),
    );
  }

  Widget _buildNarrowLayout() {
    return TabBarView(
      controller: _tabController,
      children: [
        TransferListView(showOutgoing: true),
        TransferListView(showOutgoing: false),
      ],
    );
  }

  Widget _buildWideLayout() {
    return Row(
      children: [
        // Outgoing transfers (left panel)
        Expanded(
          child: Column(
            children: [
              _buildSectionHeader('Outgoing Transfers', Icons.cloud_upload_outlined),
              const Divider(height: 1),
              Expanded(
                child: TransferListView(showOutgoing: true),
              ),
            ],
          ),
        ),
        // Vertical divider
        const VerticalDivider(width: 1, thickness: 1),
        // Incoming transfers (right panel)
        Expanded(
          child: Column(
            children: [
              _buildSectionHeader('Incoming Transfers', Icons.cloud_download_outlined),
              const Divider(height: 1),
              Expanded(
                child: TransferListView(showOutgoing: false),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}