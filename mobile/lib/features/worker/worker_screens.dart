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

/// Worker home: availability switch, today's jobs, next job and earnings summary.
class WorkerHomeScreen extends ConsumerWidget {
  const WorkerHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(workerProfileProvider);
    return SafeArea(
      child: AsyncBody<Json?>(
        value: profile,
        onRetry: () => ref.invalidate(workerProfileProvider),
        builder: (p) {
          if (p == null) return const _BecomeWorker();
          final status = p['status'] as String;
          if (status != 'approved') return _VerificationGate(status: status, reason: p['status_reason'] as String?);
          return _ApprovedHome(profile: p);
        },
      ),
    );
  }
}

class _BecomeWorker extends ConsumerWidget {
  const _BecomeWorker();
  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(icon: Icons.engineering, title: 'Become a verified professional', message: 'Create your profile, upload your documents and our team will verify you.', action: FilledButton(onPressed: () async { await ref.read(workerRepoProvider).becomeWorker(); ref.invalidate(workerProfileProvider); }, child: const Text('Get started')));
}

class _VerificationGate extends ConsumerWidget {
  const _VerificationGate({required this.status, this.reason});
  final String status;
  final String? reason;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editable = const {'draft', 'rejected', 'expired_credentials'}.contains(status);
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text('Verification', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Text('Status: ', style: TextStyle(fontWeight: FontWeight.w700)), StatusChip(status)]),
        const SizedBox(height: 8),
        Text(switch (status) {
          'draft' => 'Complete your profile and submit it for verification. You cannot receive bookings until approved.',
          'submitted' || 'under_review' => 'Our team is reviewing your application. We will notify you as soon as it is done.',
          'rejected' => 'Your application was not approved. ${reason ?? ''} You can fix the issues and resubmit.',
          'suspended' => 'Your account is suspended. ${reason ?? ''} Contact support for help.',
          'expired_credentials' => 'A required credential expired. Upload a renewed document and resubmit to receive bookings again.',
          _ => '',
        }),
      ]))),
      if (editable) ...[
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: () => context.push('/worker/onboarding'), icon: const Icon(Icons.assignment_ind_outlined), label: const Text('Profile, documents & skills')),
      ],
      const SizedBox(height: 12),
      OutlinedButton(onPressed: () => ref.read(authRepoProvider).signOut(), child: const Text('Sign out')),
    ]);
  }
}

class _ApprovedHome extends ConsumerWidget {
  const _ApprovedHome({required this.profile});
  final Json profile;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(workerJobsProvider);
    final earnings = ref.watch(earningsProvider).value ?? const <Earning>[];
    int sum(bool Function(Earning) f) => earnings.where(f).fold(0, (a, e) => a + e.amountMinor);
    final available = (profile['is_available'] ?? true) as bool;
    return RefreshIndicator(
      onRefresh: () async { ref.invalidate(workerJobsProvider); ref.invalidate(earningsProvider); },
      child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
        Row(children: [Expanded(child: Text('Today', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))), Text(available ? 'Online' : 'Offline'), Switch(value: available, onChanged: (v) async { await ref.read(workerRepoProvider).setAvailable(v); ref.invalidate(workerProfileProvider); })]),
        AsyncBody<List<WorkerJob>>(
          value: jobs,
          onRetry: () => ref.invalidate(workerJobsProvider),
          builder: (all) {
            final now = DateTime.now();
            bool today(WorkerJob j) => j.start.year == now.year && j.start.month == now.month && j.start.day == now.day;
            final open = all.where((j) => const {'assigned', 'accepted', 'en_route', 'arrived', 'in_progress', 'awaiting_confirmation'}.contains(j.status)).toList();
            final next = open.where((j) => j.end.isAfter(now)).firstOrNull;
            final todays = open.where(today).toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (next != null) ...[const SectionTitle('Next appointment'), _JobCard(next, highlight: true)],
              const SectionTitle("Today's jobs"),
              if (todays.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('No jobs scheduled today.')) else for (final j in todays) Padding(padding: const EdgeInsets.only(bottom: 10), child: _JobCard(j)),
            ]);
          },
        ),
        const SectionTitle('Earnings'),
        Row(children: [
          Expanded(child: _Kpi('Payable soon', formatMoney(sum((e) => e.status == 'eligible' || e.status == 'in_payout')))),
          const SizedBox(width: 12),
          Expanded(child: _Kpi('Paid out', formatMoney(sum((e) => e.status == 'paid')))),
        ]),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: () => context.go('/worker/earnings'), child: const Text('View earnings & payouts')),
      ]),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)), Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12))])));
}

