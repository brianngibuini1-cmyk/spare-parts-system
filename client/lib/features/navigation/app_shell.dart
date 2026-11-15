import 'package:flutter/material.dart';

import '../../core/network/api_client.dart';
import '../catalogue/catalogue_controller.dart';
import '../catalogue/catalogue_models.dart';
import '../catalogue/catalogue_repository.dart';
import '../catalogue/catalogue_screen.dart';
import '../catalogue/product_image_picker.dart';
import '../inventory/inventory_controller.dart';
import '../inventory/inventory_repository.dart';
import '../inventory/inventory_screen.dart';
import '../inventory/stock_receiving_screen.dart';
import '../reports/dashboard_screen.dart';
import '../reports/reports_controller.dart';
import '../reports/reports_repository.dart';
import '../reports/reports_screen.dart';
import '../sales/sales_controller.dart';
import '../sales/sales_repository.dart';
import '../sales/sales_screen.dart';
import '../suppliers/supplier_controller.dart';
import '../suppliers/supplier_repository.dart';
import '../suppliers/suppliers_screen.dart';
import '../team/team_controller.dart';
import '../team/team_management_screen.dart';
import '../team/team_repository.dart';

class _Destination {
  const _Destination(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _ownerDestinations = [
  _Destination('Dashboard', Icons.dashboard_outlined),
  _Destination('Product approvals', Icons.fact_check_outlined),
  _Destination('Products', Icons.inventory_2_outlined),
  _Destination('Inventory', Icons.warehouse_outlined),
  _Destination('Stock receiving', Icons.move_to_inbox_outlined),
  _Destination('Sales', Icons.point_of_sale_outlined),
  _Destination('Suppliers', Icons.local_shipping_outlined),
  _Destination('Reports', Icons.bar_chart_outlined),
  _Destination('Team management', Icons.group_outlined),
];
const _attendantDestinations = [
  _Destination('Dashboard', Icons.dashboard_outlined),
  _Destination('Product registration', Icons.add_box_outlined),
  _Destination('Products', Icons.inventory_2_outlined),
  _Destination('Inventory', Icons.warehouse_outlined),
  _Destination('Stock receiving', Icons.move_to_inbox_outlined),
  _Destination('Sales', Icons.point_of_sale_outlined),
  _Destination('Receipts', Icons.receipt_long_outlined),
];

class AppShell extends StatefulWidget {
  const AppShell({
    required this.user,
    required this.onLogout,
    this.api,
    this.catalogueController,
    this.supplierController,
    this.inventoryController,
    this.salesController,
    this.teamController,
    this.dashboardController,
    this.reportsController,
    this.onSessionExpired,
    this.imagePicker = showProductImagePickerSheet,
    super.key,
  });

  final AuthenticatedUser user;
  final Future<void> Function() onLogout;
  final ApiClient? api;
  final CatalogueController? catalogueController;
  final SupplierController? supplierController;
  final InventoryController? inventoryController;
  final SalesController? salesController;
  final TeamController? teamController;
  final DashboardController? dashboardController;
  final ReportsController? reportsController;
  final void Function(String message)? onSessionExpired;
  final ProductImagePicker imagePicker;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selected = 0;
  CatalogueController? _ownedCatalogueController;
  SupplierController? _ownedSupplierController;
  InventoryController? _ownedInventoryController;
  SalesController? _ownedSalesController;
  TeamController? _ownedTeamController;
  DashboardController? _ownedDashboardController;
  ReportsController? _ownedReportsController;

  bool get _isOwner => widget.user.role == 'OWNER';
  List<_Destination> get _destinations =>
      _isOwner ? _ownerDestinations : _attendantDestinations;

  CatalogueController? get _catalogueController {
    if (widget.catalogueController != null) {
      return widget.catalogueController;
    }
    if (widget.api == null) {
      return null;
    }
    final initialStatus = _destinations[_selected].label == 'Product approvals'
        ? ProductApprovalStatus.pending
        : null;
    return _ownedCatalogueController ??= CatalogueController(
      CatalogueRepository(widget.api!),
      onSessionExpired: widget.onSessionExpired,
      isOwner: _isOwner,
      initialStatusFilter: initialStatus,
    );
  }

  SupplierController? get _supplierController {
    if (widget.supplierController != null) {
      return widget.supplierController;
    }
    if (widget.api == null || !_isOwner) {
      return null;
    }
    return _ownedSupplierController ??= SupplierController(
      SupplierRepository(widget.api!),
      onSessionExpired: widget.onSessionExpired,
      isOwner: _isOwner,
    );
  }

  InventoryController? get _inventoryController {
    if (widget.inventoryController != null) {
      return widget.inventoryController;
    }
    if (widget.api == null) {
      return null;
    }
    return _ownedInventoryController ??= InventoryController(
      InventoryRepository(widget.api!),
      catalogueRepository: CatalogueRepository(widget.api!),
      supplierRepository: SupplierRepository(widget.api!),
      onSessionExpired: widget.onSessionExpired,
      isOwner: _isOwner,
    );
  }

  SalesController? get _salesController {
    if (widget.salesController != null) {
      return widget.salesController;
    }
    if (widget.api == null) {
      return null;
    }
    return _ownedSalesController ??= SalesController(
      SalesRepository(widget.api!),
      inventoryRepository: InventoryRepository(widget.api!),
      onSessionExpired: widget.onSessionExpired,
    );
  }

  TeamController? get _teamController {
    if (!_isOwner) {
      return null;
    }
    if (widget.teamController != null) {
      return widget.teamController;
    }
    if (widget.api == null) {
      return null;
    }
    return _ownedTeamController ??= TeamController(
      TeamRepository(widget.api!),
      onSessionExpired: widget.onSessionExpired,
      isOwner: _isOwner,
    );
  }

  DashboardController? get _dashboardController {
    if (widget.dashboardController != null) {
      return widget.dashboardController;
    }
    if (widget.api == null) {
      return null;
    }
    return _ownedDashboardController ??= DashboardController(
      ReportsRepository(widget.api!),
      onSessionExpired: widget.onSessionExpired,
    );
  }

  ReportsController? get _reportsController {
    if (!_isOwner) {
      return null;
    }
    if (widget.reportsController != null) {
      return widget.reportsController;
    }
    if (widget.api == null) {
      return null;
    }
    return _ownedReportsController ??= ReportsController(
      ReportsRepository(widget.api!),
      onSessionExpired: widget.onSessionExpired,
      isOwner: _isOwner,
    );
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final userChanged = oldWidget.user.id != widget.user.id ||
        oldWidget.user.role != widget.user.role;
    final controllerSourceChanged = oldWidget.api != widget.api ||
        oldWidget.catalogueController != widget.catalogueController ||
        oldWidget.supplierController != widget.supplierController ||
        oldWidget.inventoryController != widget.inventoryController ||
        oldWidget.salesController != widget.salesController ||
        oldWidget.teamController != widget.teamController ||
        oldWidget.dashboardController != widget.dashboardController ||
        oldWidget.reportsController != widget.reportsController;
    if (userChanged || controllerSourceChanged) {
      _ownedCatalogueController?.dispose();
      _ownedCatalogueController = null;
      _ownedSupplierController?.dispose();
      _ownedSupplierController = null;
      _ownedInventoryController?.dispose();
      _ownedInventoryController = null;
      _ownedSalesController?.dispose();
      _ownedSalesController = null;
      _ownedTeamController?.dispose();
      _ownedTeamController = null;
      _ownedDashboardController?.dispose();
      _ownedDashboardController = null;
      _ownedReportsController?.dispose();
      _ownedReportsController = null;
    }
    if (userChanged || _selected >= _destinations.length) {
      _selected = 0;
    }
  }

  @override
  void dispose() {
    _ownedCatalogueController?.dispose();
    _ownedSupplierController?.dispose();
    _ownedInventoryController?.dispose();
    _ownedSalesController?.dispose();
    _ownedTeamController?.dispose();
    _ownedDashboardController?.dispose();
    _ownedReportsController?.dispose();
    super.dispose();
  }

  void _selectDestinationByLabel(String label) {
    final index = _destinations.indexWhere((item) => item.label == label);
    if (index != -1 && index != _selected) {
      setState(() => _selected = index);
    }
  }

  Widget _buildBody(String currentLabel) {
    final catalogueController = _catalogueController;
    if (catalogueController != null &&
        (currentLabel == 'Product approvals' ||
            currentLabel == 'Products' ||
            currentLabel == 'Product registration')) {
      final section = switch (currentLabel) {
        'Product approvals' => CatalogueSection.approvals,
        'Product registration' => CatalogueSection.register,
        _ => CatalogueSection.browse,
      };
      return CatalogueScreen(
        controller: catalogueController,
        initialSection: section,
        imagePicker: widget.imagePicker,
        isOwner: _isOwner,
        onSectionChanged: (nextSection) {
          final targetLabel = switch (nextSection) {
            CatalogueSection.approvals => 'Product approvals',
            CatalogueSection.register => 'Product registration',
            CatalogueSection.browse => 'Products',
          };
          _selectDestinationByLabel(targetLabel);
        },
      );
    }
    final supplierController = _supplierController;
    if (supplierController != null && currentLabel == 'Suppliers') {
      return SuppliersScreen(controller: supplierController);
    }
    final inventoryController = _inventoryController;
    if (inventoryController != null && currentLabel == 'Inventory') {
      return InventoryScreen(controller: inventoryController);
    }
    if (inventoryController != null && currentLabel == 'Stock receiving') {
      return StockReceivingScreen(controller: inventoryController);
    }
    final salesController = _salesController;
    if (salesController != null &&
        (currentLabel == 'Sales' || currentLabel == 'Receipts')) {
      return SalesScreen(
        controller: salesController,
        initialSection: currentLabel == 'Receipts'
            ? SalesSection.receipts
            : SalesSection.newSale,
      );
    }
    final teamController = _teamController;
    if (teamController != null && currentLabel == 'Team management') {
      return TeamManagementScreen(controller: teamController);
    }
    final dashboardController = _dashboardController;
    if (dashboardController != null && currentLabel == 'Dashboard') {
      return DashboardScreen(
        controller: dashboardController,
        isOwner: _isOwner,
        onNavigateTo: _selectDestinationByLabel,
      );
    }
    final reportsController = _reportsController;
    if (reportsController != null && currentLabel == 'Reports') {
      return ReportsScreen(controller: reportsController);
    }
    return _PlaceholderPage(title: currentLabel);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final destinations = _destinations;
    final currentLabel = destinations[_selected].label;
    final content = _buildBody(currentLabel);
    return Scaffold(
      appBar: AppBar(
        title: Text(currentLabel),
        actions: [
          if (wide)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(child: Text(widget.user.loginName)),
            ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      drawer: wide
          ? null
          : Drawer(
              child: SafeArea(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.build_circle_outlined),
                      title: const Text('BMM Auto Motors'),
                      subtitle: Text(widget.user.loginName),
                    ),
                    const Divider(),
                    Expanded(
                      child: ListView.builder(
                        itemCount: destinations.length,
                        itemBuilder: (context, index) => _navItem(
                          context,
                          destinations,
                          index,
                          closeDrawer: true,
                        ),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.logout),
                      title: const Text('Sign out'),
                      onTap: widget.onLogout,
                    ),
                  ],
                ),
              ),
            ),
      body: Row(
        children: [
          if (wide)
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: NavigationRail(
                      extended: MediaQuery.sizeOf(context).width >= 1200,
                      selectedIndex: _selected,
                      onDestinationSelected: (index) =>
                          setState(() => _selected = index),
                      destinations: [
                        for (final item in destinations)
                          NavigationRailDestination(
                            icon: Icon(item.icon),
                            label: Text(item.label),
                          ),
                      ],
                      leading: const Padding(
                        padding: EdgeInsets.all(20),
                        child: Icon(
                          Icons.build_circle_outlined,
                          color: Color(0xFF087E8B),
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (wide) const VerticalDivider(width: 1),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _navItem(
    BuildContext context,
    List<_Destination> destinations,
    int index, {
    bool closeDrawer = false,
  }) {
    final item = destinations[index];
    return ListTile(
      selected: index == _selected,
      leading: Icon(item.icon),
      title: Text(item.label),
      onTap: () {
        setState(() => _selected = index);
        if (closeDrawer) Navigator.pop(context);
      },
    );
  }
}

class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.construction_outlined,
                size: 42,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(height: 14),
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text(
                'This workspace is ready for the next implementation milestone.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}
