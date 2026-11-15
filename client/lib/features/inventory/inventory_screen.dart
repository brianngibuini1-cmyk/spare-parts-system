import 'package:flutter/material.dart';

import 'inventory_controller.dart';
import 'inventory_models.dart';
import 'product_movements_screen.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({
    required this.controller,
    super.key,
  });

  final InventoryController controller;

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadBalances();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search stock by product name or MPN...',
                        prefixIcon: const Icon(Icons.search),
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  ctrl.loadBalances(query: '');
                                },
                              )
                            : null,
                      ),
                      onSubmitted: (value) => ctrl.loadBalances(query: value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Refresh balances',
                    onPressed: () =>
                        ctrl.loadBalances(query: _searchController.text),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${ctrl.totalBalances} approved product(s) in inventory',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (ctrl.isLoadingBalances && ctrl.balances.isEmpty) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (ctrl.balancesError != null && ctrl.balances.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(ctrl.balancesError!),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: () => ctrl.loadBalances(),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }
                    if (ctrl.balances.isEmpty) {
                      return const Center(
                        child: Text('No approved products found.'),
                      );
                    }
                    return ListView.separated(
                      itemCount: ctrl.balances.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = ctrl.balances[index];
                        return Card(
                          child: ListTile(
                            title: Text(
                              item.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              'Ref: ${item.internalReference}'
                              '${item.manufacturerPartNumber != null ? ' • MPN: ${item.manufacturerPartNumber}' : ''}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Chip(
                                  label: Text(
                                    'On hand: ${formatQuantityDisplay(item.quantityOnHand)}',
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ProductMovementsScreen(
                                    controller: ctrl,
                                    productId: item.productId,
                                    productName: item.name,
                                  ),
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
      },
    );
  }
}