class _JobCard extends StatelessWidget {
  const _JobCard(this.job, {this.highlight = false});
  final WorkerJob job;
  final bool highlight;
  @override
  Widget build(BuildContext context) => Card(
        color: highlight ? AppColors.accentSoft : null,
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          onTap: () => context.push('/worker/job/${job.id}'),
          title: Text('${DateFormat('h:mm a').format(job.start)} · ${job.customerFirstName}', style: TextStyle(fontWeight: FontWeight.w800, color: highlight ? AppColors.navy : null)),
          subtitle: Text('${job.ref} · you earn ${formatMoney(job.earningMinor, currency: job.currency)}', style: TextStyle(color: highlight ? AppColors.navy : null)),
          trailing: StatusChip(job.status),
        ),
      );
}

class JobsScreen extends ConsumerWidget {
  const JobsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 8), child: Text('My jobs', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
          Expanded(
            child: AsyncBody<List<WorkerJob>>(
              value: ref.watch(workerJobsProvider),
              onRetry: () => ref.invalidate(workerJobsProvider),
              builder: (list) => list.isEmpty
                  ? const EmptyState(icon: Icons.work_outline, title: 'No jobs yet', message: 'New assignments will appear here and in your notifications.')
                  : RefreshIndicator(onRefresh: () async => ref.invalidate(workerJobsProvider), child: ListView.separated(padding: const EdgeInsets.all(20), itemCount: list.length, separatorBuilder: (_, _) => const SizedBox(height: 10), itemBuilder: (c, i) => _JobCard(list[i]))),
            ),
          ),
        ]),
      );
}

final _jobProvider = FutureProvider.family<WorkerJob, String>((ref, id) => ref.watch(workerRepoProvider).job(id));
final _jobExtraProvider = FutureProvider.family<List<ExtraTimeRequest>, String>((ref, id) => ref.watch(workerRepoProvider).extraRequests(id));

class JobDetailScreen extends ConsumerStatefulWidget {
  const JobDetailScreen({super.key, required this.jobId});
  final String jobId;
  @override
  ConsumerState<JobDetailScreen> createState() => _JobDetailState();
}

class _JobDetailState extends ConsumerState<JobDetailScreen> with BusyMixin {
  void _refresh() {
    ref.invalidate(_jobProvider(widget.jobId));
    ref.invalidate(_jobExtraProvider(widget.jobId));
    ref.invalidate(workerJobsProvider);
  }

  Future<void> _advance(WorkerJob j, String to, String label) async {
    if (to == 'awaiting_confirmation') {
      final ok = await confirmDialog(context, title: 'Mark work as done?', message: 'The customer will be asked to confirm completion.', confirm: 'Yes, done');
      if (!ok) return;
    }
    await run(() async { await ref.read(workerRepoProvider).updateStatus(j.id, to); _refresh(); });
  }

  Future<void> _reject(WorkerJob j) async {
    final ok = await confirmDialog(context, title: 'Decline this job?', message: 'It will be offered to another professional.', confirm: 'Decline', destructive: true);
    if (ok) await run(() async { await ref.read(workerRepoProvider).updateStatus(j.id, 'unassigned', reason: 'worker declined'); _refresh(); if (mounted) context.pop(); });
  }

