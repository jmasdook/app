import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../common/widgets.dart';

class BookingsScreen extends ConsumerWidget {
  const BookingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const tabs = ['Upcoming', 'Active', 'Completed', 'Cancelled', 'Disputed'];
    bool match(int i, Booking b) => switch (i) {
          0 => b.isUpcoming,
          1 => b.isActive,
          2 => b.status == 'completed',
          3 => b.status == 'cancelled',
          _ => b.status == 'disputed',
        };
    return DefaultTabController(
      length: tabs.length,
      child: SafeArea(
        child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 0), child: Align(alignment: Alignment.centerLeft, child: Text('Bookings', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)))),
          TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final t in tabs) Tab(text: t)]),
          Expanded(
            child: AsyncBody<List<Booking>>(
              value: ref.watch(myBookingsProvider),
              onRetry: () => ref.invalidate(myBookingsProvider),
              builder: (all) => TabBarView(children: [
                for (var i = 0; i < tabs.length; i++)
                  RefreshIndicator(
                    onRefresh: () async => ref.invalidate(myBookingsProvider),
                    child: Builder(builder: (c) {
                      final list = all.where((b) => match(i, b)).toList();
                      if (list.isEmpty) return ListView(children: [SizedBox(height: 300, child: EmptyState(icon: Icons.event_available, title: 'Nothing here', message: i == 0 ? 'Book a service to get started.' : null))]);
                      return ListView.separated(padding: const EdgeInsets.all(20), itemCount: list.length, separatorBuilder: (_, _) => const SizedBox(height: 12), itemBuilder: (c, j) => _BookingCard(list[j]));
                    }),
                  ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _BookingCard extends StatelessWidget {
  const _BookingCard(this.b);
  final Booking b;
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          onTap: () => context.push('/booking/${b.id}'),
          title: Text(b.serviceName.isEmpty ? b.ref : b.serviceName, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Text('${DateFormat('EEE d MMM · h:mm a').format(b.start)}\n${b.ref} · ${formatMoney(b.totalMinor, currency: b.currency)}')),
          isThreeLine: true,
          trailing: StatusChip(b.status),
        ),
      );
}

final bookingDetailProvider = FutureProvider.family<Booking, String>((ref, id) => ref.watch(bookingRepoProvider).booking(id));
final _historyProvider = FutureProvider.family<List<StatusEvent>, String>((ref, id) => ref.watch(bookingRepoProvider).history(id));
final _workerInfoProvider = FutureProvider.family<Json?, String>((ref, id) => ref.watch(bookingRepoProvider).workerInfo(id));
final _extraProvider = FutureProvider.family<ExtraTimeRequest?, String>((ref, id) => ref.watch(bookingRepoProvider).openExtraTime(id));

class BookingDetailScreen extends ConsumerStatefulWidget {
  const BookingDetailScreen({super.key, required this.bookingId});
  final String bookingId;
  @override
  ConsumerState<BookingDetailScreen> createState() => _BookingDetailState();
}

class _BookingDetailState extends ConsumerState<BookingDetailScreen> with BusyMixin {
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    // Light polling so status changes (en route, extra-time requests) appear without push.
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(bookingDetailProvider(widget.bookingId));
    ref.invalidate(_historyProvider(widget.bookingId));
    ref.invalidate(_extraProvider(widget.bookingId));
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.bookingId;
    return Scaffold(
      appBar: AppBar(title: const Text('Booking')),
      body: AsyncBody<Booking>(
        value: ref.watch(bookingDetailProvider(id)),
        onRetry: _refresh,
        builder: (b) {
          final history = ref.watch(_historyProvider(id)).value ?? const <StatusEvent>[];
          final worker = ref.watch(_workerInfoProvider(id)).value;
          final extra = ref.watch(_extraProvider(id)).value;
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Row(children: [Expanded(child: Text(b.serviceName, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))), StatusChip(b.status)]),
              Text('${b.ref} · ${DateFormat('EEE d MMM · h:mm a').format(b.start)}', style: const TextStyle(color: AppColors.muted)),
              if (extra != null && extra.status == 'pending') ...[
                const SizedBox(height: 16),
                Card(color: AppColors.accentSoft, child: ListTile(leading: const Icon(Icons.more_time, color: AppColors.accent), title: Text('Extra time requested: ${formatDuration(extra.minutes)}', style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.navy)), subtitle: const Text('Tap to review and decide', style: TextStyle(color: AppColors.navy)), trailing: const Icon(Icons.chevron_right), onTap: () async { await context.push('/extra/${extra.id}', extra: extra); _refresh(); })),
              ],
              if (extra != null && extra.status == 'awaiting_payment') ...[
                const SizedBox(height: 16),
                Card(child: ListTile(leading: const Icon(Icons.payments_outlined), title: Text('Pay ${formatMoney(extra.totalMinor, currency: extra.currency)} to confirm extra time'), trailing: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(80, 44)), onPressed: busy ? null : () => run(() async { await ref.read(bookingRepoProvider).pay(b.id, extraRequestId: extra.id); _refresh(); }), child: const Text('Pay')))),
              ],
              if (worker != null) ...[
                const SectionTitle('Your professional'),
                Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.engineering)), title: Text((worker['display_name'] ?? '') as String), subtitle: Text('Rating ${worker['rating_avg']} (${worker['rating_count']})'), trailing: IconButton(tooltip: 'Message', icon: const Icon(Icons.chat_bubble_outline), onPressed: () => context.push('/chat/${b.id}')))),
              ],
              const SectionTitle('Status'),
              if (b.status == 'pending_payment') Card(child: ListTile(leading: const Icon(Icons.hourglass_top), title: const Text('Awaiting payment'), subtitle: const Text('Your slot is held for a few minutes.'), trailing: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(80, 44)), onPressed: busy ? null : () => run(() async { await ref.read(bookingRepoProvider).pay(b.id); _refresh(); }), child: const Text('Pay')))),
              _Timeline(history),
              const SectionTitle('Payment'),
              Card(child: ListTile(title: const Text('Total'), trailing: Text(formatMoney(b.totalMinor, currency: b.currency), style: const TextStyle(fontWeight: FontWeight.w800)), subtitle: b.extraMinutes > 0 ? Text('+ ${formatDuration(b.extraMinutes)} approved extra time (billed separately)') : null)),
              const SizedBox(height: 16),
              if (b.status == 'awaiting_confirmation') ...[
                FilledButton(onPressed: busy ? null : () => run(() async { await ref.read(bookingRepoProvider).confirmCompletion(b.id); _refresh(); ref.invalidate(myBookingsProvider); }, success: 'Thanks for confirming!'), child: const Text('Confirm work is complete')),
                const SizedBox(height: 8),
              ],
              if (b.status == 'completed') ...[
                FilledButton.icon(onPressed: () => _review(b), icon: const Icon(Icons.star_outline), label: const Text('Rate this job')),
                const SizedBox(height: 8),
              ],
              if (b.canCancel) OutlinedButton(onPressed: busy ? null : () => _cancel(b), child: const Text('Cancel booking')),
              if (const {'awaiting_confirmation', 'completed', 'en_route', 'arrived', 'in_progress'}.contains(b.status)) ...[
                const SizedBox(height: 8),
                OutlinedButton(onPressed: () => _dispute(b), child: const Text('Report a problem')),
              ],
              const SizedBox(height: 8),
              TextButton.icon(onPressed: () => context.push('/support?booking=${b.id}'), icon: const Icon(Icons.support_agent), label: const Text('Get help with this booking')),
            ]),
          );
        },
      ),
    );
  }

  Future<void> _cancel(Booking b) async {
    final ok = await confirmDialog(context, title: 'Cancel this booking?', message: 'Any refund follows the cancellation policy shown when you booked.', confirm: 'Cancel booking', destructive: true);
    if (!ok) return;
    await run(() async { await ref.read(bookingRepoProvider).cancel(b.id, 'Cancelled by customer'); _refresh(); ref.invalidate(myBookingsProvider); }, success: 'Booking cancelled');
  }

  Future<void> _dispute(Booking b) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Report a problem'), content: TextField(controller: c, maxLines: 4, decoration: const InputDecoration(hintText: 'What went wrong? (min 10 characters)')), actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(90, 44)), onPressed: () => Navigator.pop(d, true), child: const Text('Submit'))]));
    final text = c.text.trim();
    c.dispose();
    if (ok == true && text.length >= 10) await run(() async { await ref.read(bookingRepoProvider).dispute(b.id, text); _refresh(); }, success: 'Our team will review this and contact you.');
  }

  Future<void> _review(Booking b) async {
    var rating = 5;
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(
        title: const Text('Rate your professional'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 1; i <= 5; i++) IconButton(tooltip: '$i stars', onPressed: () => set(() => rating = i), icon: Icon(i <= rating ? Icons.star_rounded : Icons.star_outline_rounded, color: const Color(0xFFF2B01E), size: 32))]),
          TextField(controller: c, maxLines: 3, decoration: const InputDecoration(hintText: 'Add a comment (optional)')),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(90, 44)), onPressed: () => Navigator.pop(d, true), child: const Text('Submit'))],
      )),
    );
    final text = c.text.trim();
    c.dispose();
    if (ok == true) await run(() => ref.read(bookingRepoProvider).review(b.id, rating, text), success: 'Thanks for your review!');
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline(this.events);
  final List<StatusEvent> events;
  @override
  Widget build(BuildContext context) => Column(children: [
        for (var i = 0; i < events.length; i++)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Column(children: [
                Container(width: 14, height: 14, margin: const EdgeInsets.only(top: 4), decoration: BoxDecoration(shape: BoxShape.circle, color: i == events.length - 1 ? AppColors.accent : AppColors.border)),
                if (i != events.length - 1) Expanded(child: Container(width: 2, color: AppColors.border)),
              ]),
              const SizedBox(width: 14),
              Expanded(child: Padding(padding: const EdgeInsets.only(bottom: 14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(events[i].status.replaceAll('_', ' '), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(DateFormat('d MMM, h:mm a').format(events[i].at), style: const TextStyle(color: AppColors.muted, fontSize: 12)),
              ]))),
            ]),
          ),
      ]);
}

