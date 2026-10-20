import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models.dart';

abstract class AuthRepository {
  String? get userId;
  Stream<bool> authChanges();
  Future<void> signIn(String email, String password);
  Future<void> signUp(String email, String password, String fullName, {required bool asWorker});
  Future<void> signOut();
  Future<void> resetPassword(String email);
  Future<Set<String>> roles();
  Future<Json?> profile();
  Future<void> updateProfile({String? fullName, String? phone});
  Future<void> requestAccountDeletion();
}

abstract class CatalogRepository {
  Future<List<ServiceCategory>> categories();
  Future<List<Service>> search({String? query, String? categoryId, int? maxPriceMinor, String? areaId, DateTime? date, double? minRating});
  Future<Service> service(String id);
  Future<List<ServiceArea>> areas();
  Future<List<Slot>> slots({required String serviceId, required String areaId, required DateTime date, int? durationMinutes});
  Future<PricingQuote> quote({required String serviceId, required DateTime start, int? durationMinutes, String? promoCode});
}

abstract class BookingRepository {
  Future<List<Address>> addresses();
  Future<Address> addAddress({required String label, required String line1, required String city, required String areaId});
  Future<void> deleteAddress(String id);
  Future<({String id, DateTime expiresAt})> reserve({required String serviceId, required String areaId, required DateTime start, int? durationMinutes});
  Future<String> uploadPhoto(File file);
  Future<Booking> createBooking({required String reservationId, required String addressId, required String description, String? promoCode, List<String> photoPaths});
  Future<void> pay(String bookingId, {String? extraRequestId});
  Future<List<Booking>> myBookings();
  Future<Booking> booking(String id);
  Future<List<StatusEvent>> history(String bookingId);
  Future<Json?> workerInfo(String bookingId);
  Future<void> cancel(String id, String? reason);
  Future<void> confirmCompletion(String id);
  Future<void> dispute(String id, String reason);
  Future<void> review(String id, int rating, String comment);
  Future<ExtraTimeRequest?> openExtraTime(String bookingId);
  Future<ExtraTimeRequest> decideExtraTime(String requestId, bool approve);
  Future<List<ChatMessage>> messages(String bookingId);
  Future<void> sendMessage(String bookingId, String body);
  Future<List<AppNotification>> notifications();
  Future<void> markNotificationRead(String id);
  Future<List<SupportTicket>> tickets();
  Future<void> createTicket({required String subject, required String body, String category, String? bookingId});
}

abstract class WorkerRepository {
  Future<Json?> myProfile();
  Future<void> becomeWorker();
  Future<void> saveProfile({String? bio, int? radiusKm});
  Future<void> setAvailable(bool value);
  Future<List<Json>> documents();
  Future<void> uploadDocument(File file, String docType, DateTime? expiresOn);
  Future<List<Json>> mySkills();
  Future<void> addSkill(String serviceId);
  Future<void> removeSkill(String serviceId);
  Future<Set<String>> myAreaIds();
  Future<void> setAreas(Set<String> areaIds);
  Future<List<Json>> availability();
  Future<void> setAvailability(List<({int dow, int start, int end})> windows);
  Future<List<Json>> timeOff();
  Future<void> addTimeOff(DateTime from, DateTime to, String? reason);
  Future<void> deleteTimeOff(String id);
  Future<void> submitApplication();
  Future<List<WorkerJob>> jobs();
  Future<WorkerJob> job(String id);
  Future<void> updateStatus(String bookingId, String to, {String? reason});
  Future<ExtraTimeRequest> requestExtraTime(String bookingId, int minutes, String reason);
  Future<List<ExtraTimeRequest>> extraRequests(String bookingId);
  Future<List<Earning>> earnings();
}

// ---------------------------------------------------------------------------------------------------------------
// Supabase implementations. Every privileged rule (availability, price, state machine) is enforced by the backend.
// ---------------------------------------------------------------------------------------------------------------

SupabaseClient get _db => Supabase.instance.client;
String get _uid => _db.auth.currentUser!.id;
List<Json> _rows(Object? data) => (data as List).cast<Json>();

class SupabaseAuthRepository implements AuthRepository {
  @override
  String? get userId => _db.auth.currentUser?.id;
  @override
  Stream<bool> authChanges() => _db.auth.onAuthStateChange.map((e) => e.session != null);
  @override
  Future<void> signIn(String email, String password) => _db.auth.signInWithPassword(email: email.trim(), password: password);

  @override
  Future<void> signUp(String email, String password, String fullName, {required bool asWorker}) async {
    final res = await _db.auth.signUp(email: email.trim(), password: password, data: {'full_name': fullName.trim()});
    // A worker role is requested via an RPC that creates a *draft* profile; nothing is bookable until an admin approves.
    if (asWorker && res.session != null) await _db.rpc('become_worker');
  }

