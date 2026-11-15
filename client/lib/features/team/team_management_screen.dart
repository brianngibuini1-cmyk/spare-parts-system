import 'package:flutter/material.dart';

import 'team_controller.dart';
import 'team_models.dart';

class TeamManagementScreen extends StatefulWidget {
  const TeamManagementScreen({
    required this.controller,
    super.key,
  });

  final TeamController controller;

  @override
  State<TeamManagementScreen> createState() => _TeamManagementScreenState();
}

class _TeamManagementScreenState extends State<TeamManagementScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.controller.isOwner) {
        widget.controller.loadAttendants();
      }
    });
  }

  Future<void> _openCreateDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (context) =>
          _CreateAttendantDialog(controller: widget.controller),
    );
    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.actionMessage ?? 'Attendant account created.',
          ),
        ),
      );
    }
  }

  Future<void> _openManageDialog(AttendantAccount attendant) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _ManageAttendantDialog(
        controller: widget.controller,
        attendant: attendant,
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.actionMessage ?? 'Attendant account updated.',
          ),
        ),
      );
    }
  }

  Future<void> _toggleStatus(AttendantAccount attendant) async {
    final nextActive = !attendant.isActive;
    if (!nextActive) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Deactivate attendant'),
          content: Text(
            'Deactivate ${attendant.loginName}? This immediately signs out any active sessions for this account.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Deactivate'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }

    final updated = await widget.controller.setAttendantStatus(
      attendant,
      isActive: nextActive,
    );
    if (!mounted) {
      return;
    }
    if (updated != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.actionMessage ?? 'Attendant status updated.',
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
        if (!ctrl.isOwner) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Owner access is required to manage attendant accounts.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${ctrl.attendants.length} attendant account(s)',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh attendants',
                    onPressed: ctrl.isLoading || ctrl.isSaving
                        ? null
                        : ctrl.loadAttendants,
                    icon: const Icon(Icons.refresh),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    onPressed: ctrl.isSaving ? null : _openCreateDialog,
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: const Text('Add attendant'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (ctrl.isLoading && ctrl.attendants.isEmpty) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (ctrl.listError != null && ctrl.attendants.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(ctrl.listError!, textAlign: TextAlign.center),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: ctrl.loadAttendants,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }
                    if (ctrl.attendants.isEmpty) {
                      return const Center(
                        child: Text('No attendant accounts yet.'),
                      );
                    }
                    return RefreshIndicator(
                      onRefresh: ctrl.loadAttendants,
                      child: ListView.separated(
                        itemCount: ctrl.attendants.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final attendant = ctrl.attendants[index];
                          final createdLabel = attendant.createdAt != null
                              ? 'Created: ${attendant.createdAt!.toLocal().toString().split('.').first}'
                              : 'Account #${attendant.id}';
                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                child: Icon(
                                  attendant.isActive
                                      ? Icons.person_outline
                                      : Icons.person_off_outlined,
                                ),
                              ),
                              title: Text(
                                attendant.loginName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                'ID #${attendant.id} • $createdLabel',
                              ),
                              trailing: Wrap(
                                spacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Chip(
                                    label: Text(
                                      attendant.isActive
                                          ? 'Active'
                                          : 'Inactive',
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'View & edit status',
                                    onPressed: ctrl.isSaving
                                        ? null
                                        : () => _openManageDialog(attendant),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  TextButton(
                                    onPressed: ctrl.isSaving
                                        ? null
                                        : () => _toggleStatus(attendant),
                                    child: Text(
                                      attendant.isActive
                                          ? 'Deactivate'
                                          : 'Activate',
                                    ),
                                  ),
                                ],
                              ),
                              onTap: ctrl.isSaving
                                  ? null
                                  : () => _openManageDialog(attendant),
                            ),
                          );
                        },
                      ),
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

class _CreateAttendantDialog extends StatefulWidget {
  const _CreateAttendantDialog({required this.controller});

  final TeamController controller;

  @override
  State<_CreateAttendantDialog> createState() => _CreateAttendantDialogState();
}

class _CreateAttendantDialogState extends State<_CreateAttendantDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _loginController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _submitError;

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() => _submitError = null);
    final created = await widget.controller.createAttendant(
      AttendantCreateInput(
        loginName: _loginController.text,
        password: _passwordController.text,
      ),
    );
    if (!mounted) {
      return;
    }
    if (created != null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _submitError =
            widget.controller.actionError ?? 'Unable to create attendant.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final saving = widget.controller.isSaving;
        return AlertDialog(
          title: const Text('Add attendant'),
          content: SizedBox(
            width: 420,
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _loginController,
                      enabled: !saving,
                      decoration: const InputDecoration(
                        labelText: 'Login name *',
                        helperText: 'Trimmed and case-insensitive.',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => validateAttendantLoginName(v ?? ''),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      enabled: !saving,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        labelText: 'Password *',
                        helperText: 'Minimum 15 characters.',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (v) => validateAttendantPassword(v ?? ''),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _confirmPasswordController,
                      enabled: !saving,
                      obscureText: _obscureConfirm,
                      decoration: InputDecoration(
                        labelText: 'Confirm password *',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _obscureConfirm
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () => setState(
                            () => _obscureConfirm = !_obscureConfirm,
                          ),
                          icon: Icon(
                            _obscureConfirm
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (v) {
                        if (v != _passwordController.text) {
                          return 'Passwords do not match.';
                        }
                        return null;
                      },
                    ),
                    if (_submitError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _submitError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving ? null : _submit,
              child: Text(saving ? 'Creating...' : 'Create attendant'),
            ),
          ],
        );
      },
    );
  }
}

class _ManageAttendantDialog extends StatefulWidget {
  const _ManageAttendantDialog({
    required this.controller,
    required this.attendant,
  });

  final TeamController controller;
  final AttendantAccount attendant;

  @override
  State<_ManageAttendantDialog> createState() => _ManageAttendantDialogState();
}

class _ManageAttendantDialogState extends State<_ManageAttendantDialog> {
  late bool _isActive = widget.attendant.isActive;
  String? _submitError;

  Future<void> _save() async {
    if (_isActive == widget.attendant.isActive) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() => _submitError = null);
    final updated = await widget.controller.setAttendantStatus(
      widget.attendant,
      isActive: _isActive,
    );
    if (!mounted) {
      return;
    }
    if (updated != null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _submitError =
            widget.controller.actionError ?? 'Unable to update attendant.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final saving = widget.controller.isSaving;
        return AlertDialog(
          title: const Text('Attendant account'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Login name: ${widget.attendant.loginName}'),
                const SizedBox(height: 4),
                Text('Account ID: #${widget.attendant.id}'),
                const SizedBox(height: 4),
                Text('Role: ${widget.attendant.role}'),
                if (widget.attendant.createdAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Created: ${widget.attendant.createdAt!.toLocal().toString().split('.').first}',
                  ),
                ],
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Account active'),
                  subtitle: const Text(
                    'Deactivating immediately revokes active sessions.',
                  ),
                  value: _isActive,
                  onChanged: saving
                      ? null
                      : (value) => setState(() => _isActive = value),
                ),
                const SizedBox(height: 8),
                Text(
                  'Login name and password edits are not supported by the backend API.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_submitError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _submitError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(context).pop(false),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: saving ? null : _save,
              child: Text(saving ? 'Saving...' : 'Save changes'),
            ),
          ],
        );
      },
    );
  }
}