  Future<void> _requestExtra(WorkerJob j) async {
    var minutes = 60;
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(
        title: const Text('Request extra time'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<int>(initialValue: minutes, decoration: const InputDecoration(labelText: 'Extra time'), items: [for (final m in [30, 60, 90, 120]) DropdownMenuItem(value: m, child: Text(formatDuration(m)))], onChanged: (v) => set(() => minutes = v ?? 60)),
          const SizedBox(height: 12),
          TextField(controller: reason, maxLines: 3, decoration: const InputDecoration(labelText: 'Reason for the customer', alignLabelWithHint: true)),
          const SizedBox(height: 8),
          const Text('The price is calculated by the system. The customer must approve and pay before anything is charged.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(90, 44)), onPressed: () => Navigator.pop(d, true), child: const Text('Send request'))],
      )),
    );
    final text = reason.text.trim();
    reason.dispose();
    if (ok == true) await run(() async { await ref.read(workerRepoProvider).requestExtraTime(j.id, minutes, text); _refresh(); }, success: 'Request sent to the customer');
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(_jobProvider(widget.jobId));
    return Scaffold(
      appBar: AppBar(title: const Text('Job')),
      body: AsyncBody<WorkerJob>(
        value: job,
        onRetry: _refresh,
        builder: (j) {
          final extras = ref.watch(_jobExtraProvider(widget.jobId)).value ?? const <ExtraTimeRequest>[];
          final action = j.nextAction;
          return ListView(padding: const EdgeInsets.all(20), children: [
            Row(children: [Expanded(child: Text(j.ref, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))), StatusChip(j.status)]),
            Text(DateFormat('EEE d MMM · h:mm a').format(j.start), style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 16),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Customer: ${j.customerFirstName}', style: const TextStyle(fontWeight: FontWeight.w700)),
              if (j.address != null) Text(j.address!) else const Text('Exact address is shared once you are on your way.', style: TextStyle(color: AppColors.muted)),
              if (j.customerPhone != null) Text('Phone: ${j.customerPhone}'),
              if (j.description.isNotEmpty) ...[const SizedBox(height: 8), const Text('Customer notes', style: TextStyle(color: AppColors.muted)), Text(j.description)],
            ]))),
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('You earn'), Text(formatMoney(j.earningMinor, currency: j.currency), style: const TextStyle(fontWeight: FontWeight.w800))]),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Platform commission'), Text(formatMoney(j.commissionMinor, currency: j.currency))]),
            ]))),
            if (extras.isNotEmpty) ...[
              const SectionTitle('Extra-time requests'),
              for (final e in extras) Card(child: ListTile(title: Text('${formatDuration(e.minutes)} · ${formatMoney(e.totalMinor, currency: e.currency)}'), subtitle: Text(e.reason), trailing: StatusChip(e.status))),
            ],
            const SizedBox(height: 20),
            if (action != null) FilledButton(onPressed: busy ? null : () => _advance(j, action.to, action.label), child: Text(action.label)),
            if (j.status == 'assigned') ...[const SizedBox(height: 8), OutlinedButton(onPressed: busy ? null : () => _reject(j), child: const Text('Decline job'))],
            if (j.status == 'in_progress' && !extras.any((e) => e.status == 'pending' || e.status == 'awaiting_payment')) ...[const SizedBox(height: 8), OutlinedButton.icon(onPressed: busy ? null : () => _requestExtra(j), icon: const Icon(Icons.more_time), label: const Text('Request extra time'))],
            if (const {'assigned', 'accepted', 'en_route', 'arrived', 'in_progress'}.contains(j.status)) ...[const SizedBox(height: 8), TextButton.icon(onPressed: () => context.push('/chat/${j.id}'), icon: const Icon(Icons.chat_bubble_outline), label: const Text('Message customer'))],
          ]);
        },
      ),
    );
  }
}

class EarningsScreen extends ConsumerWidget {
  const EarningsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 8), child: Text('Earnings', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
          Expanded(
            child: AsyncBody<List<Earning>>(
              value: ref.watch(earningsProvider),
              onRetry: () => ref.invalidate(earningsProvider),
              builder: (list) {
                int sum(Set<String> st) => list.where((e) => st.contains(e.status)).fold(0, (a, e) => a + e.amountMinor);
                final commission = list.where((e) => e.kind == 'job').fold(0, (a, e) => a + (e.commissionMinor ?? 0));
                return ListView(padding: const EdgeInsets.all(20), children: [
                  Row(children: [Expanded(child: _Kpi('Pending (jobs not yet released)', formatMoney(sum({'pending', 'held'})))), const SizedBox(width: 12), Expanded(child: _Kpi('Ready for payout', formatMoney(sum({'eligible', 'in_payout'}))))]),
                  const SizedBox(height: 12),
                  Row(children: [Expanded(child: _Kpi('Paid out', formatMoney(sum({'paid'})))), const SizedBox(width: 12), Expanded(child: _Kpi('Commission on jobs', formatMoney(commission)))]),
                  const SectionTitle('History'),
                  if (list.isEmpty) const EmptyState(icon: Icons.savings_outlined, title: 'No earnings yet') else for (final e in list) Card(child: ListTile(title: Text(e.bookingRef ?? e.kind.replaceAll('_', ' ')), subtitle: Text(e.kind.replaceAll('_', ' ')), leading: StatusChip(e.status), trailing: Text(formatMoney(e.amountMinor, currency: e.currency), style: TextStyle(fontWeight: FontWeight.w800, color: e.amountMinor < 0 ? AppColors.danger : null)))),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(onPressed: () => ref.read(authRepoProvider).signOut(), icon: const Icon(Icons.logout), label: const Text('Sign out')),
                ]);
              },
            ),
          ),
        ]),
      );
}