  @override
  Future<void> signOut() => _db.auth.signOut();
  @override
  Future<void> resetPassword(String email) => _db.auth.resetPasswordForEmail(email.trim());

  @override
  Future<Set<String>> roles() async {
    final rows = _rows(await _db.from('user_roles').select('role').eq('user_id', _uid));
    return rows.map((r) => r['role'] as String).toSet();
  }

  @override
  Future<Json?> profile() => _db.from('profiles').select().eq('id', _uid).maybeSingle();

  @override
  Future<void> updateProfile({String? fullName, String? phone}) async {
    await _db.from('profiles').update({'full_name': ?fullName, if (phone != null) 'phone': phone.isEmpty ? null : phone}).eq('id', _uid);
  }

  @override
  Future<void> requestAccountDeletion() async => _db.rpc('request_account_deletion');
}

class SupabaseCatalogRepository implements CatalogRepository {
  @override
  Future<List<ServiceCategory>> categories() async =>
      _rows(await _db.from('service_categories').select().eq('active', true).order('sort_order')).map(ServiceCategory.fromJson).toList();

  @override
  Future<List<Service>> search({String? query, String? categoryId, int? maxPriceMinor, String? areaId, DateTime? date, double? minRating}) async {
    final data = await _db.rpc('search_services', params: {
      'p_query': query, 'p_category': categoryId, 'p_max_price_minor': maxPriceMinor, 'p_area': areaId,
      'p_date': date?.toIso8601String().substring(0, 10), 'p_min_rating': minRating,
    });
    return _rows(data).map(Service.fromJson).toList();
  }

  @override
  Future<Service> service(String id) async => Service.fromJson(await _db.from('services').select().eq('id', id).single());

  @override
  Future<List<ServiceArea>> areas() async => _rows(await _db.from('service_areas').select().eq('active', true).order('city')).map(ServiceArea.fromJson).toList();

  @override
  Future<List<Slot>> slots({required String serviceId, required String areaId, required DateTime date, int? durationMinutes}) async {
    final data = await _db.rpc('available_slots', params: {
      'p_service_id': serviceId, 'p_area_id': areaId, 'p_date': date.toIso8601String().substring(0, 10), 'p_duration_minutes': durationMinutes,
    });
    return _rows(data).map(Slot.fromJson).toList();
  }

  @override
  Future<PricingQuote> quote({required String serviceId, required DateTime start, int? durationMinutes, String? promoCode}) async {
    final data = await _db.rpc('calculate_pricing', params: {
      'p_service_id': serviceId, 'p_start': start.toUtc().toIso8601String(), 'p_duration_minutes': durationMinutes,
      'p_promo_code': (promoCode ?? '').isEmpty ? null : promoCode,
    });
    return PricingQuote.fromJson(data as Json);
  }
}

class SupabaseBookingRepository implements BookingRepository {
  @override
  Future<List<Address>> addresses() async => _rows(await _db.from('customer_addresses').select().order('created_at')).map(Address.fromJson).toList();

  @override
  Future<Address> addAddress({required String label, required String line1, required String city, required String areaId}) async {
    final existing = await _db.from('customer_addresses').select('id').eq('user_id', _uid).limit(1);
    final row = await _db.from('customer_addresses').insert({
      'user_id': _uid, 'label': label, 'line1': line1, 'city': city, 'area_id': areaId, 'is_default': (existing as List).isEmpty,
    }).select().single();
    return Address.fromJson(row);
  }

  @override
  Future<void> deleteAddress(String id) async => _db.from('customer_addresses').delete().eq('id', id);

  @override
  Future<({String id, DateTime expiresAt})> reserve({required String serviceId, required String areaId, required DateTime start, int? durationMinutes}) async {
    final row = await _db.rpc('reserve_slot', params: {
      'p_service_id': serviceId, 'p_area_id': areaId, 'p_start': start.toUtc().toIso8601String(), 'p_duration_minutes': durationMinutes,
    });
    final j = row as Json;
    return (id: j['id'] as String, expiresAt: DateTime.parse('${j['expires_at']}').toLocal());
  }