/// Customer decision on a worker's extra-time request. Approval opens a payment step; nothing is charged by this screen.
class ExtraTimeScreen extends ConsumerStatefulWidget {
  const ExtraTimeScreen({super.key, required this.request});
  final ExtraTimeRequest request;
  @override
  ConsumerState<ExtraTimeScreen> createState() => _ExtraTimeState();
}

class _ExtraTimeState extends ConsumerState<ExtraTimeScreen> with BusyMixin {
  Future<void> _decide(bool approve) => run(() async {
        final r = widget.request;
        final updated = await ref.read(bookingRepoProvider).decideExtraTime(r.id, approve);
        if (!mounted) return;
        if (updated.status == 'expired') {
          showSnack(context, 'This request has expired. Ask your professional to send a new one.', error: true);
        } else if (approve) {
          // Step 2: explicit payment authorisation (server-verified). Declining here keeps the request unpaid.
          try {
            await ref.read(bookingRepoProvider).pay(r.bookingId, extraRequestId: r.id);
            if (mounted) showSnack(context, 'Extra time confirmed.');
          } catch (e) {
            if (mounted) showSnack(context, 'Approved. Complete the payment from the booking page to confirm.', error: true);
          }
        }
        if (mounted) context.pop();
      });

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return Scaffold(
      appBar: AppBar(title: const Text('Extra time request')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text('Your professional needs ${formatDuration(r.minutes)} more', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Reason', style: TextStyle(color: AppColors.muted)), Text(r.reason)]))),
        const SizedBox(height: 12),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          _line('Rate', '${formatMoney(r.rateMinor, currency: r.currency)} / hour'),
          _line('Extra time', formatDuration(r.minutes)),
          _line('Subtotal', formatMoney(r.netMinor, currency: r.currency)),
          _line('VAT', formatMoney(r.taxMinor, currency: r.currency)),
          const Divider(),
          _line('Total to pay', formatMoney(r.totalMinor, currency: r.currency), bold: true),
        ]))),
        const SizedBox(height: 8),
        Text('Respond by ${DateFormat('h:mm a').format(r.expiresAt)}. You are only charged if you approve and complete payment.', style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 20),
        FilledButton(onPressed: busy ? null : () => _decide(true), child: Text('Approve & pay ${formatMoney(r.totalMinor, currency: r.currency)}')),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: busy ? null : () => _decide(false), child: const Text('Decline')),
      ]),
    );
  }

  Widget _line(String l, String v, {bool bold = false}) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: TextStyle(fontWeight: bold ? FontWeight.w800 : null)), Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600))]));
}

