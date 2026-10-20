import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../common/widgets.dart';
import 'home_screen.dart';

final serviceProvider = FutureProvider.family<Service, String>((ref, id) => ref.watch(catalogRepoProvider).service(id));

String policyText(({int hours, int bps}) t, {required bool last}) =>
    t.bps == 10000 ? 'Free cancellation up to ${t.hours} hours before' : t.bps == 0 ? 'No refund within ${last ? 'the last' : ''} ${t.hours == 0 ? 'moments' : '${t.hours} hours'}' : '${t.bps ~/ 100}% refund up to ${t.hours} hours before';

class ServiceDetailScreen extends ConsumerWidget {
  const ServiceDetailScreen({super.key, required this.serviceId});
  final String serviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(serviceProvider(serviceId));
    return Scaffold(
      appBar: AppBar(),
      body: AsyncBody<Service>(
        value: async,
        onRetry: () => ref.invalidate(serviceProvider(serviceId)),
        builder: (s) => Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
              NetImage(s.imageUrl, height: 200, radius: 20),
              const SizedBox(height: 16),
              Text(s.name, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(s.description),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    _row('Price (${s.priceLabel})', formatMoney(s.basePriceMinor, currency: s.currency)),
                    _row(s.isHourly ? 'Minimum duration' : 'Included duration', formatDuration(s.includedMinutes)),
                    if (s.pricingModel == 'base_plus_extra') _row('Additional hour', formatMoney(s.extraHourRateMinor, currency: s.currency)),
                    const Divider(),
                    const Align(alignment: Alignment.centerLeft, child: Text('Prices exclude VAT; the exact total is shown before you pay.', style: TextStyle(fontSize: 12, color: AppColors.muted))),
                  ]),
                ),
              ),
              if (s.included.isNotEmpty) ...[const SectionTitle("What's included"), for (final i in s.included) _bullet(Icons.check_circle, AppColors.ok, i)],
              if (s.excluded.isNotEmpty) ...[const SectionTitle('Not included'), for (final i in s.excluded) _bullet(Icons.remove_circle_outline, AppColors.muted, i)],
              if (s.cancellationPolicy.isNotEmpty) ...[
                const SectionTitle('Cancellation policy'),
                for (var i = 0; i < s.cancellationPolicy.length; i++) _bullet(Icons.event_busy, AppColors.muted, policyText(s.cancellationPolicy[i], last: i == s.cancellationPolicy.length - 1)),
              ],
            ]),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton(onPressed: () => context.push('/book/${s.id}'), child: Text('Book · from ${formatMoney(s.basePriceMinor, currency: s.currency)}')),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _row(String l, String v) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l), Text(v, style: const TextStyle(fontWeight: FontWeight.w700))]));
  Widget _bullet(IconData i, Color c, String t) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(i, size: 20, color: c), const SizedBox(width: 10), Expanded(child: Text(t))]));
}
