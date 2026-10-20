typedef Json = Map<String, dynamic>;

int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
DateTime _dt(Object? v) => DateTime.parse('$v').toLocal();

class ServiceCategory {
  const ServiceCategory({required this.id, required this.name, required this.description, this.imageUrl});
  factory ServiceCategory.fromJson(Json j) => ServiceCategory(
      id: j['id'] as String, name: j['name'] as String, description: (j['description'] ?? '') as String, imageUrl: j['image_url'] as String?);
  final String id, name, description;
  final String? imageUrl;
}

class Service {
  const Service({
    required this.id, required this.name, required this.description, required this.pricingModel, required this.basePriceMinor,
    required this.currency, required this.includedMinutes, this.imageUrl, this.categoryId, this.included = const [],
    this.excluded = const [], this.extraHourRateMinor = 0, this.cancellationPolicy = const [], this.popular = false,
    this.ratingAvg, this.available, this.maxDurationMinutes = 480,
  });
  factory Service.fromJson(Json j) => Service(
        id: j['id'] as String,
        name: j['name'] as String,
        description: (j['description'] ?? '') as String,
        pricingModel: j['pricing_model'] as String,
        basePriceMinor: _int(j['base_price_minor']),
        currency: (j['currency'] ?? 'AED') as String,
        includedMinutes: _int(j['included_minutes']),
        imageUrl: j['image_url'] as String?,
        categoryId: j['category_id'] as String?,
        included: ((j['included'] ?? const []) as List).cast<String>(),
        excluded: ((j['excluded'] ?? const []) as List).cast<String>(),
        extraHourRateMinor: _int(j['extra_hour_rate_minor']),
        cancellationPolicy: ((j['cancellation_policy'] ?? const []) as List).map((e) => (hours: _int(e['hours_before']), bps: _int(e['refund_bps']))).toList(),
        popular: (j['popular'] ?? false) as bool,
        ratingAvg: j['rating_avg'] == null ? null : double.tryParse('${j['rating_avg']}'),
        available: j['available'] as bool?,
        maxDurationMinutes: j['max_duration_minutes'] == null ? 480 : _int(j['max_duration_minutes']),
      );
  final String id, name, description, pricingModel, currency;
  final int basePriceMinor, includedMinutes, extraHourRateMinor, maxDurationMinutes;
  final String? imageUrl, categoryId;
  final List<String> included, excluded;
  final List<({int hours, int bps})> cancellationPolicy;
  final bool popular;
  final double? ratingAvg;
  final bool? available;

  bool get isHourly => pricingModel == 'hourly';
  String get priceLabel => isHourly ? 'per hour' : (pricingModel == 'base_plus_extra' ? 'starting price' : 'fixed price');
}

class ServiceArea {
  const ServiceArea({required this.id, required this.city, required this.name});
  factory ServiceArea.fromJson(Json j) => ServiceArea(id: j['id'] as String, city: j['city'] as String, name: j['name'] as String);
  final String id, city, name;
  String get label => '$name, $city';
}

class Address {
  const Address({required this.id, required this.label, required this.line1, required this.city, required this.areaId, this.isDefault = false});
  factory Address.fromJson(Json j) => Address(id: j['id'] as String, label: (j['label'] ?? '') as String, line1: j['line1'] as String,
      city: j['city'] as String, areaId: j['area_id'] as String, isDefault: (j['is_default'] ?? false) as bool);
  final String id, label, line1, city, areaId;
  final bool isDefault;
}

class Slot {
  const Slot({required this.workerId, required this.start, required this.end});
  factory Slot.fromJson(Json j) => Slot(workerId: j['worker_id'] as String, start: _dt(j['slot_start']), end: _dt(j['slot_end']));
  final String workerId;
  final DateTime start, end;
}

class PriceLine {
  const PriceLine(this.type, this.label, this.amountMinor);
  final String type, label;
  final int amountMinor;
}