  @override
  Future<String> uploadPhoto(File file) async {
    final path = '$_uid/${DateTime.now().microsecondsSinceEpoch}.jpg';
    await _db.storage.from('booking-media').upload(path, file, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    return path;
  }

  @override
  Future<Booking> createBooking({required String reservationId, required String addressId, required String description, String? promoCode, List<String> photoPaths = const []}) async {
    final row = await _db.rpc('create_booking', params: {
      'p_reservation_id': reservationId, 'p_address_id': addressId, 'p_description': description,
      'p_promo_code': (promoCode ?? '').isEmpty ? null : promoCode,
      // A stable key per attempt makes retries after flaky networks safe (no duplicate bookings).
      'p_idempotency_key': 'bk-$reservationId', 'p_attachment_paths': photoPaths,
    });
    return Booking.fromJson({...(row as Json), 'service': {'name': ''}});
  }

  @override
  Future<void> pay(String bookingId, {String? extraRequestId}) async {
    // The Edge Function reads the amount from the database; the app only sends ids and an idempotency key.
    final key = extraRequestId == null ? 'pay-$bookingId' : 'pay-extra-$extraRequestId';
    final res = await _db.functions.invoke('create-payment', body: {'booking_id': bookingId, 'extra_request_id': extraRequestId, 'idempotency_key': key});
    final data = res.data as Json;
    if (data['sandbox'] == true) {
      // SANDBOX ONLY: simulate the customer's payment. Disabled server-side in production configurations.
      await _db.functions.invoke('sandbox-pay', body: {'payment_id': data['payment_id'], 'outcome': 'success'});
    } else {
      throw UnsupportedError('Live card payments require the provider SDK (see docs/PAYMENTS.md).');
    }
  }

  @override
  Future<List<Booking>> myBookings() async =>
      _rows(await _db.from('bookings').select('*, service:services(name)').eq('customer_id', _uid).order('scheduled_start', ascending: false)).map(Booking.fromJson).toList();

  @override
  Future<Booking> booking(String id) async => Booking.fromJson(await _db.from('bookings').select('*, service:services(name)').eq('id', id).single());

  @override
  Future<List<StatusEvent>> history(String bookingId) async =>
      _rows(await _db.from('booking_status_history').select().eq('booking_id', bookingId).order('created_at')).map(StatusEvent.fromJson).toList();

  @override
  Future<Json?> workerInfo(String bookingId) => _db.from('booking_worker_info').select().eq('booking_id', bookingId).maybeSingle();

  @override
  Future<void> cancel(String id, String? reason) async => _db.rpc('cancel_booking', params: {'p_booking_id': id, 'p_reason': reason});
  @override
  Future<void> confirmCompletion(String id) async => _db.rpc('confirm_completion', params: {'p_booking_id': id});
  @override
  Future<void> dispute(String id, String reason) async => _db.rpc('open_dispute', params: {'p_booking_id': id, 'p_reason': reason});
  @override
  Future<void> review(String id, int rating, String comment) async => _db.rpc('submit_review', params: {'p_booking_id': id, 'p_rating': rating, 'p_comment': comment});

  @override
  Future<ExtraTimeRequest?> openExtraTime(String bookingId) async {
    final rows = _rows(await _db.from('extra_time_requests').select().eq('booking_id', bookingId).inFilter('status', ['pending', 'awaiting_payment']).limit(1));
    return rows.isEmpty ? null : ExtraTimeRequest.fromJson(rows.first);
  }

  @override
  Future<ExtraTimeRequest> decideExtraTime(String requestId, bool approve) async =>
      ExtraTimeRequest.fromJson(await _db.rpc('decide_extra_time', params: {'p_request_id': requestId, 'p_approve': approve}) as Json);

  @override
  Future<List<ChatMessage>> messages(String bookingId) async =>
      _rows(await _db.from('booking_messages').select().eq('booking_id', bookingId).order('created_at')).map(ChatMessage.fromJson).toList();
  @override
  Future<void> sendMessage(String bookingId, String body) async => _db.rpc('send_booking_message', params: {'p_booking_id': bookingId, 'p_body': body});

  @override
  Future<List<AppNotification>> notifications() async =>
      _rows(await _db.from('notifications').select().order('created_at', ascending: false).limit(50)).map(AppNotification.fromJson).toList();
  @override
  Future<void> markNotificationRead(String id) async => _db.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id);

  @override
  Future<List<SupportTicket>> tickets() async => _rows(await _db.from('support_tickets').select().order('created_at', ascending: false)).map(SupportTicket.fromJson).toList();

  @override
  Future<void> createTicket({required String subject, required String body, String category = 'general', String? bookingId}) async {
    final t = await _db.from('support_tickets').insert({'user_id': _uid, 'subject': subject, 'category': category, 'booking_id': bookingId}).select('id').single();
    await _db.from('support_messages').insert({'ticket_id': t['id'], 'sender_id': _uid, 'body': body});
  }
}

