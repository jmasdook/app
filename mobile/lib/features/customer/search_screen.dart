import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../common/widgets.dart';
import 'home_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.categoryId});
  final String? categoryId;
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _q = TextEditingController();
  String? _category, _area;
  double? _maxPrice;
  DateTime? _date;
  bool _highRating = false;
  Future<List<Service>>? _future;

  @override
  void initState() {
    super.initState();
    _category = widget.categoryId;
    _run();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _run() => setState(() => _future = ref.read(catalogRepoProvider).search(
        query: _q.text.trim(), categoryId: _category, maxPriceMinor: _maxPrice == null ? null : (_maxPrice! * 100).round(),
        areaId: _area, date: _date, minRating: _highRating ? 4 : null));

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(categoriesProvider).value ?? const <ServiceCategory>[];
    final areas = ref.watch(areasProvider).value ?? const <ServiceArea>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Find a service')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(controller: _q, decoration: InputDecoration(hintText: 'Search e.g. plumber', prefixIcon: const Icon(Icons.search), suffixIcon: IconButton(tooltip: 'Search', icon: const Icon(Icons.arrow_forward), onPressed: _run)), textInputAction: TextInputAction.search, onSubmitted: (_) => _run()),
        ),
        SizedBox(
          height: 56,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            for (final c in cats) Padding(padding: const EdgeInsets.only(right: 8, top: 10, bottom: 10), child: FilterChip(label: Text(c.name), selected: _category == c.id, onSelected: (v) { _category = v ? c.id : null; _run(); })),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<String?>(
              value: _area, hint: const Text('Area'), underline: const SizedBox.shrink(),
              items: [const DropdownMenuItem(value: null, child: Text('Any area')), for (final a in areas) DropdownMenuItem(value: a.id, child: Text(a.label))],
              onChanged: (v) { _area = v; _run(); },
            ),
            ActionChip(
              avatar: const Icon(Icons.event, size: 18),
              label: Text(_date == null ? 'Any date' : '${_date!.day}/${_date!.month}'),
              onPressed: () async {
                final d = await showDatePicker(context: context, initialDate: DateTime.now().add(const Duration(days: 1)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 60)));
                if (d != null) { _date = d; _run(); }
              },
            ),
            FilterChip(label: const Text('4★ & up'), selected: _highRating, onSelected: (v) { _highRating = v; _run(); }),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Text(_maxPrice == null ? 'Any price' : 'Up to ${formatMoney((_maxPrice! * 100).round())}', style: const TextStyle(fontSize: 13)),
            Expanded(child: Slider(value: _maxPrice ?? 500, min: 50, max: 500, divisions: 9, onChanged: (v) => setState(() => _maxPrice = v), onChangeEnd: (_) => _run())),
            if (_maxPrice != null) TextButton(onPressed: () { _maxPrice = null; _run(); }, child: const Text('Clear')),
          ]),
        ),
        if (_area != null && _date != null) const Padding(padding: EdgeInsets.symmetric(horizontal: 20), child: Align(alignment: Alignment.centerLeft, child: Text('Showing services with open slots on that date', style: TextStyle(fontSize: 12)))),
        Expanded(
          child: FutureBuilder<List<Service>>(
            future: _future,
            builder: (c, snap) {
              if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(20), child: Skeleton());
              if (snap.hasError) return ErrorState(error: snap.error!, onRetry: _run);
              final list = snap.data!;
              if (list.isEmpty) return const EmptyState(icon: Icons.search_off, title: 'No services match', message: 'Try removing a filter.');
              return ListView.separated(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), itemCount: list.length, separatorBuilder: (_, _) => const SizedBox(height: 12), itemBuilder: (c, i) => ServiceTile(list[i]));
            },
          ),
        ),
      ]),
    );
  }
}
