import 'package:flutter/material.dart';

import '../inventory/inventory_models.dart';
import '../sales/sales_models.dart';
import 'reports_controller.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    required this.controller,
    super.key,
  });

  final ReportsController controller;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final TextEditingController _fromController = TextEditingController();
  final TextEditingController _toController = TextEditingController();
  final FocusNode _fromFocusNode = FocusNode();
  final FocusNode _toFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncDateControllers);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.controller.isOwner) {
        await widget.controller.loadReports();
        if (mounted) {
          _syncDateControllers();
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant ReportsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncDateControllers);
      widget.controller.addListener(_syncDateControllers);
      _syncDateControllers();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncDateControllers);
    _fromController.dispose();
    _toController.dispose();
    _fromFocusNode.dispose();
    _toFocusNode.dispose();
    super.dispose();
  }

  void _syncDateControllers() {
    if (!mounted) {
      return;
    }
    if (widget.controller.fromDate != null &&
        _fromController.text.isEmpty &&
        !_fromFocusNode.hasFocus) {
      _fromController.text = widget.controller.fromDate!;
    }
    if (widget.controller.toDate != null &&
        _toController.text.isEmpty &&
        !_toFocusNode.hasFocus) {
      _toController.text = widget.controller.toDate!;
    }
  }

  Future<void> _applyDateRange() async {
    await widget.controller.loadReports(
      nextFromDate: _fromController.text,
      nextToDate: _toController.text,
    );
  }

  Widget _buildSectionLoadingCard(String label) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(label),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionErrorCard(
    ThemeData theme,
    String message,
    VoidCallback onRetry,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        if (!ctrl.isOwner) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Owner access is required to view operational reports.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () => ctrl.loadReports(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Operational Reports (not accounting statements)',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh reports',
                    onPressed: ctrl.isLoading ? null : () => ctrl.loadReports(),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Date Range (Africa/Nairobi)',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _fromController,
                              focusNode: _fromFocusNode,
                              decoration: const InputDecoration(
                                labelText: 'From (YYYY-MM-DD)',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _toController,
                              focusNode: _toFocusNode,
                              decoration: const InputDecoration(
                                labelText: 'To (YYYY-MM-DD)',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: ctrl.isLoading ? null : _applyDateRange,
                            child: const Text('Apply'),
                          ),
                        ],
                      ),
                      if (ctrl.errorMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          ctrl.errorMessage!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (ctrl.isLoadingSales && ctrl.salesReport == null)
                _buildSectionLoadingCard('Loading sales summary...')
              else if (ctrl.salesErrorMessage != null)
                _buildSectionErrorCard(
                  theme,
                  ctrl.salesErrorMessage!,
                  ctrl.retrySalesReport,
                )
              else if (ctrl.salesReport != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (ctrl.isLoadingSales) ...[
                          const LinearProgressIndicator(),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          'Sales Summary (${ctrl.salesReport!.fromDate} to ${ctrl.salesReport!.toDate})',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Completed sales: ${ctrl.salesReport!.completedSalesCount}',
                        ),
                        Text(
                          'Total sales: KES ${formatMoneyDisplay(ctrl.salesReport!.totalSalesValue)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Cash total: KES ${formatMoneyDisplay(ctrl.salesReport!.cashTotal)}',
                        ),
                        Text(
                          'M-PESA (Manual) total: KES ${formatMoneyDisplay(ctrl.salesReport!.mpesaTotal)}',
                        ),
                        const SizedBox(height: 6),
                        Text(
                          ctrl.salesReport!.mpesaNote,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No sales summary available.'),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Inventory Balances (${ctrl.totalBalances})',
                    style: theme.textTheme.titleMedium,
                  ),
                  if (ctrl.totalBalances > 0)
                    Text(
                      'Showing ${ctrl.balances.length} of ${ctrl.totalBalances}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (ctrl.isLoadingBalances && ctrl.balances.isEmpty)
                _buildSectionLoadingCard('Loading inventory balances...')
              else if (ctrl.balancesErrorMessage != null)
                _buildSectionErrorCard(
                  theme,
                  ctrl.balancesErrorMessage!,
                  ctrl.retryBalances,
                )
              else if (ctrl.balances.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No approved products in inventory report.'),
                  ),
                )
              else ...[
                if (ctrl.isLoadingBalances) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                ],
                ...ctrl.balances.map(
                  (item) => Card(
                    child: ListTile(
                      title: Text(item.name),
                      subtitle: Text(
                        '${item.internalReference}'
                        '${item.manufacturerPartNumber != null ? ' • MPN: ${item.manufacturerPartNumber}' : ''}'
                        ' • Unit: ${item.unitOfMeasure ?? 'Unconfigured'}'
                        ' • Price: KES ${formatMoneyDisplay(item.sellingPrice)}',
                      ),
                      trailing: Text(
                        formatQuantityDisplay(item.quantityOnHand),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                if (ctrl.balancesLoadMoreError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      ctrl.balancesLoadMoreError!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (ctrl.totalBalances > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: OutlinedButton(
                      onPressed: (!ctrl.hasMoreBalances ||
                              ctrl.isLoadingMoreBalances ||
                              ctrl.isLoadingBalances)
                          ? null
                          : ctrl.loadMoreBalances,
                      child: Text(
                        ctrl.isLoadingMoreBalances
                            ? 'Loading balances...'
                            : (ctrl.hasMoreBalances
                                ? 'Load more balances'
                                : 'All balances loaded'),
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Stock Movement History (${ctrl.totalMovements})',
                    style: theme.textTheme.titleMedium,
                  ),
                  if (ctrl.totalMovements > 0)
                    Text(
                      'Showing ${ctrl.movements.length} of ${ctrl.totalMovements}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (ctrl.isLoadingMovements && ctrl.movements.isEmpty)
                _buildSectionLoadingCard('Loading stock movements...')
              else if (ctrl.movementsErrorMessage != null)
                _buildSectionErrorCard(
                  theme,
                  ctrl.movementsErrorMessage!,
                  ctrl.retryMovements,
                )
              else if (ctrl.movements.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No stock movements found for this range.'),
                  ),
                )
              else ...[
                if (ctrl.isLoadingMovements) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                ],
                ...ctrl.movements.map(
                  (mov) => Card(
                    child: ListTile(
                      title: Text(
                        '${mov.productName} (${mov.movementType.toUpperCase()})',
                      ),
                      subtitle: Text(
                        'Ref: ${mov.sourceReference ?? mov.sourceId} • By: ${mov.actorLogin}\n'
                        '${mov.createdAt.toLocal().toString().split('.').first}'
                        '${mov.reason != null ? ' • ${mov.reason}' : ''}',
                      ),
                      isThreeLine: true,
                      trailing: Text(
                        formatQuantityDisplay(mov.quantityDelta),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                if (ctrl.movementsLoadMoreError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      ctrl.movementsLoadMoreError!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (ctrl.totalMovements > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: OutlinedButton(
                      onPressed: (!ctrl.hasMoreMovements ||
                              ctrl.isLoadingMoreMovements ||
                              ctrl.isLoadingMovements)
                          ? null
                          : ctrl.loadMoreMovements,
                      child: Text(
                        ctrl.isLoadingMoreMovements
                            ? 'Loading movements...'
                            : (ctrl.hasMoreMovements
                                ? 'Load more movements'
                                : 'All movements loaded'),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