// ---------------------------------------------------------------------------------------------------------------
// Onboarding: profile, documents (private storage), skills, areas, availability; then submit for verification.
// ---------------------------------------------------------------------------------------------------------------
final _docsProvider = FutureProvider<List<Json>>((ref) => ref.watch(workerRepoProvider).documents());
final _skillsProvider = FutureProvider<List<Json>>((ref) => ref.watch(workerRepoProvider).mySkills());
final _areaIdsProvider = FutureProvider<Set<String>>((ref) => ref.watch(workerRepoProvider).myAreaIds());
final _servicesProvider = FutureProvider<List<Service>>((ref) => ref.watch(catalogRepoProvider).search());

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingState();
}

class _OnboardingState extends ConsumerState<OnboardingScreen> with BusyMixin {
  final _bio = TextEditingController();
  @override
  void dispose() {
    _bio.dispose();
    super.dispose();
  }

  Future<void> _upload(String type) async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, imageQuality: 85);
    if (x == null) return;
    DateTime? expiry;
    if (!mounted) return;
    if (type != 'other') {
      expiry = await showDatePicker(context: context, helpText: 'Expiry date of this document', initialDate: DateTime.now().add(const Duration(days: 365)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
    }
    await run(() async { await ref.read(workerRepoProvider).uploadDocument(File(x.path), type, expiry); ref.invalidate(_docsProvider); }, success: 'Uploaded to private storage');
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(_docsProvider).value ?? const <Json>[];
    final skills = ref.watch(_skillsProvider).value ?? const <Json>[];
    final services = ref.watch(_servicesProvider).value ?? const <Service>[];
    final areas = ref.watch(areasProvider).value ?? const <ServiceArea>[];
    final areaIds = ref.watch(_areaIdsProvider).value ?? const <String>{};
    final skillIds = skills.map((s) => s['service_id'] as String).toSet();
    return Scaffold(
      appBar: AppBar(title: const Text('Your application')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const SectionTitle('About you'),
        TextField(controller: _bio, maxLines: 3, maxLength: 1000, decoration: const InputDecoration(labelText: 'Short bio', alignLabelWithHint: true)),
        OutlinedButton(onPressed: () => run(() => ref.read(workerRepoProvider).saveProfile(bio: _bio.text.trim()), success: 'Saved'), child: const Text('Save bio')),
        const SectionTitle('Documents'),
        const Text('Identity and qualification documents are stored privately and only reviewed by verification staff.'),
        const SizedBox(height: 8),
        for (final d in docs) Card(child: ListTile(leading: const Icon(Icons.description_outlined), title: Text((d['doc_type'] as String).replaceAll('_', ' ')), subtitle: Text(d['expires_on'] == null ? 'No expiry' : 'Expires ${d['expires_on']}'), trailing: StatusChip(d['status'] as String))),
        Wrap(spacing: 8, children: [for (final t in const ['identity', 'qualification', 'trade_license']) ActionChip(avatar: const Icon(Icons.upload_file, size: 18), label: Text('Upload ${t.replaceAll('_', ' ')}'), onPressed: busy ? null : () => _upload(t))]),
        const SectionTitle('Skills'),
        Wrap(spacing: 8, runSpacing: 4, children: [for (final s in services) FilterChip(label: Text(s.name), selected: skillIds.contains(s.id), onSelected: (v) async { v ? await ref.read(workerRepoProvider).addSkill(s.id) : await ref.read(workerRepoProvider).removeSkill(s.id); ref.invalidate(_skillsProvider); })]),
        const Padding(padding: EdgeInsets.only(top: 6), child: Text('An administrator approves each skill.', style: TextStyle(fontSize: 12, color: AppColors.muted))),
        const SectionTitle('Service areas'),
        Wrap(spacing: 8, runSpacing: 4, children: [for (final a in areas) FilterChip(label: Text(a.label), selected: areaIds.contains(a.id), onSelected: (v) async { final next = {...areaIds}; v ? next.add(a.id) : next.remove(a.id); await ref.read(workerRepoProvider).setAreas(next); ref.invalidate(_areaIdsProvider); })]),
        const SectionTitle('Working hours'),
        OutlinedButton.icon(onPressed: () => context.push('/worker/availability'), icon: const Icon(Icons.schedule), label: const Text('Set weekly availability')),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: busy ? null : () => run(() async { await ref.read(workerRepoProvider).submitApplication(); ref.invalidate(workerProfileProvider); if (!context.mounted) return; context.pop(); }, success: 'Submitted for verification'),
          child: const Text('Submit for verification'),
        ),
      ]),
    );
  }
}

