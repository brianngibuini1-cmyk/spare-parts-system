import 'package:flutter/material.dart';

import 'supplier_controller.dart';
import 'supplier_models.dart';

class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({
    required this.controller,
    super.key,
  });

  final SupplierController controller;

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.loadSuppliers();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openSupplierForm({SupplierItem? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _SupplierFormDialog(
        controller: widget.controller,
        existing: existing,
      ),
    );

    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.actionMessage ?? 'Supplier saved.',
          ),
        ),
      );
    }
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
                        hintText: 'Search suppliers by name, contact, phone...',
                        prefixIcon: const Icon(Icons.search),
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  ctrl.loadSuppliers(query: '');
                                },
                              )
                            : null,
                      ),
                      onSubmitted: (value) => ctrl.loadSuppliers(query: value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: ctrl.isSaving ? null : () => _openSupplierForm(),
                    icon: const Icon(Icons.add),
                    label: const Text('Add supplier'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${ctrl.total} supplier(s)',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  if (ctrl.isOwner) ...[
                    const Text('Show inactive'),
                    Switch(
                      value: ctrl.includeInactive,
                      onChanged: (value) => ctrl.loadSuppliers(
                        includeInactiveFilter: value,
                      ),
                    ),
                  ],
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: () => ctrl.loadSuppliers(
                      query: _searchController.text,
                    ),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              if (ctrl.actionError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: MaterialBanner(
                    content: Text(ctrl.actionError!),
                    actions: [
                      TextButton(
                        onPressed: ctrl.clearFeedback,
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (ctrl.isLoading && ctrl.suppliers.isEmpty) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (ctrl.listError != null && ctrl.suppliers.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(ctrl.listError!),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: () => ctrl.loadSuppliers(),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }
                    if (ctrl.suppliers.isEmpty) {
                      return const Center(
                        child: Text('No suppliers found.'),
                      );
                    }
                    return ListView.separated(
                      itemCount: ctrl.suppliers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final supplier = ctrl.suppliers[index];
                        return Card(
                          child: ListTile(
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    supplier.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Chip(
                                  label: Text(
                                    supplier.isActive ? 'Active' : 'Inactive',
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (supplier.contactPerson != null)
                                  Text('Contact: ${supplier.contactPerson}'),
                                if (supplier.phone != null)
                                  Text('Phone: ${supplier.phone}'),
                                if (supplier.email != null)
                                  Text('Email: ${supplier.email}'),
                                if (supplier.notes != null)
                                  Text('Notes: ${supplier.notes}'),
                              ],
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (action) {
                                if (action == 'edit') {
                                  _openSupplierForm(existing: supplier);
                                } else if (action == 'toggle') {
                                  ctrl.setSupplierActive(
                                    supplier,
                                    !supplier.isActive,
                                  );
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Edit supplier'),
                                ),
                                PopupMenuItem(
                                  value: 'toggle',
                                  child: Text(
                                    supplier.isActive
                                        ? 'Deactivate'
                                        : 'Activate',
                                  ),
                                ),
                              ],
                            ),
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

class _SupplierFormDialog extends StatefulWidget {
  const _SupplierFormDialog({
    required this.controller,
    this.existing,
  });

  final SupplierController controller;
  final SupplierItem? existing;

  @override
  State<_SupplierFormDialog> createState() => _SupplierFormDialogState();
}

class _SupplierFormDialogState extends State<_SupplierFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _contactController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _contactController =
        TextEditingController(text: widget.existing?.contactPerson ?? '');
    _phoneController =
        TextEditingController(text: widget.existing?.phone ?? '');
    _emailController =
        TextEditingController(text: widget.existing?.email ?? '');
    _notesController =
        TextEditingController(text: widget.existing?.notes ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contactController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return AlertDialog(
      title: Text(existing == null ? 'Add supplier' : 'Edit supplier'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Supplier name *',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a supplier name.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _contactController,
                decoration: const InputDecoration(
                  labelText: 'Contact person',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
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
            final result = existing == null
                ? await widget.controller.createSupplier(
                    SupplierCreateInput(
                      name: _nameController.text,
                      contactPerson: _contactController.text,
                      phone: _phoneController.text,
                      email: _emailController.text,
                      notes: _notesController.text,
                    ),
                  )
                : await widget.controller.updateSupplier(
                    existing.id,
                    SupplierUpdateInput(
                      name: _nameController.text,
                      contactPerson: _contactController.text,
                      phone: _phoneController.text,
                      email: _emailController.text,
                      notes: _notesController.text,
                    ),
                  );
            if (result != null && context.mounted) {
              Navigator.of(context).pop(true);
            } else if (context.mounted) {
              Navigator.of(context).pop(false);
            }
          },
          child: Text(existing == null ? 'Save supplier' : 'Update'),
        ),
      ],
    );
  }
}