class SupabaseWorkerRepository implements WorkerRepository {
  @override
  Future<Json?> myProfile() => _db.from('worker_profiles').select().eq('id', _uid).maybeSingle();
  @override
  Future<void> becomeWorker() async => _db.rpc('become_worker');
  @override
  Future<void> saveProfile({String? bio, int? radiusKm}) async =>
      _db.from('worker_profiles').update({'bio': ?bio, 'service_radius_km': ?radiusKm}).eq('id', _uid);
  @override
  Future<void> setAvailable(bool value) async => _db.from('worker_profiles').update({'is_available': value}).eq('id', _uid);

  @override
  Future<List<Json>> documents() async => _rows(await _db.from('worker_documents').select().eq('worker_id', _uid).order('created_at'));

  @override
  Future<void> uploadDocument(File file, String docType, DateTime? expiresOn) async {
    final ext = file.path.toLowerCase().endsWith('.pdf') ? 'pdf' : 'jpg';
    final path = '$_uid/${docType}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage.from('worker-documents').upload(path, file, fileOptions: FileOptions(contentType: ext == 'pdf' ? 'application/pdf' : 'image/jpeg'));
    await _db.from('worker_documents').insert({'worker_id': _uid, 'doc_type': docType, 'storage_path': path, 'expires_on': expiresOn?.toIso8601String().substring(0, 10)});
  }

  @override
  Future<List<Json>> mySkills() async => _rows(await _db.from('worker_skills').select('service_id, approved, service:services(name)').eq('worker_id', _uid));
  @override
  Future<void> addSkill(String serviceId) async => _db.from('worker_skills').upsert({'worker_id': _uid, 'service_id': serviceId}, ignoreDuplicates: true);
  @override
  Future<void> removeSkill(String serviceId) async => _db.from('worker_skills').delete().eq('worker_id', _uid).eq('service_id', serviceId);

  @override
  Future<Set<String>> myAreaIds() async => _rows(await _db.from('worker_service_areas').select('area_id').eq('worker_id', _uid)).map((r) => r['area_id'] as String).toSet();
  @override
  Future<void> setAreas(Set<String> areaIds) async {
    await _db.from('worker_service_areas').delete().eq('worker_id', _uid);
    if (areaIds.isNotEmpty) await _db.from('worker_service_areas').insert(areaIds.map((a) => {'worker_id': _uid, 'area_id': a}).toList());
  }

  @override
  Future<List<Json>> availability() async => _rows(await _db.from('worker_availability').select().eq('worker_id', _uid).order('dow').order('start_minute'));
  @override
  Future<void> setAvailability(List<({int dow, int start, int end})> windows) async {
    await _db.from('worker_availability').delete().eq('worker_id', _uid);
    if (windows.isNotEmpty) {
      await _db.from('worker_availability').insert(windows.map((w) => {'worker_id': _uid, 'dow': w.dow, 'start_minute': w.start, 'end_minute': w.end}).toList());
    }
  }

  @override
  Future<List<Json>> timeOff() async => _rows(await _db.from('worker_time_off').select().eq('worker_id', _uid).order('created_at'));
  @override
  Future<void> addTimeOff(DateTime from, DateTime to, String? reason) async => _db.from('worker_time_off').insert({
        'worker_id': _uid, 'during': '[${from.toUtc().toIso8601String()},${to.toUtc().toIso8601String()})', 'reason': reason});
  @override
  Future<void> deleteTimeOff(String id) async => _db.from('worker_time_off').delete().eq('id', id);

  @override
  Future<void> submitApplication() async => _db.rpc('submit_worker_application');

  @override
  Future<List<WorkerJob>> jobs() async => _rows(await _db.from('worker_jobs').select().order('scheduled_start')).map(WorkerJob.fromJson).toList();
  @override
  Future<WorkerJob> job(String id) async => WorkerJob.fromJson(await _db.from('worker_jobs').select().eq('id', id).single());
  @override
  Future<void> updateStatus(String bookingId, String to, {String? reason}) async =>
      _db.rpc('worker_update_job_status', params: {'p_booking_id': bookingId, 'p_to': to, 'p_reason': reason});

  @override
  Future<ExtraTimeRequest> requestExtraTime(String bookingId, int minutes, String reason) async =>
      ExtraTimeRequest.fromJson(await _db.rpc('request_extra_time', params: {'p_booking_id': bookingId, 'p_minutes': minutes, 'p_reason': reason}) as Json);
  @override
  Future<List<ExtraTimeRequest>> extraRequests(String bookingId) async =>
      _rows(await _db.from('extra_time_requests').select().eq('booking_id', bookingId).order('created_at', ascending: false)).map(ExtraTimeRequest.fromJson).toList();

  @override
  Future<List<Earning>> earnings() async => _rows(await _db.from('worker_earnings_detail').select().order('created_at', ascending: false).limit(100)).map(Earning.fromJson).toList();
}
