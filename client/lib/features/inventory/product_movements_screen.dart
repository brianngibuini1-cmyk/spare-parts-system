import 'package:flutter/material.dart';

import 'inventory_controller.dart';
import 'inventory_models.dart';

Future<bool?> showStockAdjustmentDialog({
  required BuildContext context,
  required InventoryController controller,
  required String productId,
  required String productName,
  required String currentQuantityOnHand,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => _StockAdjustmentDialog(
      controller: controller,
      productId: productId,
      productName: productName,
      currentQuantityOnHand: currentQuantityOnHand,
    ),
  );
}

class _StockAdjustmentDialog extends StatefulWidget {
  const _StockAdjustmentDialog({
    required this.controller,
    required this.productId,
    required this.productName,
    required this.currentQuantityOnHand,
  });

  final InventoryController controller;
  final String productId;
  final String productName;
  final String currentQuantityOnHand;

  @override
  State<_StockAdjustmentDialog> createState() => _StockAdjustmentDialogState();
}

class _StockAdjustmentDialogState extends State<_StockAdjustmentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _deltaController = TextEditingController();
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _deltaController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Adjust stock: ${widget.productName}'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Current on hand: ${formatQuantityDisplay(widget.currentQuantityOnHand)}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _deltaController,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Quantity delta (e.g. -2 or 5) *',
                  border: OutlineInputBorder(),
                ),
                validator: validateSignedNonZeroDecimalInput,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _reasonController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Reason *',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a reason for this adjustment.';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            if (!_formKey.currentState!.validate()) {
              return;
            }
            final posted = await widget.controller.submitStockAdjustment(
              productId: widget.productId,
              quantityDelta: _deltaController.text,
              reason: _reasonController.text,
            );
            if (context.mounted) {
              Navigator.of(context).pop(posted != null);
            }
          },
          child: const Text('Post adjustment'),
        ),
      ],
    );
  }
}

class ProductMovementsScreen extends StatefulWidget {
  const ProductMovementsScreen({
    required this.controller,
    required this.productId,
    required this.productName,
    super.key,
  });

  final InventoryController controller;
  final String productId;
  final String productName;

  @override
  State<ProductMovementsScreen> createState() => _ProductMovementsScreenState();
}

class _ProductMovementsScreenState extends State<ProductMovementsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadProductMovements(widget.productId);
    });
  }

  Future<void> _openAdjustment(ProductMovementsResult detail) async {
    final adjusted = await showStockAdjustmentDialog(
      context: context,
      controller: widget.controller,
      productId: detail.productId,
      productName: detail.name,
      currentQuantityOnHand: detail.quantityOnHand,
    );
    if (!mounted) return;
    if (adjusted == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.actionMessage ?? 'Stock adjustment posted.',
          ),
        ),
      );
    } else if (widget.controller.actionError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.controller.actionError!)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.productName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                widget.controller.loadProductMovements(widget.productId),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final ctrl = widget.controller;
          final detail = ctrl.movementsResult;
          if (ctrl.isLoadingMovements && detail == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (ctrl.movementsError != null && detail == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(ctrl.movementsError!),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () =>
                        ctrl.loadProductMovements(widget.productId),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }
          if (detail == null) {
            return const Center(child: Text('No movement data available.'));
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                margin: const EdgeInsets.all(16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              detail.name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Ref: ${detail.internalReference}'
                              '${detail.manufacturerPartNumber != null ? ' • MPN: ${detail.manufacturerPartNumber}' : ''}',
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'On hand: ${formatQuantityDisplay(detail.quantityOnHand)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      if (ctrl.isOwner)
                        FilledButton.icon(
                          onPressed: ctrl.isSubmittingAdjustment
                              ? null
                              : () => _openAdjustment(detail),
                          icon: const Icon(Icons.tune),
                          label: const Text('Adjust stock'),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Movement ledger (${detail.total})',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: detail.items.isEmpty
                    ? const Center(
                        child: Text('No stock movements recorded yet.'),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: detail.items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final m = detail.items[index];
                          final isReceipt = m.movementType == 'receipt';
                          final isPositive = !m.quantityDelta.startsWith('-');
                          final deltaLabel = isPositive
                              ? '+${formatQuantityDisplay(m.quantityDelta)}'
                              : formatQuantityDisplay(m.quantityDelta);
                          return Card(
                            child: ListTile(
                              leading: Icon(
                                isReceipt
                                    ? Icons.local_shipping_outlined
                                    : Icons.tune,
                              ),
                              title: Row(
                                children: [
                                  Chip(
                                    label: Text(
                                      isReceipt ? 'Receipt' : 'Adjustment',
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    deltaLabel,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: isPositive
                                          ? Colors.green.shade700
                                          : Colors.red.shade700,
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (m.sourceReference != null)
                                    Text('Reference: ${m.sourceReference}'),
                                  if (m.supplierName != null)
                                    Text('Supplier: ${m.supplierName}'),
                                  if (m.reason != null)
                                    Text('Reason: ${m.reason}'),
                                  Text(
                                    'By ${m.actorLogin} • ${m.createdAt.toLocal()}',
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
