import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../common/widgets.dart';

class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.height = 120, this.width, this.radius = 16});
  final String? url;
  final double height;
  final double? width;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final ph = Container(height: height, width: width, decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(radius)), child: const Icon(Icons.handyman_rounded, color: AppColors.accent));
    if (url == null) return ph;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      // cacheWidth keeps decoded bitmaps small (memory / jank) regardless of the source resolution.
      child: Image.network(url!, height: height, width: width, fit: BoxFit.cover, cacheWidth: 600, errorBuilder: (_, _, _) => ph, loadingBuilder: (c, child, p) => p == null ? child : ph),
    );
  }
}

class ServiceTile extends StatelessWidget {
  const ServiceTile(this.service, {super.key});
  final Service service;
  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/service/${service.id}'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              NetImage(service.imageUrl, height: 76, width: 76, radius: 14),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(service.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text('${formatDuration(service.includedMinutes)} · ${service.priceLabel}', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text(formatMoney(service.basePriceMinor, currency: service.currency), style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.accent)),
                    if ((service.ratingAvg ?? 0) > 0) ...[const SizedBox(width: 10), const Icon(Icons.star_rounded, size: 16, color: Color(0xFFF2B01E)), Text(service.ratingAvg!.toStringAsFixed(1))],
                  ]),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        ),
      );
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final name = ((profile?['full_name'] ?? '') as String).split(' ').first;
    final addresses = ref.watch(addressesProvider).value ?? const <Address>[];
    final areas = ref.watch(areasProvider).value ?? const <ServiceArea>[];
    final defaultAddress = addresses.where((a) => a.isDefault).firstOrNull ?? addresses.firstOrNull;
    final areaName = areas.where((a) => a.id == defaultAddress?.areaId).firstOrNull?.label;
    final bookings = ref.watch(myBookingsProvider);
    final next = bookings.value?.where((b) => b.isUpcoming || b.isActive).where((b) => b.status != 'pending_payment').toList()?..sort((a, b) => a.start.compareTo(b.start));

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myBookingsProvider);
          ref.invalidate(popularServicesProvider);
          ref.invalidate(categoriesProvider);
        },
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), children: [
          Text(name.isEmpty ? 'Hello' : 'Hello, $name', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Row(children: [const Icon(Icons.place_outlined, size: 16, color: AppColors.muted), const SizedBox(width: 4), Expanded(child: Text(areaName ?? 'Add an address in Account', overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.muted)))]),
          const SizedBox(height: 16),
          Semantics(
            button: true,
            label: 'Search services',
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => context.push('/search'),
              child: Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
                child: const Row(children: [Icon(Icons.search), SizedBox(width: 10), Text('What do you need help with?', style: TextStyle(color: AppColors.muted))]),
              ),
            ),
          ),
          if (next != null && next.isNotEmpty) ...[
            const SectionTitle('Your next appointment'),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                title: Text(next.first.serviceName.isEmpty ? next.first.ref : next.first.serviceName, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(DateFormat('EEE d MMM · h:mm a').format(next.first.start)),
                trailing: StatusChip(next.first.status),
                onTap: () => context.push('/booking/${next.first.id}'),
              ),
            ),
          ],
          const SectionTitle('Services'),
          AsyncBody<List<ServiceCategory>>(
            value: ref.watch(categoriesProvider),
            onRetry: () => ref.invalidate(categoriesProvider),
            skeleton: const Skeleton(height: 120, count: 1),
            builder: (cats) => SizedBox(
              height: 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: cats.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (c, i) => SizedBox(
                  width: 150,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => context.push('/search?category=${cats[i].id}'),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      NetImage(cats[i].imageUrl, height: 100, width: 150),
                      const SizedBox(height: 6),
                      Text(cats[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          const SectionTitle('Popular right now'),
          AsyncBody<List<Service>>(
            value: ref.watch(popularServicesProvider),
            onRetry: () => ref.invalidate(popularServicesProvider),
            builder: (list) => list.isEmpty
                ? const EmptyState(icon: Icons.construction, title: 'No services yet', message: 'Services will appear here once they are published.')
                : Column(children: [for (final s in list) Padding(padding: const EdgeInsets.only(bottom: 12), child: ServiceTile(s))]),
          ),
          const SectionTitle('Shortcuts'),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: () => context.go('/bookings'), icon: const Icon(Icons.history), label: const Text('Booking history'))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton.icon(onPressed: () => context.push('/support'), icon: const Icon(Icons.support_agent), label: const Text('Support'))),
          ]),
        ]),
      ),
    );
  }
}