final _availabilityProvider = FutureProvider<List<Json>>((ref) => ref.watch(workerRepoProvider).availability());
final _timeOffProvider = FutureProvider<List<Json>>((ref) => ref.watch(workerRepoProvider).timeOff());

class AvailabilityScreen extends ConsumerStatefulWidget {
  const AvailabilityScreen({super.key});
  @override
  ConsumerState<AvailabilityScreen> createState() => _AvailabilityState();
}

class _AvailabilityState extends ConsumerState<AvailabilityScreen> with BusyMixin {
  // dow (0=Sunday) -> list of (startMinute, endMinute); a gap between two windows is a break.
  Map<int, List<({int start, int end})>>? _windows;
  static const _days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

  String _fmt(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  Future<int?> _pick(int initial) async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60));
    return t == null ? null : t.hour * 60 + t.minute;
  }

  Future<void> _addWindow(int dow) async {
    final s = await _pick(9 * 60);
    if (s == null || !mounted) return;
    final e = await _pick(s + 8 * 60 > 1439 ? 1439 : s + 8 * 60);
    if (e == null) return;
    if (e <= s) {
      if (mounted) showSnack(context, 'End time must be after start time', error: true);
      return;
    }
    final list = [...?_windows![dow], (start: s, end: e)]..sort((a, b) => a.start.compareTo(b.start));
    for (var i = 1; i < list.length; i++) {
      if (list[i].start < list[i - 1].end) {
        if (mounted) showSnack(context, 'Windows cannot overlap', error: true);
        return;
      }
    }
    setState(() => _windows![dow] = list);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_availabilityProvider);
    if (_windows == null && async.hasValue) {
      _windows = {for (var d = 0; d < 7; d++) d: []};
      for (final r in async.value!) { _windows![r['dow'] as int]!.add((start: r['start_minute'] as int, end: r['end_minute'] as int)); }
    }
    final timeOff = ref.watch(_timeOffProvider).value ?? const <Json>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Availability')),
      body: _windows == null
          ? const Padding(padding: EdgeInsets.all(20), child: Skeleton())
          : ListView(padding: const EdgeInsets.all(20), children: [
              const Text('Add working windows for each day. Leave a gap between two windows for a break.'),
              const SizedBox(height: 8),
              for (var d = 0; d < 7; d++)
                Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [Text(_days[d], style: const TextStyle(fontWeight: FontWeight.w800)), const Spacer(), IconButton(tooltip: 'Add window for ${_days[d]}', onPressed: () => _addWindow(d), icon: const Icon(Icons.add_circle_outline))]),
                  if (_windows![d]!.isEmpty) const Text('Day off', style: TextStyle(color: AppColors.muted)),
                  Wrap(spacing: 8, children: [for (final w in _windows![d]!) InputChip(label: Text('${_fmt(w.start)} – ${_fmt(w.end)}'), onDeleted: () => setState(() => _windows![d]!.remove(w)))]),
                ]))),
              FilledButton(onPressed: busy ? null : () => run(() async {
                final flat = [for (final e in _windows!.entries) for (final w in e.value) (dow: e.key, start: w.start, end: w.end)];
                await ref.read(workerRepoProvider).setAvailability(flat);
                ref.invalidate(_availabilityProvider);
              }, success: 'Availability saved'), child: const Text('Save availability')),
              const SectionTitle('Leave & unavailable dates'),
              for (final t in timeOff) Card(child: ListTile(title: Text('${t['during']}'.replaceAll('"', '')), subtitle: Text((t['reason'] ?? '') as String), trailing: IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () async { await ref.read(workerRepoProvider).deleteTimeOff(t['id'] as String); ref.invalidate(_timeOffProvider); }))),
              OutlinedButton.icon(
                icon: const Icon(Icons.beach_access_outlined),
                label: const Text('Add time off'),
                onPressed: () async {
                  final r = await showDateRangePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (r == null) return;
                  await run(() async { await ref.read(workerRepoProvider).addTimeOff(DateTime(r.start.year, r.start.month, r.start.day), DateTime(r.end.year, r.end.month, r.end.day + 1), null); ref.invalidate(_timeOffProvider); });
                },
              ),
            ]),
    );
  }
}
