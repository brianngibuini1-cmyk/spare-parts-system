import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'catalogue_controller.dart';
import 'catalogue_models.dart';
import 'product_image_picker.dart';

enum CatalogueSection { browse, register, approvals }

String _formatUtcTimestamp(DateTime timestamp) {
  final utc = timestamp.toUtc();
  final year = utc.year.toString().padLeft(4, '0');
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  final hour = utc.hour.toString().padLeft(2, '0');
  final minute = utc.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute UTC';
}

class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({
    required this.controller,
    this.initialSection = CatalogueSection.browse,
    this.imagePicker = showProductImagePickerSheet,
    this.onSectionChanged,
    this.isOwner,
    super.key,
  });

  final CatalogueController controller;
  final CatalogueSection initialSection;
  final ProductImagePicker imagePicker;
  final ValueChanged<CatalogueSection>? onSectionChanged;
  final bool? isOwner;

  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  late CatalogueSection _section = widget.initialSection;
  late final TextEditingController _searchController = TextEditingController(
    text: widget.controller.searchQuery,
  );

  bool get _effectiveIsOwner => widget.isOwner ?? widget.controller.isOwner;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_section == CatalogueSection.approvals &&
          widget.controller.statusFilter == null &&
          widget.controller.products.isEmpty &&
          !widget.controller.isLoadingList &&
          widget.controller.listError == null) {
        widget.controller.loadProducts(
          status: ProductApprovalStatus.pending,
          updateFilter: true,
        );
        return;
      }
      if (widget.controller.products.isEmpty &&
          !widget.controller.isLoadingList &&
          widget.controller.listError == null) {
        widget.controller.loadProducts();
      }
    });
  }

  @override
  void didUpdateWidget(covariant CatalogueScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection != widget.initialSection) {
      final previousSection = _section;
      _section = widget.initialSection;
      if (widget.controller.selectedProduct != null) {
        widget.controller.closeProductDetail();
      }
      if (_section == CatalogueSection.approvals &&
          previousSection != CatalogueSection.approvals) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          widget.controller.loadProducts(
            query: _searchController.text,
            status: ProductApprovalStatus.pending,
            updateFilter: true,
          );
        });
      } else if (_section == CatalogueSection.browse &&
          previousSection == CatalogueSection.approvals) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          widget.controller.loadProducts(
            query: _searchController.text,
            updateFilter: true,
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _switchSection(CatalogueSection next) {
    final previous = _section;
    setState(() => _section = next);
    if (widget.controller.selectedProduct != null) {
      widget.controller.closeProductDetail();
    }
    if (next == CatalogueSection.approvals &&
        previous != CatalogueSection.approvals) {
      widget.controller.loadProducts(
        query: _searchController.text,
        status: ProductApprovalStatus.pending,
        updateFilter: true,
      );
    } else if (next == CatalogueSection.browse &&
        previous == CatalogueSection.approvals) {
      widget.controller.loadProducts(
        query: _searchController.text,
        updateFilter: true,
      );
    }
    widget.onSectionChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final selected = widget.controller.selectedProduct;
          if (selected != null) {
            return _ProductDetailView(
              controller: widget.controller,
              product: selected,
              imagePicker: widget.imagePicker,
              isOwner: _effectiveIsOwner,
            );
          }
          return switch (_section) {
            CatalogueSection.browse => _ProductBrowseView(
                controller: widget.controller,
                searchController: _searchController,
                isOwner: _effectiveIsOwner,
                isApprovalQueue: false,
                onOpenRegister: () => _switchSection(CatalogueSection.register),
                onOpenApprovals: _effectiveIsOwner
                    ? () => _switchSection(CatalogueSection.approvals)
                    : null,
              ),
            CatalogueSection.approvals => _ProductBrowseView(
                controller: widget.controller,
                searchController: _searchController,
                isOwner: _effectiveIsOwner,
                isApprovalQueue: true,
                onOpenRegister: () => _switchSection(CatalogueSection.register),
                onOpenBrowse: () => _switchSection(CatalogueSection.browse),
              ),
            CatalogueSection.register => _ProductRegistrationView(
                controller: widget.controller,
                imagePicker: widget.imagePicker,
                onBrowseCatalogue: () =>
                    _switchSection(CatalogueSection.browse),
              ),
          };
        },
      );
}