final _messagesProvider = FutureProvider.family<List<ChatMessage>, String>((ref, id) => ref.watch(bookingRepoProvider).messages(id));

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.bookingId});
  final String bookingId;
  @override
  ConsumerState<ChatScreen> createState() => _ChatState();
}

class _ChatState extends ConsumerState<ChatScreen> with BusyMixin {
  final _c = TextEditingController();
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => ref.invalidate(_messagesProvider(widget.bookingId)));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authRepoProvider).userId;
    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: Column(children: [
        Expanded(
          child: AsyncBody<List<ChatMessage>>(
            value: ref.watch(_messagesProvider(widget.bookingId)),
            builder: (list) => list.isEmpty
                ? const EmptyState(icon: Icons.chat_bubble_outline, title: 'No messages yet', message: 'Phone numbers stay private; chat here about this booking.')
                : ListView(padding: const EdgeInsets.all(16), children: [for (final m in list) Align(alignment: m.senderId == me ? Alignment.centerRight : Alignment.centerLeft, child: Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .75), decoration: BoxDecoration(color: m.senderId == me ? AppColors.accent : AppColors.accentSoft, borderRadius: BorderRadius.circular(16)), child: Text(m.body, style: TextStyle(color: m.senderId == me ? Colors.white : AppColors.navy))))]),
          ),
        ),
        SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 8), child: Row(children: [
          Expanded(child: TextField(controller: _c, maxLength: 1000, decoration: const InputDecoration(hintText: 'Message', counterText: ''))),
          const SizedBox(width: 8),
          IconButton.filled(tooltip: 'Send', onPressed: busy ? null : () => run(() async { final t = _c.text.trim(); if (t.isEmpty) return; await ref.read(bookingRepoProvider).sendMessage(widget.bookingId, t); _c.clear(); ref.invalidate(_messagesProvider(widget.bookingId)); }), icon: const Icon(Icons.send)),
        ]))),
      ]),
    );
  }
}

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 8), child: Text('Notifications', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
          Expanded(
            child: AsyncBody<List<AppNotification>>(
              value: ref.watch(notificationsProvider),
              onRetry: () => ref.invalidate(notificationsProvider),
              builder: (list) => list.isEmpty
                  ? const EmptyState(icon: Icons.notifications_none, title: 'All caught up', message: 'Booking updates and reminders appear here.')
                  : RefreshIndicator(
                      onRefresh: () async => ref.invalidate(notificationsProvider),
                      child: ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (c, i) {
                          final n = list[i];
                          return Card(
                            child: ListTile(
                              leading: Icon(n.read ? Icons.notifications_none : Icons.notifications_active, color: n.read ? AppColors.muted : AppColors.accent),
                              title: Text(n.title, style: TextStyle(fontWeight: n.read ? FontWeight.w500 : FontWeight.w800)),
                              subtitle: Text('${n.body}\n${DateFormat('d MMM, h:mm a').format(n.createdAt)}'),
                              isThreeLine: true,
                              onTap: () async {
                                await ref.read(bookingRepoProvider).markNotificationRead(n.id);
                                ref.invalidate(notificationsProvider);
                                final id = n.data['booking_id'];
                                if (id is String && context.mounted) unawaited(context.push('/booking/$id'));
                              },
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ),
        ]),
      );
}