class PricingQuote {
  const PricingQuote({required this.currency, required this.totalMinor, required this.lines, required this.durationMinutes});
  factory PricingQuote.fromJson(Json j) => PricingQuote(
        currency: j['currency'] as String,
        totalMinor: _int(j['total_minor']),
        durationMinutes: _int(j['duration_minutes']),
        lines: ((j['lines'] ?? const []) as List).map((l) => PriceLine(l['type'] as String, l['label'] as String, _int(l['amount_minor']))).toList(),
      );
  final String currency;
  final int totalMinor, durationMinutes;
  final List<PriceLine> lines;
}

class Booking {
  const Booking({
    required this.id, required this.ref, required this.status, required this.start, required this.end, required this.currency,
    required this.totalMinor, required this.serviceName, this.workerId, this.extraMinutes = 0, this.addressLine,
  });
  factory Booking.fromJson(Json j) => Booking(
        id: j['id'] as String,
        ref: j['ref'] as String,
        status: j['status'] as String,
        start: _dt(j['scheduled_start']),
        end: _dt(j['scheduled_end']),
        currency: (j['currency'] ?? 'AED') as String,
        totalMinor: _int(j['total_minor']),
        serviceName: ((j['service'] as Map?)?['name'] ?? 'Service') as String,
        workerId: j['worker_id'] as String?,
        extraMinutes: _int(j['extra_minutes']),
        addressLine: (j['address_snapshot'] as Map?)?['line1'] as String?,
      );
  final String id, ref, status, currency, serviceName;
  final DateTime start, end;
  final int totalMinor, extraMinutes;
  final String? workerId, addressLine;

  bool get isUpcoming => const {'pending_payment', 'assigned', 'accepted', 'unassigned'}.contains(status);
  bool get isActive => const {'en_route', 'arrived', 'in_progress', 'awaiting_confirmation'}.contains(status);
  bool get canCancel => isUpcoming;
}

class WorkerJob {
  const WorkerJob({
    required this.id, required this.ref, required this.status, required this.start, required this.end, required this.serviceId,
    required this.earningMinor, required this.commissionMinor, required this.currency, required this.customerFirstName,
    this.description = '', this.address, this.customerPhone, this.extraMinutes = 0,
  });
  factory WorkerJob.fromJson(Json j) => WorkerJob(
        id: j['id'] as String, ref: j['ref'] as String, status: j['status'] as String, start: _dt(j['scheduled_start']), end: _dt(j['scheduled_end']),
        serviceId: j['service_id'] as String, earningMinor: _int(j['worker_earning_minor']), commissionMinor: _int(j['commission_minor']),
        currency: (j['currency'] ?? 'AED') as String, customerFirstName: (j['customer_first_name'] ?? '') as String,
        description: (j['description'] ?? '') as String, address: (j['address'] as Map?)?['line1'] as String?, customerPhone: j['customer_phone'] as String?,
        extraMinutes: _int(j['extra_minutes']),
      );
  final String id, ref, status, serviceId, currency, customerFirstName, description;
  final DateTime start, end;
  final int earningMinor, commissionMinor, extraMinutes;
  final String? address, customerPhone;

  /// The next action a worker may take, or null when none (the server validates every transition).
  ({String to, String label})? get nextAction => switch (status) {
        'assigned' => (to: 'accepted', label: 'Accept job'),
        'accepted' => (to: 'en_route', label: "I'm on my way"),
        'en_route' => (to: 'arrived', label: "I've arrived"),
        'arrived' => (to: 'in_progress', label: 'Start job'),
        'in_progress' => (to: 'awaiting_confirmation', label: 'Mark work done'),
        _ => null,
      };
}

class ExtraTimeRequest {
  const ExtraTimeRequest({
    required this.id, required this.bookingId, required this.minutes, required this.reason, required this.status,
    required this.rateMinor, required this.netMinor, required this.taxMinor, required this.totalMinor, required this.currency, required this.expiresAt,
  });
  factory ExtraTimeRequest.fromJson(Json j) => ExtraTimeRequest(
        id: j['id'] as String, bookingId: j['booking_id'] as String, minutes: _int(j['requested_minutes']), reason: j['reason'] as String,
        status: j['status'] as String, rateMinor: _int(j['rate_minor']), netMinor: _int(j['net_minor']), taxMinor: _int(j['tax_minor']),
        totalMinor: _int(j['total_minor']), currency: j['currency'] as String, expiresAt: _dt(j['expires_at']),
      );
  final String id, bookingId, reason, status, currency;
  final int minutes, rateMinor, netMinor, taxMinor, totalMinor;
  final DateTime expiresAt;
}

