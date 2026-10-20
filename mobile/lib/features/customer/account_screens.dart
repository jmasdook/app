import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/env.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../common/widgets.dart';

Future<void> showAddAddressSheet(BuildContext context, WidgetRef ref) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => const _AddAddressSheet(),
    );

class _AddAddressSheet extends ConsumerStatefulWidget {
  const _AddAddressSheet();
  @override
  ConsumerState<_AddAddressSheet> createState() => _AddAddressState();
}

class _AddAddressState extends ConsumerState<_AddAddressSheet> with BusyMixin {
  final _label = TextEditingController(text: 'Home'), _line = TextEditingController();
  ServiceArea? _area;
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _label.dispose();
    _line.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final areas = ref.watch(areasProvider).value ?? const <ServiceArea>[];
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Form(
        key: _form,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('New address', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          TextFormField(controller: _label, decoration: const InputDecoration(labelText: 'Label')),
          const SizedBox(height: 12),
          TextFormField(controller: _line, decoration: const InputDecoration(labelText: 'Building, street, apartment'), validator: (v) => (v == null || v.trim().length < 3) ? 'Enter the address' : null),
          const SizedBox(height: 12),
          DropdownButtonFormField<ServiceArea>(
            initialValue: _area,
            decoration: const InputDecoration(labelText: 'Area'),
            items: [for (final a in areas) DropdownMenuItem(value: a, child: Text(a.label))],
            onChanged: (v) => setState(() => _area = v),
            validator: (v) => v == null ? 'Choose an area' : null,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : () async {
              if (!_form.currentState!.validate()) return;
              await run(() async {
                await ref.read(bookingRepoProvider).addAddress(label: _label.text.trim(), line1: _line.text.trim(), city: _area!.city, areaId: _area!.id);
                ref.invalidate(addressesProvider);
                if (context.mounted) Navigator.pop(context);
              });
            },
            child: const Text('Save address'),
          ),
        ]),
      ),
    );
  }
}

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final roles = ref.watch(rolesProvider).value ?? const <String>{};
    final addresses = ref.watch(addressesProvider);
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
        Text('Account', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.person)), title: Text((profile?['full_name'] ?? '') as String), subtitle: Text((profile?['phone'] ?? 'No phone added') as String), trailing: const Icon(Icons.edit_outlined), onTap: () => _editProfile(context, ref, profile))),
        const SectionTitle('Saved addresses'),
        AsyncBody<List<Address>>(
          value: addresses,
          builder: (list) => Column(children: [
            for (final a in list) Card(child: ListTile(leading: const Icon(Icons.home_outlined), title: Text(a.label), subtitle: Text('${a.line1}, ${a.city}'), trailing: IconButton(tooltip: 'Delete address', icon: const Icon(Icons.delete_outline), onPressed: () async {
              await ref.read(bookingRepoProvider).deleteAddress(a.id);
              ref.invalidate(addressesProvider);
            }))),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: () => showAddAddressSheet(context, ref), icon: const Icon(Icons.add), label: const Text('Add address')),
          ]),
        ),
        const SectionTitle('Help & privacy'),
        Card(child: Column(children: [
          ListTile(leading: const Icon(Icons.support_agent), title: const Text('Support & complaints'), trailing: const Icon(Icons.chevron_right), onTap: () => context.push('/support')),
          if (roles.contains('worker')) ListTile(leading: const Icon(Icons.engineering), title: const Text('Switch to professional mode'), trailing: const Icon(Icons.chevron_right), onTap: () => ref.read(workerModeProvider.notifier).set(true)),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('Request account deletion'),
            subtitle: const Text('Personal data is anonymised; financial records are kept as required by law.'),
            onTap: () async {
              final ok = await confirmDialog(context, title: 'Request deletion?', message: 'Our team will review your request. Accounts with open bookings or balances cannot be deleted until resolved.', confirm: 'Request deletion', destructive: true);
              if (ok) {
                await ref.read(authRepoProvider).requestAccountDeletion();
                if (context.mounted) showSnack(context, 'Deletion requested. We will confirm by email.');
              }
            },
          ),
        ])),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: () => ref.read(authRepoProvider).signOut(), icon: const Icon(Icons.logout), label: const Text('Sign out')),
        const SizedBox(height: 12),
        const Center(child: Text('${Env.brandName} · v1.0.0', style: TextStyle(fontSize: 12))),
      ]),
    );
  }

  Future<void> _editProfile(BuildContext context, WidgetRef ref, Json? p) async {
    final name = TextEditingController(text: (p?['full_name'] ?? '') as String), phone = TextEditingController(text: (p?['phone'] ?? '') as String);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Edit profile'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name')),
          const SizedBox(height: 12),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone (+971…)')),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(90, 44)), onPressed: () => Navigator.pop(c, true), child: const Text('Save'))],
      ),
    );
    if (ok == true) {
      try {
        await ref.read(authRepoProvider).updateProfile(fullName: name.text.trim(), phone: phone.text.trim());
        ref.invalidate(profileProvider);
      } catch (e) {
        if (context.mounted) showSnack(context, 'Check the phone format, e.g. +971501234567', error: true);
      }
    }
    name.dispose();
    phone.dispose();
  }
}

class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({super.key, this.bookingId});
  final String? bookingId;
  @override
  ConsumerState<SupportScreen> createState() => _SupportState();
}

class _SupportState extends ConsumerState<SupportScreen> with BusyMixin {
  final _subject = TextEditingController(), _body = TextEditingController();
  String _category = 'general';
  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tickets = ref.watch(_ticketsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Support')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('How can we help?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(initialValue: _category, decoration: const InputDecoration(labelText: 'Topic'), items: const [
            DropdownMenuItem(value: 'general', child: Text('General question')), DropdownMenuItem(value: 'booking', child: Text('A booking')), DropdownMenuItem(value: 'payment', child: Text('Payment or refund')),
            DropdownMenuItem(value: 'complaint', child: Text('Complaint')), DropdownMenuItem(value: 'account', child: Text('My account')),
          ], onChanged: (v) => setState(() => _category = v ?? 'general')),
          const SizedBox(height: 12),
          TextField(controller: _subject, decoration: const InputDecoration(labelText: 'Subject')),
          const SizedBox(height: 12),
          TextField(controller: _body, maxLines: 4, decoration: const InputDecoration(labelText: 'Tell us more', alignLabelWithHint: true)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : () => run(() async {
              if (_subject.text.trim().length < 3 || _body.text.trim().isEmpty) throw Exception('missing');
              await ref.read(bookingRepoProvider).createTicket(subject: _subject.text.trim(), body: _body.text.trim(), category: _category, bookingId: widget.bookingId);
              _subject.clear();
              _body.clear();
              ref.invalidate(_ticketsProvider);
            }, success: 'Thanks, our team will reply soon.'),
            child: const Text('Send'),
          ),
        ]))),
        const SectionTitle('Your tickets'),
        AsyncBody<List<SupportTicket>>(
          value: tickets,
          builder: (list) => list.isEmpty ? const EmptyState(icon: Icons.mark_email_read_outlined, title: 'No tickets yet') : Column(children: [for (final t in list) Card(child: ListTile(title: Text(t.subject), trailing: StatusChip(t.status)))]),
        ),
      ]),
    );
  }
}

final _ticketsProvider = FutureProvider<List<SupportTicket>>((ref) => ref.watch(bookingRepoProvider).tickets());
