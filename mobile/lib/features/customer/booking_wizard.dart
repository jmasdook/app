import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../common/widgets.dart';
import 'service_detail_screen.dart';
import 'account_screens.dart';

/// Select address -> describe issue (+photos) -> pick slot (held server-side) -> review price -> pay.
/// Availability, price and commission are all decided by the backend; this widget only renders them.
class BookingWizard extends ConsumerStatefulWidget {
  const BookingWizard({super.key, required this.serviceId});
  final String serviceId;
  @override
  ConsumerState<BookingWizard> createState() => _BookingWizardState();
}

class _BookingWizardState extends ConsumerState<BookingWizard> with BusyMixin {
  int _step = 0;
  Address? _address;
  final _description = TextEditingController(), _promo = TextEditingController();
  final List<File> _photos = [];
  DateTime _date = DateTime.now().add(const Duration(days: 1));
  int? _duration;
  Slot? _slot;
  List<Slot>? _slots;
  ({String id, DateTime expiresAt})? _hold;
  PricingQuote? _quote;
  String? _promoError;
  Timer? _ticker;
  Duration _left = Duration.zero;

  @override
  void dispose() {
    _ticker?.cancel();
    _description.dispose();
    _promo.dispose();
    super.dispose();
  }

  Future<void> _loadSlots(Service s) async {
    setState(() { _slots = null; _slot = null; });
    try {
      final all = await ref.read(catalogRepoProvider).slots(serviceId: s.id, areaId: _address!.areaId, date: _date, durationMinutes: _duration);
      // One chip per start time (several workers may share it; the server picks one when holding).
      final seen = <int>{};
      if (mounted) setState(() => _slots = [for (final x in all) if (seen.add(x.start.millisecondsSinceEpoch)) x]);
    } catch (e) {
      if (mounted) { setState(() => _slots = []); showSnack(context, friendlyError(e), error: true); }
    }
  }

