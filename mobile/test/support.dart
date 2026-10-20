import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skillconnect/core/theme.dart';
import 'package:skillconnect/data/models.dart';
import 'package:skillconnect/data/providers.dart';
import 'package:skillconnect/data/repositories.dart';

/// In-memory test doubles. They record calls so tests can assert what the UI asked the backend to do.
class FakeAuth extends Fake implements AuthRepository {
  final calls = <String>[];
  @override
  String? get userId => 'u1';
  @override
  Stream<bool> authChanges() => const Stream.empty();
  @override
  Future<void> signIn(String email, String password) async => calls.add('signIn:$email');
  @override
  Future<Json?> profile() async => {'full_name': 'Amina Test', 'phone': null};
  @override
  Future<Set<String>> roles() async => {'customer'};
}

class FakeBookings extends Fake implements BookingRepository {
  final calls = <String>[];
  @override
  Future<ExtraTimeRequest> decideExtraTime(String requestId, bool approve) async {
    calls.add('decide:$requestId:$approve');
    return sampleExtra(status: approve ? 'awaiting_payment' : 'rejected');
  }

  @override
  Future<void> pay(String bookingId, {String? extraRequestId}) async => calls.add('pay:$bookingId:$extraRequestId');
  @override
  Future<List<Booking>> myBookings() async => [];
  @override
  Future<List<Address>> addresses() async => [];
  @override
  Future<List<AppNotification>> notifications() async => [];
  @override
  Future<String> uploadPhoto(File file) async => 'x';
}

class FakeWorker extends Fake implements WorkerRepository {
  final calls = <String>[];
  WorkerJob current = sampleJob('assigned');
  @override
  @override
  @override
  Future<void> updateStatus(String bookingId, String to, {String? reason}) async {
    calls.add('status:$to');
    current = sampleJob(to);
  }

  @override
  Future<WorkerJob> job(String id) async => current;
  @override
  Future<List<ExtraTimeRequest>> extraRequests(String bookingId) async => [];
  @override
  Future<List<WorkerJob>> jobs() async => [current];
  @override
  Future<Json?> myProfile() async => {'status': 'approved', 'is_available': true};
  @override
  Future<List<Earning>> earnings() async => [];
}

class FakeCatalog extends Fake implements CatalogRepository {
  @override
  Future<List<ServiceCategory>> categories() async => const [ServiceCategory(id: 'c1', name: 'Plumbing', description: '')];
  @override
  Future<List<Service>> search({String? query, String? categoryId, int? maxPriceMinor, String? areaId, DateTime? date, double? minRating}) async => const [
        Service(id: 's1', name: 'Plumber visit', description: 'd', pricingModel: 'base_plus_extra', basePriceMinor: 12000, currency: 'AED', includedMinutes: 60, popular: true),
      ];
  @override
  Future<List<ServiceArea>> areas() async => const [];
}

ExtraTimeRequest sampleExtra({String status = 'pending'}) => ExtraTimeRequest(
    id: 'r1', bookingId: 'b1', minutes: 60, reason: 'Found a second leak', status: status, rateMinor: 6000, netMinor: 6000, taxMinor: 300, totalMinor: 6300, currency: 'AED', expiresAt: DateTime.now().add(const Duration(minutes: 10)));

WorkerJob sampleJob(String status) => WorkerJob(
    id: 'b1', ref: 'SC-000001', status: status, start: DateTime(2030, 1, 1, 10), end: DateTime(2030, 1, 1, 12), serviceId: 's1', earningMinor: 12750, commissionMinor: 2250, currency: 'AED', customerFirstName: 'Sara');

Widget wrap(Widget child, List<Override> overrides) => ProviderScope(overrides: overrides, child: MaterialApp(theme: buildTheme(), home: child));

/// Pushes [screen] on top of a home page so screens that call context.pop() behave as in the app.
Widget wrapRouted(Widget screen, List<Override> overrides) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (c, s) => Scaffold(body: Center(child: TextButton(onPressed: () => c.push('/screen'), child: const Text('open'))))),
    GoRoute(path: '/screen', builder: (c, s) => screen),
  ]);
  return ProviderScope(overrides: overrides, child: MaterialApp.router(theme: buildTheme(), routerConfig: router));
}

List<Override> baseOverrides({FakeAuth? auth, FakeBookings? bookings, FakeWorker? worker, FakeCatalog? catalog}) => [
      authRepoProvider.overrideWithValue(auth ?? FakeAuth()),
      bookingRepoProvider.overrideWithValue(bookings ?? FakeBookings()),
      workerRepoProvider.overrideWithValue(worker ?? FakeWorker()),
      catalogRepoProvider.overrideWithValue(catalog ?? FakeCatalog()),
    ];
