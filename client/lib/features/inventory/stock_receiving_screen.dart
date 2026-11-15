import 'package:flutter/material.dart';

import '../catalogue/catalogue_models.dart';
import 'inventory_controller.dart';
import 'inventory_models.dart';

class StockReceivingScreen extends StatefulWidget {
  const StockReceivingScreen({
    required this.controller,
    super.key,
  });

  final InventoryController controller;

  @override
  State<StockReceivingScreen> createState() => _StockReceivingScreenState();
}

class _StockReceivingScreenState extends State<StockReceivingScreen> {
  String? _selectedSupplierId;
  bool _useUnlistedSupplier = false;
  final TextEditingController _unlistedSupplierController =
      TextEditingController();
  final TextEditingController _deliveryNoteController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  final List<GoodsReceiptLineInput> _lines = <GoodsReceiptLineInput>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadReceivingLookups();
    });
  }

  @override
  void dispose() {
    _unlistedSupplierController.dispose();
    _deliveryNoteController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _addLineDialog(List<ProductItem> products) async {
    if (products.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No approved products available to receive.'),
        ),
      );
      return;
    }

    final line = await showDialog<GoodsReceiptLineInput>(
      context: context,
      builder: (context) => _AddReceiptLineDialog(products: products),
    );

    if (line != null && mounted) {
      setState(() {
        _lines.add(line);
      });
    }
  }

  Future<void> _submitReceipt() async {
    if (_lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one item line to receive.')),
      );
      return;
    }

    final receipt = await widget.controller.submitGoodsReceipt(
      supplierId: _useUnlistedSupplier ? null : _selectedSupplierId,
      unlistedSupplierName:
          _useUnlistedSupplier ? _unlistedSupplierController.text : null,
      deliveryNoteReference: _deliveryNoteController.text,
      notes: _notesController.text,
      lines: List<GoodsReceiptLineInput>.unmodifiable(_lines),
    );

    if (!mounted) return;
    if (receipt != null) {
      setState(() {
        _lines.clear();
        _selectedSupplierId = null;
        _useUnlistedSupplier = false;
        _unlistedSupplierController.clear();
        _deliveryNoteController.clear();
        _notesController.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.actionMessage ?? 'Stock receipt posted.',
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
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Receive incoming stock',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Reload products & suppliers',
                    onPressed: ctrl.isLoadingReceivingLookups
                        ? null
                        : ctrl.loadReceivingLookups,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              if (ctrl.receivingLookupsError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    ctrl.receivingLookupsError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use unlisted / walk-in supplier'),
                value: _useUnlistedSupplier,
                onChanged: ctrl.isSubmittingReceipt
                    ? null
                    : (value) => setState(() {
                          _useUnlistedSupplier = value;
                          if (value) {
                            _selectedSupplierId = null;
                          } else {
                            _unlistedSupplierController.clear();
                          }
                        }),
              ),
              if (_useUnlistedSupplier)
                TextField(
                  controller: _unlistedSupplierController,
                  enabled: !ctrl.isSubmittingReceipt,
                  decoration: const InputDecoration(
                    labelText: 'Unlisted supplier name',
                    border: OutlineInputBorder(),
                  ),
                )
              else
                DropdownButtonFormField<String?>(
                  initialValue: _selectedSupplierId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Active supplier (optional)',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('No supplier selected'),
                    ),
                    ...ctrl.activeSuppliers.map(
                      (s) => DropdownMenuItem<String?>(
                        value: s.id,
                        child: Text(s.name, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                  onChanged: ctrl.isSubmittingReceipt
                      ? null
                      : (value) => setState(() => _selectedSupplierId = value),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _deliveryNoteController,
                enabled: !ctrl.isSubmittingReceipt,
                decoration: const InputDecoration(
                  labelText: 'Delivery note / invoice reference',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                enabled: !ctrl.isSubmittingReceipt,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Receipt lines (${_lines.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: ctrl.isSubmittingReceipt
                        ? null
                        : () => _addLineDialog(ctrl.approvedProducts),
                    icon: const Icon(Icons.add),
                    label: const Text('Add product'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_lines.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No items added yet. Tap "Add product" above.'),
                  ),
                )
              else
                ...List<Widget>.generate(_lines.length, (index) {
                  final line = _lines[index];
                  return Card(
                    child: ListTile(
                      title: Text(line.productName),
                      subtitle: Text(
                        'Qty: ${line.quantity} • Unit cost: ${line.unitCost}',
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove line',
                        onPressed: ctrl.isSubmittingReceipt
                            ? null
                            : () => setState(() => _lines.removeAt(index)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                  );
                }),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: ctrl.isSubmittingReceipt ? null : _submitReceipt,
                icon: ctrl.isSubmittingReceipt
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: Text(
                  ctrl.isSubmittingReceipt
                      ? 'Posting receipt...'
                      : 'Submit stock receipt',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AddReceiptLineDialog extends StatefulWidget {
  const _AddReceiptLineDialog({required this.products});

  final List<ProductItem> products;

  @override
  State<_AddReceiptLineDialog> createState() => _AddReceiptLineDialogState();
}

class _AddReceiptLineDialogState extends State<_AddReceiptLineDialog> {
  final _formKey = GlobalKey<FormState>();
  late ProductItem _selectedProduct;
  final _quantityController = TextEditingController(text: '1');
  final _costController = TextEditingController(text: '0');

  @override
  void initState() {
    super.initState();
    _selectedProduct = widget.products.first;
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _costController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add received item'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<ProductItem>(
                initialValue: _selectedProduct,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Approved product *',
                  border: OutlineInputBorder(),
                ),
                items: widget.products
                    .map(
                      (p) => DropdownMenuItem<ProductItem>(
                        value: p,
                        child: Text(
                          p.manufacturerPartNumber != null
                              ? '${p.name} (${p.manufacturerPartNumber})'
                              : p.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedProduct = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _quantityController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Quantity received *',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => validatePositiveDecimalInput(
                  value,
                  fieldLabel: 'a quantity',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _costController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Purchase unit cost *',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => validateNonNegativeDecimalInput(
                  value,
                  fieldLabel: 'a unit cost',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              return;
            }
            Navigator.of(context).pop(
              GoodsReceiptLineInput(
                productId: _selectedProduct.id,
                productName: _selectedProduct.name,
                quantity: _quantityController.text.trim(),
                unitCost: _costController.text.trim(),
              ),
            );
          },
          child: const Text('Add line'),
        ),
      ],
    );
  }
}