class _ProductBrowseView extends StatelessWidget {
  const _ProductBrowseView({
    required this.controller,
    required this.searchController,
    required this.isOwner,
    required this.isApprovalQueue,
    required this.onOpenRegister,
    this.onOpenApprovals,
    this.onOpenBrowse,
  });

  final CatalogueController controller;
  final TextEditingController searchController;
  final bool isOwner;
  final bool isApprovalQueue;
  final VoidCallback onOpenRegister;
  final VoidCallback? onOpenApprovals;
  final VoidCallback? onOpenBrowse;

  void _runSearch() {
    controller.loadProducts(query: searchController.text);
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isApprovalQueue
                              ? 'Product approval queue'
                              : 'Spare parts catalogue',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isApprovalQueue
                              ? 'Review submitted products and photographs, then set a selling price to approve or record a rejection reason.'
                              : 'Browse approved spare parts and track pending or rejected product submissions.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        if (isApprovalQueue && onOpenBrowse != null)
                          OutlinedButton.icon(
                            key: const Key('open-browse-catalogue-button'),
                            onPressed: onOpenBrowse,
                            icon: const Icon(Icons.inventory_2_outlined),
                            label: const Text('Browse full catalogue'),
                          ),
                        if (!isApprovalQueue &&
                            isOwner &&
                            onOpenApprovals != null)
                          OutlinedButton.icon(
                            key: const Key('open-approval-queue-button'),
                            onPressed: onOpenApprovals,
                            icon: const Icon(Icons.fact_check_outlined),
                            label: const Text('Review submissions'),
                          ),
                        FilledButton.icon(
                          key: const Key('open-register-product-button'),
                          onPressed: onOpenRegister,
                          icon: const Icon(Icons.add_box_outlined),
                          label: const Text('Submit new product'),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 360,
                              child: TextField(
                                key: const Key('catalogue-search-input'),
                                controller: searchController,
                                decoration: const InputDecoration(
                                  labelText: 'Search catalogue',
                                  hintText:
                                      'Name, reference, category, or part number',
                                  prefixIcon: Icon(Icons.search),
                                ),
                                onSubmitted: (_) => _runSearch(),
                              ),
                            ),
                            FilledButton(
                              key: const Key('catalogue-search-button'),
                              onPressed:
                                  controller.isLoadingList ? null : _runSearch,
                              child: const Text('Search'),
                            ),
                            OutlinedButton.icon(
                              key: const Key('catalogue-refresh-button'),
                              onPressed: controller.isLoadingList
                                  ? null
                                  : () => controller.loadProducts(
                                        query: searchController.text,
                                      ),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Refresh'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilterChip(
                              key: const Key('filter-status-all'),
                              label: const Text('All visible'),
                              selected: controller.statusFilter == null,
                              onSelected: controller.isLoadingList
                                  ? null
                                  : (_) => controller.loadProducts(
                                        query: searchController.text,
                                        updateFilter: true,
                                      ),
                            ),
                            for (final status in ProductApprovalStatus.values)
                              FilterChip(
                                key: Key('filter-status-${status.wireValue}'),
                                label: Text(status.displayLabel),
                                selected: controller.statusFilter == status,
                                onSelected: controller.isLoadingList
                                    ? null
                                    : (_) => controller.loadProducts(
                                          query: searchController.text,
                                          status: status,
                                          updateFilter: true,
                                        ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (controller.actionMessage != null)
                  _FeedbackBanner(
                    key: const Key('catalogue-action-message'),
                    message: controller.actionMessage!,
                    isError: false,
                  ),
                if (controller.actionError != null)
                  _FeedbackBanner(
                    key: const Key('catalogue-action-error'),
                    message: controller.actionError!,
                    isError: true,
                  ),
                if (controller.isLoadingList)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text('Loading spare parts catalogue...'),
                        ],
                      ),
                    ),
                  )
                else if (controller.listError != null)
                  Card(
                    key: const Key('catalogue-list-error-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 40),
                          const SizedBox(height: 12),
                          Text(
                            controller.listError!,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            key: const Key('catalogue-retry-button'),
                            onPressed: _runSearch,
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (controller.products.isEmpty)
                  Card(
                    key: const Key('catalogue-empty-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.inventory_2_outlined, size: 42),
                          const SizedBox(height: 12),
                          Text(
                            isApprovalQueue &&
                                    controller.statusFilter ==
                                        ProductApprovalStatus.pending &&
                                    controller.searchQuery.trim().isEmpty
                                ? 'No pending products awaiting review.'
                                : 'No matching products found.',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            isApprovalQueue &&
                                    controller.statusFilter ==
                                        ProductApprovalStatus.pending &&
                                    controller.searchQuery.trim().isEmpty
                                ? 'All product submissions have been reviewed.'
                                : 'Adjust your search filter or submit a new product for owner approval.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          '${controller.products.length} '
                          '${controller.products.length == 1 ? 'product' : 'products'} shown',
                          key: const Key('catalogue-result-count'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      for (final product in controller.products)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ProductListCard(
                            product: product,
                            isOwner: isOwner,
                            imageBytes:
                                controller.imageBytesFor(product.imageUrl),
                            isLoadingImage:
                                controller.isLoadingImageFor(product.imageUrl),
                            onTap: () => controller.openProductDetail(
                              product.id,
                              initial: product,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
}

class _ProductListCard extends StatelessWidget {
  const _ProductListCard({
    required this.product,
    required this.isOwner,
    required this.imageBytes,
    required this.isLoadingImage,
    required this.onTap,
  });

  final ProductItem product;
  final bool isOwner;
  final Uint8List? imageBytes;
  final bool isLoadingImage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        key: Key('product-card-${product.id}'),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ProductThumbnail(
                  productId: product.id,
                  imageUrl: product.imageUrl,
                  imageBytes: imageBytes,
                  isLoading: isLoadingImage,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            product.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          _ApprovalStatusBadge(status: product.approvalStatus),
                          if (isOwner && product.isPending)
                            const Chip(
                              label: Text('Awaiting owner review'),
                              visualDensity: VisualDensity.compact,
                            )
                          else if (!isOwner && product.canEdit)
                            const Chip(
                              label: Text('Editable submission'),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Reference: ${product.internalReference}'
                        '${product.category != null ? ' • Category: ${product.category}' : ''}'
                        '${product.manufacturerPartNumber != null ? ' • Part #: ${product.manufacturerPartNumber}' : ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Submitted by ${product.submittedByLogin} on ${_formatUtcTimestamp(product.submittedAt)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      if (product.sellingPrice != null)
                        Text(
                          'Selling price: ${product.sellingPrice}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        )
                      else if (product.isPending)
                        const Text('Selling price: Set on owner approval')
                      else
                        const Text('Selling price: Not approved'),
                      if (product.approvalStatus ==
                              ProductApprovalStatus.rejected &&
                          product.rejectionReason != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Rejection reason: ${product.rejectionReason}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      );
}

class _ProductThumbnail extends StatelessWidget {
  const _ProductThumbnail({
    required this.productId,
    required this.imageUrl,
    required this.imageBytes,
    required this.isLoading,
  });

  final String productId;
  final String? imageUrl;
  final Uint8List? imageBytes;
  final bool isLoading;

  @override
  Widget build(BuildContext context) => Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          color: const Color(0xFFECEAE2),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: _buildChild(),
      );

  Widget _buildChild() {
    if (imageUrl == null) {
      return const Center(
        child: Icon(Icons.image_not_supported_outlined, size: 28),
      );
    }
    if (imageBytes != null) {
      return Image.memory(
        imageBytes!,
        key: Key('product-thumbnail-image-$productId'),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.photo_outlined, size: 28),
        ),
      );
    }
    if (isLoading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return const Center(
      child: Icon(Icons.broken_image_outlined, size: 28),
    );
  }
}

class _ProductRegistrationView extends StatefulWidget {
  const _ProductRegistrationView({
    required this.controller,
    required this.imagePicker,
    required this.onBrowseCatalogue,
  });

  final CatalogueController controller;
  final ProductImagePicker imagePicker;
  final VoidCallback onBrowseCatalogue;

  @override
  State<_ProductRegistrationView> createState() =>
      _ProductRegistrationViewState();
}

class _ProductRegistrationViewState extends State<_ProductRegistrationView> {
  final _nameController = TextEditingController();
  final _categoryController = TextEditingController();
  final _partNumberController = TextEditingController();
  final _descriptionController = TextEditingController();
  SelectedProductImage? _selectedImage;
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    _partNumberController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickPhotograph() async {
    final chosen = await widget.imagePicker(context);
    if (!mounted || chosen == null) return;
    setState(() {
      _selectedImage = chosen;
    });
  }

  Future<void> _submit() async {
    final trimmedName = _nameController.text.trim();
    if (trimmedName.isEmpty) {
      setState(() {
        _nameError = 'Enter the product name.';
      });
      return;
    }
    setState(() {
      _nameError = null;
    });
    final created = await widget.controller.submitNewProduct(
      ProductCreateInput(
        name: trimmedName,
        category: _categoryController.text,
        manufacturerPartNumber: _partNumberController.text,
        description: _descriptionController.text,
      ),
      image: _selectedImage,
    );
    if (!mounted || created == null) return;
    _nameController.clear();
    _categoryController.clear();
    _partNumberController.clear();
    _descriptionController.clear();
    setState(() {
      _selectedImage = null;
    });
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Submit product for approval',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'New submissions remain pending until the owner sets a selling price and approves them.',
                        ),
                      ],
                    ),
                    OutlinedButton.icon(
                      key: const Key('browse-catalogue-button'),
                      onPressed: widget.onBrowseCatalogue,
                      icon: const Icon(Icons.inventory_2_outlined),
                      label: const Text('Browse catalogue'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (widget.controller.actionMessage != null)
                  _FeedbackBanner(
                    key: const Key('register-action-message'),
                    message: widget.controller.actionMessage!,
                    isError: false,
                  ),
                if (widget.controller.actionError != null)
                  _FeedbackBanner(
                    key: const Key('register-action-error'),
                    message: widget.controller.actionError!,
                    isError: true,
                  ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const Key('create-product-name-input'),
                          controller: _nameController,
                          maxLength: 200,
                          decoration: InputDecoration(
                            labelText: 'Product name',
                            errorText: _nameError,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('create-product-category-input'),
                          controller: _categoryController,
                          maxLength: 100,
                          decoration: const InputDecoration(
                            labelText: 'Category',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('create-product-part-number-input'),
                          controller: _partNumberController,
                          maxLength: 128,
                          decoration: const InputDecoration(
                            labelText: 'Manufacturer part number',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('create-product-description-input'),
                          controller: _descriptionController,
                          maxLength: 4000,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'Description',
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              key: const Key('create-select-image-button'),
                              onPressed: widget.controller.isSubmitting
                                  ? null
                                  : _pickPhotograph,
                              icon: const Icon(Icons.add_a_photo_outlined),
                              label: Text(
                                _selectedImage == null
                                    ? 'Select photograph (optional)'
                                    : 'Change photograph',
                              ),
                            ),
                            if (_selectedImage != null)
                              Chip(
                                key: const Key('selected-create-image-chip'),
                                label: Text(_selectedImage!.filename),
                                onDeleted: widget.controller.isSubmitting
                                    ? null
                                    : () => setState(
                                          () => _selectedImage = null,
                                        ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          key: const Key('submit-new-product-button'),
                          onPressed:
                              widget.controller.isSubmitting ? null : _submit,
                          child: Text(
                            widget.controller.isSubmitting
                                ? 'Submitting...'
                                : 'Submit for approval',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _ProductDetailView extends StatefulWidget {
  const _ProductDetailView({
    required this.controller,
    required this.product,
    required this.imagePicker,
    required this.isOwner,
  });

  final CatalogueController controller;
  final ProductItem product;
  final ProductImagePicker imagePicker;
  final bool isOwner;

  @override
  State<_ProductDetailView> createState() => _ProductDetailViewState();
}

class _ProductDetailViewState extends State<_ProductDetailView> {
  late final TextEditingController _nameController;
  late final TextEditingController _categoryController;
  late final TextEditingController _partNumberController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _sellingPriceController;
  late final TextEditingController _rejectionReasonController;
  String? _nameError;
  String? _priceError;
  String? _rejectionReasonError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.product.name);
    _categoryController =
        TextEditingController(text: widget.product.category ?? '');
    _partNumberController = TextEditingController(
      text: widget.product.manufacturerPartNumber ?? '',
    );
    _descriptionController =
        TextEditingController(text: widget.product.description ?? '');
    _sellingPriceController = TextEditingController(
      text: widget.product.sellingPrice ?? '',
    );
    _rejectionReasonController = TextEditingController();
  }

  @override
  void didUpdateWidget(covariant _ProductDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final productChanged = oldWidget.product.id != widget.product.id;
    if (productChanged ||
        oldWidget.product.name != widget.product.name ||
        oldWidget.product.category != widget.product.category ||
        oldWidget.product.manufacturerPartNumber !=
            widget.product.manufacturerPartNumber ||
        oldWidget.product.description != widget.product.description) {
      _nameController.text = widget.product.name;
      _categoryController.text = widget.product.category ?? '';
      _partNumberController.text = widget.product.manufacturerPartNumber ?? '';
      _descriptionController.text = widget.product.description ?? '';
    }
    if (productChanged ||
        oldWidget.product.sellingPrice != widget.product.sellingPrice) {
      _sellingPriceController.text = widget.product.sellingPrice ?? '';
      _priceError = null;
    }
    if (productChanged) {
      _rejectionReasonController.clear();
      _rejectionReasonError = null;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    _partNumberController.dispose();
    _descriptionController.dispose();
    _sellingPriceController.dispose();
    _rejectionReasonController.dispose();
    super.dispose();
  }

  Future<void> _saveEdits() async {
    final trimmedName = _nameController.text.trim();
    if (trimmedName.isEmpty) {
      setState(() {
        _nameError = 'Product name is required.';
      });
      return;
    }
    setState(() {
      _nameError = null;
    });
    await widget.controller.updateSelectedProduct(
      ProductUpdateInput(
        name: trimmedName,
        category: _categoryController.text,
        manufacturerPartNumber: _partNumberController.text,
        description: _descriptionController.text,
      ),
    );
  }

  Future<void> _uploadPhotograph() async {
    final selected = await widget.imagePicker(context);
    if (!mounted || selected == null) return;
    await widget.controller.uploadImageForSelectedProduct(selected);
  }

  Future<void> _approveProduct() async {
    final priceValidation = validateSellingPriceInput(
      _sellingPriceController.text,
    );
    if (priceValidation != null) {
      setState(() {
        _priceError = priceValidation;
      });
      return;
    }
    setState(() {
      _priceError = null;
    });
    await widget.controller.approveProduct(
      widget.product.id,
      _sellingPriceController.text,
    );
  }

  Future<void> _rejectProduct() async {
    final reasonValidation = validateRejectionReasonInput(
      _rejectionReasonController.text,
    );
    if (reasonValidation != null) {
      setState(() {
        _rejectionReasonError = reasonValidation;
      });
      return;
    }
    setState(() {
      _rejectionReasonError = null;
    });
    final rejected = await widget.controller.rejectProduct(
      widget.product.id,
      _rejectionReasonController.text,
    );
    if (!mounted || !rejected) return;
    _rejectionReasonController.clear();
  }

  String _readOnlyExplanation(ProductItem product) {
    if (product.approvalStatus == ProductApprovalStatus.rejected) {
      return 'Rejected submissions are locked and cannot be edited or receive photograph updates.';
    }
    if (product.approvalStatus == ProductApprovalStatus.approved) {
      return 'Approved catalogue records are read-only for shop attendants.';
    }
    return 'Only your own pending submissions can be edited.';
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final imageUrl = product.imageUrl;
    final imageBytes = widget.controller.imageBytesFor(imageUrl);
    final isLoadingImage = widget.controller.isLoadingImageFor(imageUrl);
    final imageError = widget.controller.imageErrorFor(imageUrl);
    final reviewBusy = widget.controller.isReviewActionInProgress;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    key: const Key('back-to-catalogue-button'),
                    onPressed: widget.controller.closeProductDetail,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Back to catalogue'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('refresh-detail-button'),
                    onPressed: widget.controller.isLoadingDetail
                        ? null
                        : () => widget.controller.openProductDetail(product.id),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh details'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (widget.controller.isLoadingDetail)
                const LinearProgressIndicator(),
              if (widget.controller.detailError != null)
                _FeedbackBanner(
                  key: const Key('detail-error-banner'),
                  message: widget.controller.detailError!,
                  isError: true,
                ),
              if (widget.controller.actionMessage != null)
                _FeedbackBanner(
                  key: const Key('detail-action-message'),
                  message: widget.controller.actionMessage!,
                  isError: false,
                ),
              if (widget.controller.actionError != null)
                _FeedbackBanner(
                  key: const Key('detail-action-error'),
                  message: widget.controller.actionError!,
                  isError: true,
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            product.name,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          _ApprovalStatusBadge(status: product.approvalStatus),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('Internal reference: ${product.internalReference}'),
                      const SizedBox(height: 4),
                      Text(
                        'Category: ${product.category ?? 'Uncategorised'}',
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Manufacturer part number: ${product.manufacturerPartNumber ?? 'Not specified'}',
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Selling price: ${product.sellingPrice ?? (product.isPending ? 'Set on owner approval' : 'Not approved')}',
                      ),
                      const SizedBox(height: 4),
                      Text('Submitted by: ${product.submittedByLogin}'),
                      const SizedBox(height: 4),
                      Text(
                        'Submitted at: ${_formatUtcTimestamp(product.submittedAt)}',
                      ),
                      if (product.approvedByLogin != null) ...[
                        const SizedBox(height: 4),
                        Text('Approved by: ${product.approvedByLogin}'),
                      ],
                      if (product.approvedAt != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Approved at: ${_formatUtcTimestamp(product.approvedAt!)}',
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        product.description ?? 'No description provided.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      if (product.approvalStatus ==
                              ProductApprovalStatus.rejected &&
                          product.rejectionReason != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          key: const Key('detail-rejection-reason-box'),
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFDECEC),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          child: Text(
                            'Rejection reason: ${product.rejectionReason}',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Text(
                            'Product photograph',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (product.canEdit)
                            FilledButton.tonalIcon(
                              key: const Key('detail-upload-image-button'),
                              onPressed: widget.controller.isUploadingImage
                                  ? null
                                  : _uploadPhotograph,
                              icon: const Icon(Icons.upload_file_outlined),
                              label: Text(
                                widget.controller.isUploadingImage
                                    ? 'Uploading...'
                                    : (imageUrl == null
                                        ? 'Upload photograph'
                                        : 'Replace photograph'),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (imageUrl == null)
                        const Text(
                          'No product photograph has been uploaded yet.',
                          key: Key('detail-no-image-text'),
                        )
                      else if (imageBytes != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 320),
                            child: Image.memory(
                              imageBytes,
                              key: const Key('product-detail-image'),
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('Authenticated photograph loaded.'),
                              ),
                            ),
                          ),
                        )
                      else if (isLoadingImage)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 12),
                              Text('Loading authenticated photograph...'),
                            ],
                          ),
                        )
                      else if (imageError != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              imageError,
                              key: const Key('detail-image-error-text'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              key: const Key('detail-retry-image-button'),
                              onPressed: () =>
                                  widget.controller.loadProductImage(
                                imageUrl,
                                forceRefresh: true,
                              ),
                              child: const Text('Retry photograph'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              if (widget.isOwner && !product.isRejected) ...[
                const SizedBox(height: 16),
                Card(
                  key: const Key('owner-approval-card'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          product.isPending
                              ? 'Approve product and set selling price'
                              : 'Update approved selling price',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Price supports up to four decimal places. Currency and tax are not configured here.',
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          key: const Key('owner-selling-price-input'),
                          controller: _sellingPriceController,
                          enabled: !reviewBusy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Selling price',
                            hintText: '0.0000',
                            errorText: _priceError,
                          ),
                          onSubmitted: (_) {
                            if (!reviewBusy) {
                              _approveProduct();
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          key: const Key('owner-approve-product-button'),
                          onPressed: reviewBusy ? null : _approveProduct,
                          icon: const Icon(Icons.check_circle_outline),
                          label: Text(
                            widget.controller.isApproving
                                ? 'Approving...'
                                : (product.isPending
                                    ? 'Approve product'
                                    : 'Save approved price'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (widget.isOwner && product.isPending) ...[
                const SizedBox(height: 16),
                Card(
                  key: const Key('owner-rejection-card'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Reject submission',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Provide a reason for rejecting this submission. Rejected products remain in the audit record and cannot be edited or approved later.',
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          key: const Key('owner-rejection-reason-input'),
                          controller: _rejectionReasonController,
                          enabled: !reviewBusy,
                          maxLength: maxRejectionReasonLength,
                          maxLines: 3,
                          decoration: InputDecoration(
                            labelText: 'Rejection reason',
                            errorText: _rejectionReasonError,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          key: const Key('owner-reject-product-button'),
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.error,
                            foregroundColor:
                                Theme.of(context).colorScheme.onError,
                          ),
                          onPressed: reviewBusy ? null : _rejectProduct,
                          icon: const Icon(Icons.cancel_outlined),
                          label: Text(
                            widget.controller.isRejecting
                                ? 'Rejecting...'
                                : 'Reject submission',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (product.canEdit)
                Card(
                  key: const Key('detail-edit-form-card'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          product.isPending
                              ? 'Edit pending submission'
                              : 'Edit product details',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          key: const Key('edit-product-name-input'),
                          controller: _nameController,
                          maxLength: 200,
                          decoration: InputDecoration(
                            labelText: 'Product name',
                            errorText: _nameError,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('edit-product-category-input'),
                          controller: _categoryController,
                          maxLength: 100,
                          decoration: const InputDecoration(
                            labelText: 'Category',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('edit-product-part-number-input'),
                          controller: _partNumberController,
                          maxLength: 128,
                          decoration: const InputDecoration(
                            labelText: 'Manufacturer part number',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('edit-product-description-input'),
                          controller: _descriptionController,
                          maxLength: 4000,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'Description',
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          key: const Key('save-product-edit-button'),
                          onPressed: widget.controller.isSavingEdit
                              ? null
                              : _saveEdits,
                          child: Text(
                            widget.controller.isSavingEdit
                                ? 'Saving...'
                                : 'Save product details',
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Card(
                  key: const Key('product-readonly-notice'),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_outline),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(_readOnlyExplanation(product)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApprovalStatusBadge extends StatelessWidget {
  const _ApprovalStatusBadge({required this.status});

  final ProductApprovalStatus status;

  @override
  Widget build(BuildContext context) {
    final (backgroundColor, foregroundColor) = switch (status) {
      ProductApprovalStatus.approved => (
          const Color(0xFFE1F3E8),
          const Color(0xFF1B5E20),
        ),
      ProductApprovalStatus.pending => (
          const Color(0xFFFFF4DC),
          const Color(0xFF7A4F01),
        ),
      ProductApprovalStatus.rejected => (
          const Color(0xFFFDECEC),
          const Color(0xFF9F1D1D),
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        status.displayLabel,
        style: TextStyle(
          color: foregroundColor,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _FeedbackBanner extends StatelessWidget {
  const _FeedbackBanner({
    required this.message,
    required this.isError,
    super.key,
  });

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final background =
        isError ? const Color(0xFFFDECEC) : const Color(0xFFE1F3E8);
    final foreground =
        isError ? Theme.of(context).colorScheme.error : const Color(0xFF1B5E20);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: foreground),
        ),
        child: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: foreground,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
