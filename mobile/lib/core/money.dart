/// Money is always an integer number of minor units (fils). No floating point is used for amounts.
String formatMoney(int? minor, {String currency = 'AED'}) {
  if (minor == null) return '-';
  final negative = minor < 0;
  final abs = minor.abs();
  final whole = (abs ~/ 100).toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  final frac = (abs % 100).toString().padLeft(2, '0');
  return '$currency ${negative ? '-' : ''}$whole.$frac';
}

String formatDuration(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}