  Future<void> _holdAndQuote(Service s) => run(() async {
        final repo = ref.read(bookingRepoProvider);
        final hold = await repo.reserve(serviceId: s.id, areaId: _address!.areaId, start: _slot!.start, durationMinutes: _duration);
        final quote = await ref.read(catalogRepoProvider).quote(serviceId: s.id, start: _slot!.start, durationMinutes: _duration, promoCode: _promo.text.trim());
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          final left = hold.expiresAt.difference(DateTime.now());
          if (mounted) setState(() => _left = left.isNegative ? Duration.zero : left);
        });
        setState(() { _hold = hold; _quote = quote; _step = 3; _promoError = null; });
      });

  Future<void> _applyPromo(Service s) async {
    try {
      final q = await ref.read(catalogRepoProvider).quote(serviceId: s.id, start: _slot!.start, durationMinutes: _duration, promoCode: _promo.text.trim());
      setState(() { _quote = q; _promoError = null; });
    } catch (e) {
      setState(() => _promoError = friendlyError(e));
    }
  }

  Future<void> _confirmAndPay(Service s) => run(() async {
        final repo = ref.read(bookingRepoProvider);
        final paths = <String>[];
        for (final f in _photos) { paths.add(await repo.uploadPhoto(f)); }
        final booking = await repo.createBooking(reservationId: _hold!.id, addressId: _address!.id, description: _description.text.trim(), promoCode: _promo.text.trim(), photoPaths: paths);
        try {
          await repo.pay(booking.id);
        } catch (e) {
          if (mounted) showSnack(context, 'Payment was not completed. You can retry from your booking.', error: true);
        }
        ref.invalidate(myBookingsProvider);
        if (mounted) context.go('/booking/${booking.id}');
      });

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(serviceProvider(widget.serviceId));
    return Scaffold(
      appBar: AppBar(title: const Text('Book a service')),
      body: AsyncBody<Service>(
        value: service,
        builder: (s) {
          if (_duration == null && s.isHourly) _duration = s.includedMinutes;
          final steps = ['Address', 'Details', 'Time', 'Review'];
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(children: [for (var i = 0; i < steps.length; i++) Expanded(child: Container(margin: const EdgeInsets.symmetric(horizontal: 2), height: 4, decoration: BoxDecoration(color: i <= _step ? AppColors.accent : AppColors.border, borderRadius: BorderRadius.circular(4))))]),
            ),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Align(alignment: Alignment.centerLeft, child: Text('Step ${_step + 1} of 4 · ${steps[_step]}', style: const TextStyle(color: AppColors.muted)))),
            Expanded(child: AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: KeyedSubtree(key: ValueKey(_step), child: _body(s)))),
          ]);
        },
      ),
    );
  }

  Widget _body(Service s) {
    switch (_step) {
      case 0:
        final addrs = ref.watch(addressesProvider);
        return _scroll([
          AsyncBody<List<Address>>(
            value: addrs,
            onRetry: () => ref.invalidate(addressesProvider),
            builder: (list) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (list.isEmpty) const EmptyState(icon: Icons.home_outlined, title: 'Where should we come?', message: 'Add the address for this service.'),
              RadioGroup<String>(
                groupValue: _address?.id,
                onChanged: (id) => setState(() => _address = list.firstWhere((a) => a.id == id)),
                child: Column(children: [for (final a in list) Card(child: RadioListTile<String>(value: a.id, title: Text(a.label), subtitle: Text('${a.line1}, ${a.city}')))]),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: () async { await showAddAddressSheet(context, ref); ref.invalidate(addressesProvider); }, icon: const Icon(Icons.add_location_alt_outlined), label: const Text('Add a new address')),
              const SizedBox(height: 20),
              FilledButton(onPressed: _address == null ? null : () { setState(() => _step = 1); }, child: const Text('Continue')),
            ]),
          ),
        ]);
      case 1:
        return _scroll([
          TextField(controller: _description, maxLines: 4, maxLength: 1000, decoration: const InputDecoration(labelText: 'Describe the issue (optional)', alignLabelWithHint: true)),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final f in _photos) Stack(children: [ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(f, width: 84, height: 84, fit: BoxFit.cover, cacheWidth: 200)), Positioned(right: 0, top: 0, child: IconButton.filled(iconSize: 16, visualDensity: VisualDensity.compact, tooltip: 'Remove photo', onPressed: () => setState(() => _photos.remove(f)), icon: const Icon(Icons.close)))]),
            if (_photos.length < 4)
              InkWell(
                onTap: () async {
                  final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 80);
                  if (x != null) setState(() => _photos.add(File(x.path)));
                },
                child: Container(width: 84, height: 84, decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.add_a_photo_outlined)),
              ),
          ]),
          const SizedBox(height: 24),
          FilledButton(onPressed: () { setState(() => _step = 2); _loadSlots(s); }, child: const Text('Continue')),
          TextButton(onPressed: () => setState(() => _step = 0), child: const Text('Back')),
        ]);
      case 2:
        final days = [for (var i = 1; i <= 14; i++) DateTime.now().add(Duration(days: i))];
        return _scroll([
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: days.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (c, i) {
                final d = days[i];
                final sel = d.year == _date.year && d.month == _date.month && d.day == _date.day;
                return ChoiceChip(
                  selected: sel,
                  label: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(DateFormat('EEE').format(d)), Text('${d.day}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18))]),
                  onSelected: (_) { _date = d; _loadSlots(s); },
                );
              },
            ),
          ),
          if (s.isHourly) ...[
            const SizedBox(height: 12),
            Row(children: [
              const Text('Hours'),
              const Spacer(),
              IconButton(tooltip: 'Fewer hours', onPressed: (_duration ?? 0) > s.includedMinutes ? () { _duration = _duration! - 60; _loadSlots(s); } : null, icon: const Icon(Icons.remove_circle_outline)),
              Text(formatDuration(_duration ?? s.includedMinutes), style: const TextStyle(fontWeight: FontWeight.w700)),
              IconButton(tooltip: 'More hours', onPressed: (_duration ?? 0) + 60 <= s.maxDurationMinutes ? () { _duration = _duration! + 60; _loadSlots(s); } : null, icon: const Icon(Icons.add_circle_outline)),
            ]),
          ],
          const SizedBox(height: 12),
          if (_slots == null) const Skeleton(height: 44, count: 4)
          else if (_slots!.isEmpty) const EmptyState(icon: Icons.event_busy, title: 'No openings that day', message: 'Try another date.')
          else Wrap(spacing: 8, runSpacing: 8, children: [for (final sl in _slots!) ChoiceChip(label: Text(DateFormat('h:mm a').format(sl.start)), selected: _slot?.start == sl.start, onSelected: (_) => setState(() => _slot = sl))]),
          const SizedBox(height: 24),
          FilledButton(onPressed: _slot == null || busy ? null : () => _holdAndQuote(s), child: const Text('Hold this time & continue')),
          TextButton(onPressed: () => setState(() => _step = 1), child: const Text('Back')),
        ]);
      default:
        final q = _quote!;
        final expired = _left == Duration.zero && _hold != null && _hold!.expiresAt.isBefore(DateTime.now());
        return _scroll([
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            Text('${DateFormat('EEE d MMM · h:mm a').format(_slot!.start)} · ${formatDuration(q.durationMinutes)}'),
            Text(_address!.line1, style: const TextStyle(color: AppColors.muted)),
          ]))),
          const SizedBox(height: 12),
          Row(children: [Expanded(child: TextField(controller: _promo, textCapitalization: TextCapitalization.characters, decoration: InputDecoration(labelText: 'Promo code', errorText: _promoError))), const SizedBox(width: 8), OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(90, 56)), onPressed: () => _applyPromo(s), child: const Text('Apply'))]),
          const SizedBox(height: 12),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            for (final l in q.lines) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l.label), Text(formatMoney(l.amountMinor, currency: q.currency), style: TextStyle(color: l.amountMinor < 0 ? AppColors.ok : null))])),
            const Divider(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Total payable', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)), Text(formatMoney(q.totalMinor, currency: q.currency), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18))]),
          ]))),
          const SizedBox(height: 8),
          Text(expired ? 'Your hold expired. Go back and pick a time again.' : 'Slot held for ${_left.inMinutes}:${(_left.inSeconds % 60).toString().padLeft(2, '0')}', style: TextStyle(color: expired ? AppColors.danger : AppColors.muted), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: busy || expired ? null : () => _confirmAndPay(s), child: Text('Confirm & pay ${formatMoney(q.totalMinor, currency: q.currency)}')),
          TextButton(onPressed: () => setState(() => _step = 2), child: const Text('Back')),
        ]);
    }
  }

  Widget _scroll(List<Widget> children) => ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: children);
}
