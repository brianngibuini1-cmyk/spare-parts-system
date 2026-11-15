import 'package:flutter/material.dart';

import '../sales/sales_models.dart';
import 'reports_controller.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    required this.controller,
    required this.isOwner,
    this.onNavigateTo,
    super.key,
  });

  final DashboardController controller;
  final bool isOwner;
  final void Function(String destinationLabel)? onNavigateTo;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadDashboard();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        if (ctrl.isLoading && ctrl.summary == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (ctrl.errorMessage != null && ctrl.summary == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(ctrl.errorMessage!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: ctrl.loadDashboard,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }

        final summary = ctrl.summary;
        if (summary == null) {
          return Center(
            child: FilledButton(
              onPressed: ctrl.loadDashboard,
              child: const Text('Load dashboard'),
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: ctrl.loadDashboard,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Daily overview (${summary.businessDate} • ${summary.timezone})',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh dashboard',
                    onPressed: ctrl.isLoading ? null : ctrl.loadDashboard,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        "Today's Sales",
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _MetricRow(
                        label: 'Completed sales',
                        value: '${summary.todayCompletedSalesCount}',
                      ),
                      const SizedBox(height: 6),
                      _MetricRow(
                        label: 'Total sales value',
                        value:
                            'KES ${formatMoneyDisplay(summary.todaySalesTotal)}',
                        bold: true,
                      ),
                      const SizedBox(height: 6),
                      _MetricRow(
                        label: 'Cash sales total',
                        value:
                            'KES ${formatMoneyDisplay(summary.todayCashTotal)}',
                      ),
                      const SizedBox(height: 6),
                      _MetricRow(
                        label: 'M-PESA (Manual) total',
                        value:
                            'KES ${formatMoneyDisplay(summary.todayMpesaTotal)}',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'M-PESA totals reflect manually recorded payments and are not automatically verified.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Inventory Overview',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _MetricRow(
                        label: 'Approved products',
                        value: '${summary.approvedProductsCount}',
                      ),
                      const SizedBox(height: 6),
                      _MetricRow(
                        label: 'Approved products with zero stock',
                        value: '${summary.zeroStockProductsCount}',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: widget.onNavigateTo == null
                                ? null
                                : () => widget.onNavigateTo!('Inventory'),
                            icon: const Icon(Icons.warehouse_outlined),
                            label: const Text('Open inventory'),
                          ),
                          OutlinedButton.icon(
                            onPressed: widget.onNavigateTo == null
                                ? null
                                : () => widget.onNavigateTo!('Sales'),
                            icon: const Icon(Icons.point_of_sale_outlined),
                            label: const Text('New sale'),
                          ),
                          if (widget.isOwner)
                            OutlinedButton.icon(
                              onPressed: widget.onNavigateTo == null
                                  ? null
                                  : () => widget.onNavigateTo!('Reports'),
                              icon: const Icon(Icons.bar_chart_outlined),
                              label: const Text('View reports'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
    this.bold = false,
  });

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.bold)
        : Theme.of(context).textTheme.bodyMedium;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: Text(label, style: style)),
        Text(value, style: style),
      ],
    );
  }
}