class AppNotification {
  const AppNotification({required this.id, required this.title, required this.body, required this.createdAt, required this.read, this.data = const {}});
  factory AppNotification.fromJson(Json j) => AppNotification(id: j['id'] as String, title: j['title'] as String, body: j['body'] as String,
      createdAt: _dt(j['created_at']), read: j['read_at'] != null, data: (j['data'] ?? const {}) as Json);
  final String id, title, body;
  final DateTime createdAt;
  final bool read;
  final Json data;
}

class Earning {
  const Earning({required this.id, required this.kind, required this.status, required this.amountMinor, required this.currency, this.bookingRef, this.commissionMinor});
  factory Earning.fromJson(Json j) => Earning(id: j['id'] as String, kind: j['kind'] as String, status: j['status'] as String, amountMinor: _int(j['amount_minor']),
      currency: j['currency'] as String, bookingRef: j['booking_ref'] as String?, commissionMinor: j['commission_minor'] == null ? null : _int(j['commission_minor']));
  final String id, kind, status, currency;
  final int amountMinor;
  final String? bookingRef;
  final int? commissionMinor;
}

class SupportTicket {
  const SupportTicket({required this.id, required this.subject, required this.status, required this.createdAt});
  factory SupportTicket.fromJson(Json j) => SupportTicket(id: j['id'] as String, subject: j['subject'] as String, status: j['status'] as String, createdAt: _dt(j['created_at']));
  final String id, subject, status;
  final DateTime createdAt;
}

class StatusEvent {
  const StatusEvent({required this.status, required this.at, this.reason});
  factory StatusEvent.fromJson(Json j) => StatusEvent(status: j['to_status'] as String, at: _dt(j['created_at']), reason: j['reason'] as String?);
  final String status;
  final DateTime at;
  final String? reason;
}

class ChatMessage {
  const ChatMessage({required this.id, required this.senderId, required this.body, required this.at});
  factory ChatMessage.fromJson(Json j) => ChatMessage(id: j['id'] as String, senderId: j['sender_id'] as String, body: j['body'] as String, at: _dt(j['created_at']));
  final String id, senderId, body;
  final DateTime at;
}

/// Human-friendly message for the RPC error codes raised by the database.
String friendlyError(Object e) {
  final raw = e.toString();
  const map = {
    'slot_unavailable': 'That time was just taken. Please choose another slot.',
    'reservation_expired': 'Your held slot expired. Please pick a time again.',
    'too_many_reservations': 'You have too many held slots. Finish or wait for them to expire.',
    'payment_window_closed': 'The payment window has closed. Please book again.',
    'invalid_transition': 'That action is not available for this booking right now.',
    'extension_limit_exceeded': 'That exceeds the maximum extra time for this service.',
    'extension_conflicts_with_next_booking': 'The extension would overlap your next job. Contact support.',
    'extra_time_request_already_open': 'There is already an open extra-time request for this job.',
    'promo_not_applicable': 'That promo code cannot be applied.',
    'not_authenticated': 'Please sign in again.',
    'documents_missing': 'Upload all required documents before submitting.',
    'skills_missing': 'Add at least one skill before submitting.',
    'areas_missing': 'Add at least one service area before submitting.',
  };
  for (final entry in map.entries) {
    if (raw.contains(entry.key)) return entry.value;
  }
  if (raw.contains('SocketException') || raw.contains('ClientException') || raw.contains('Failed host lookup')) {
    return 'No connection. Check your internet and try again.';
  }
  if (raw.contains('Invalid login')) return 'Incorrect email or password.';
  if (raw.contains('permission denied') || raw.contains('42501')) return 'You are not allowed to do that.';
  return 'Something went wrong. Please try again.';
}
