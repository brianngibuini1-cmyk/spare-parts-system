import 'package:flutter/material.dart';

import '../inventory/inventory_models.dart';
import 'sales_models.dart';

class SaleReceiptScreen extends StatelessWidget {
  const SaleReceiptScreen({
    required this.sale,
    super.key,
  });

  final SaleItem sale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Receipt ${sale.receiptNumber}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'BMM Auto Motors',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('Digital Receipt: ${sale.receiptNumber}'),
                  Text('Status: ${sale.status.toUpperCase()}'),
                  Text('Sold by: ${sale.soldByLogin}'),
                  Text('Date: ${sale.soldAt.toLocal()}'),
                  if (sale.paymentReference != null)
                    Text('Payment ref: ${sale.paymentReference}'),
                  if (sale.notes != null) Text('Notes: ${sale.notes}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Items (${sale.lines.length})',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...sale.lines.map(
            (line) => Card(
              child: ListTile(
                title: Text(
                  line.productName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Ref: ${line.productInternalReference}'
                  '${line.manufacturerPartNumber != null ? ' • MPN: ${line.manufacturerPartNumber}' : ''}\n'
                  '${formatQuantityDisplay(line.quantity)} × ${formatMoneyDisplay(line.unitPrice)}',
                ),
                isThreeLine: true,
                trailing: Text(
                  formatMoneyDisplay(line.lineTotal),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _SummaryRow(
                    label: 'Total',
                    value: formatMoneyDisplay(sale.totalAmount),
                    bold: true,
                  ),
                  const SizedBox(height: 6),
                  _SummaryRow(
                    label: 'Payment (${sale.paymentMethod.displayLabel})',
                    value: formatMoneyDisplay(sale.amountTendered),
                  ),
                  if (sale.paymentMethod == PaymentMethod.mpesa) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Recorded manually; not automatically verified.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  _SummaryRow(
                    label: 'Change',
                    value: formatMoneyDisplay(sale.changeGiven),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
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
        Text(label, style: style),
        Text(value, style: style),
      ],
    );
  }
}
