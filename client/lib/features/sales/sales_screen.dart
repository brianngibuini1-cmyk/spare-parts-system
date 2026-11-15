import 'package:flutter/material.dart';

import '../inventory/inventory_models.dart';
import 'sale_receipt_screen.dart';
import 'sales_controller.dart';
import 'sales_models.dart';

enum SalesSection {
  newSale,
  receipts,
}

class SalesScreen extends StatefulWidget {
  const SalesScreen({
    required this.controller,
    this.initialSection = SalesSection.newSale,
    this.onSectionChanged,
    super.key,
  });

  final SalesController controller;
  final SalesSection initialSection;
  final void Function(SalesSection section)? onSectionChanged;

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  late SalesSection _section;
  final List<SaleLineInput> _cart = <SaleLineInput>[];
  PaymentMethod _paymentMethod = PaymentMethod.cash;
  final TextEditingController _tenderedController = TextEditingController();
  final TextEditingController _paymentRefController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _receiptSearchController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadAvailableProducts();
      widget.controller.loadSales();
    });
  }

  @override
  void didUpdateWidget(covariant SalesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection != widget.initialSection) {
      _section = widget.initialSection;
    }
  }

  @override
  void dispose() {
    _tenderedController.dispose();
    _paymentRefController.dispose();
    _notesController.dispose();
    _receiptSearchController.dispose();
    super.dispose();
  }

  BigInt get _cartTotalScaled4 {
    var total = BigInt.zero;
    for (final line in _cart) {
      total += computeLineTotalScaled4(line.quantity, line.unitPrice);
    }
    return total;
  }

  Future<void> _addProductToCart(List<InventoryBalanceItem> products) async {
    final existingIds = _cart.map((l) => l.productId).toSet();
    final selectable = products
        .where(
          (p) =>
              !existingIds.contains(p.productId) &&
              parseScaled4(p.quantityOnHand) > BigInt.zero,
        )
        .toList(growable: false);

    if (selectable.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No additional in-stock approved products available.'),
        ),
      );
      return;
    }

    final line = await showDialog<SaleLineInput>(
      context: context,
      builder: (context) => _AddSaleLineDialog(products: selectable),
    );

    if (line != null && mounted) {
      setState(() {
        _cart.add(line);
        if (_tenderedController.text.trim().isEmpty ||
            _paymentMethod != PaymentMethod.cash) {
          _tenderedController.text = formatScaled4(_cartTotalScaled4);
        }
      });
    }
  }

  Future<void> _submitSale() async {
    if (_cart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one product to the sale.')),
      );
      return;
    }
    final tenderedErr = validateNonNegativeDecimalInput(
      _tenderedController.text,
      fieldLabel: 'an amount tendered',
    );
    if (tenderedErr != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tenderedErr)),
      );
      return;
    }
    final tenderedScaled = parseScaled4(_tenderedController.text);
    if (tenderedScaled < _cartTotalScaled4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Amount tendered must be at least the sale total.'),
        ),
      );
      return;
    }
    if (_paymentMethod != PaymentMethod.cash &&
        tenderedScaled != _cartTotalScaled4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Manual M-PESA payment amount must equal the sale total.',
          ),
        ),
      );
      return;
    }

    final sale = await widget.controller.submitSale(
      paymentMethod: _paymentMethod,
      amountTendered: _tenderedController.text,
      paymentReference: _paymentRefController.text,
      notes: _notesController.text,
      lines: List<SaleLineInput>.unmodifiable(_cart),
    );

    if (!mounted) return;
    if (sale != null) {
      setState(() {
        _cart.clear();
        _tenderedController.clear();
        _paymentRefController.clear();
        _notesController.clear();
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SaleReceiptScreen(sale: sale),
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
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SegmentedButton<SalesSection>(
                segments: const [
                  ButtonSegment(
                    value: SalesSection.newSale,
                    icon: Icon(Icons.point_of_sale_outlined),
                    label: Text('New sale'),
                  ),
                  ButtonSegment(
                    value: SalesSection.receipts,
                    icon: Icon(Icons.receipt_long_outlined),
                    label: Text('Receipts'),
                  ),
                ],
                selected: <SalesSection>{_section},
                onSelectionChanged: (selected) {
                  final next = selected.first;
                  setState(() => _section = next);
                  widget.onSectionChanged?.call(next);
                },
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _section == SalesSection.newSale
                  ? _buildNewSaleView(ctrl)
                  : _buildReceiptsView(ctrl),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNewSaleView(SalesController ctrl) {
    final totalScaled = _cartTotalScaled4;
    final tenderedScaled = parseScaled4(_tenderedController.text);
    final changeScaled = tenderedScaled >= totalScaled
        ? tenderedScaled - totalScaled
        : BigInt.zero;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Sale items (${_cart.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Reload stock',
                onPressed:
                    ctrl.isLoadingProducts ? null : ctrl.loadAvailableProducts,
                icon: const Icon(Icons.refresh),
              ),
              OutlinedButton.icon(
                onPressed: ctrl.isSubmittingSale
                    ? null
                    : () => _addProductToCart(ctrl.availableProducts),
                icon: const Icon(Icons.add),
                label: const Text('Add item'),
              ),
            ],
          ),
          if (ctrl.productsError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                ctrl.productsError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          if (_cart.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No items in sale yet. Tap "Add item" above.'),
              ),
            )
          else
            ...List<Widget>.generate(_cart.length, (index) {
              final line = _cart[index];
              final lineTotal = computeLineTotalScaled4(
                line.quantity,
                line.unitPrice,
              );
              return Card(
                child: ListTile(
                  title: Text(line.productName),
                  subtitle: Text(
                    'Qty: ${line.quantity} × ${formatMoneyDisplay(line.unitPrice)} '
                    '(Avail: ${formatQuantityDisplay(line.availableStock)})',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatScaled4(lineTotal),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        tooltip: 'Remove item',
                        onPressed: ctrl.isSubmittingSale
                            ? null
                            : () => setState(() => _cart.removeAt(index)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Sale total',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        formatScaled4(totalScaled),
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<PaymentMethod>(
                    initialValue: _paymentMethod,
                    decoration: const InputDecoration(
                      labelText: 'Payment method',
                      border: OutlineInputBorder(),
                    ),
                    items: PaymentMethod.values
                        .map(
                          (m) => DropdownMenuItem<PaymentMethod>(
                            value: m,
                            child: Text(m.displayLabel),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: ctrl.isSubmittingSale
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() {
                                _paymentMethod = value;
                                if (_paymentMethod != PaymentMethod.cash &&
                                    _cart.isNotEmpty) {
                                  _tenderedController.text =
                                      formatScaled4(_cartTotalScaled4);
                                }
                              });
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _tenderedController,
                    enabled: !ctrl.isSubmittingSale,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _paymentMethod == PaymentMethod.mpesa
                          ? 'M-PESA amount received *'
                          : 'Amount tendered *',
                      helperText: _paymentMethod == PaymentMethod.mpesa
                          ? 'Must match the sale total exactly (no change given).'
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Change'),
                      Text(
                        formatScaled4(changeScaled),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _paymentRefController,
                    enabled: !ctrl.isSubmittingSale,
                    decoration: InputDecoration(
                      labelText: _paymentMethod == PaymentMethod.mpesa
                          ? 'M-PESA reference / code (optional)'
                          : 'Payment reference (optional)',
                      helperText: _paymentMethod == PaymentMethod.mpesa
                          ? 'Manually recorded only; payment is not auto-verified.'
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesController,
                    enabled: !ctrl.isSubmittingSale,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: ctrl.isSubmittingSale ? null : _submitSale,
            icon: ctrl.isSubmittingSale
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle_outline),
            label: Text(
              ctrl.isSubmittingSale ? 'Recording sale...' : 'Complete sale',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptsView(SalesController ctrl) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _receiptSearchController,
                  decoration: InputDecoration(
                    hintText: 'Search by receipt number or reference...',
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                    suffixIcon: _receiptSearchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _receiptSearchController.clear();
                              ctrl.loadSales(query: '');
                            },
                          )
                        : null,
                  ),
                  onSubmitted: (value) => ctrl.loadSales(query: value),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh receipts',
                onPressed: () =>
                    ctrl.loadSales(query: _receiptSearchController.text),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('${ctrl.totalSales} receipt(s)'),
          const SizedBox(height: 8),
          Expanded(
            child: Builder(
              builder: (context) {
                if (ctrl.isLoadingSales && ctrl.sales.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (ctrl.salesError != null && ctrl.sales.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(ctrl.salesError!),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: () => ctrl.loadSales(),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
                }
                if (ctrl.sales.isEmpty) {
                  return const Center(child: Text('No sales recorded yet.'));
                }
                return ListView.separated(
                  itemCount: ctrl.sales.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final sale = ctrl.sales[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: Text(
                          sale.receiptNumber,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${sale.paymentMethod.displayLabel} • ${sale.lines.length} item(s) • ${sale.soldByLogin}',
                        ),
                        trailing: Text(
                          formatMoneyDisplay(sale.totalAmount),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SaleReceiptScreen(sale: sale),
                            ),
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AddSaleLineDialog extends StatefulWidget {
  const _AddSaleLineDialog({required this.products});

  final List<InventoryBalanceItem> products;

  @override
  State<_AddSaleLineDialog> createState() => _AddSaleLineDialogState();
}

class _AddSaleLineDialogState extends State<_AddSaleLineDialog> {
  final _formKey = GlobalKey<FormState>();
  late InventoryBalanceItem _selected;
  final _quantityController = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    _selected = widget.products.first;
  }

  @override
  void dispose() {
    _quantityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add item to sale'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<InventoryBalanceItem>(
                initialValue: _selected,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Product *',
                  border: OutlineInputBorder(),
                ),
                items: widget.products
                    .map(
                      (p) => DropdownMenuItem<InventoryBalanceItem>(
                        value: p,
                        child: Text(
                          '${p.name} (On hand: ${formatQuantityDisplay(p.quantityOnHand)}, Price: ${formatMoneyDisplay(p.sellingPrice)})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selected = value);
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
                  labelText: 'Quantity *',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final baseErr = validatePositiveDecimalInput(
                    value,
                    fieldLabel: 'a quantity',
                  );
                  if (baseErr != null) return baseErr;
                  if (parseScaled4(value!) >
                      parseScaled4(_selected.quantityOnHand)) {
                    return 'Exceeds available stock (${formatQuantityDisplay(_selected.quantityOnHand)}).';
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              return;
            }
            Navigator.of(context).pop(
              SaleLineInput(
                productId: _selected.productId,
                productName: _selected.name,
                unitPrice: _selected.sellingPrice,
                quantity: _quantityController.text.trim(),
                availableStock: _selected.quantityOnHand,
              ),
            );
          },
          child: const Text('Add item'),
        ),
      ],
    );
  }
}
