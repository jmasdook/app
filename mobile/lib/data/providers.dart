import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models.dart';
import 'repositories.dart';

// Repositories are overridable in tests (widget tests use in-memory fakes, never fake "live" data).
final authRepoProvider = Provider<AuthRepository>((ref) => SupabaseAuthRepository());
final catalogRepoProvider = Provider<CatalogRepository>((ref) => SupabaseCatalogRepository());
final bookingRepoProvider = Provider<BookingRepository>((ref) => SupabaseBookingRepository());
final workerRepoProvider = Provider<WorkerRepository>((ref) => SupabaseWorkerRepository());

final signedInProvider = StreamProvider<bool>((ref) async* {
  final repo = ref.watch(authRepoProvider);
  yield repo.userId != null;
  yield* repo.authChanges();
});

final rolesProvider = FutureProvider<Set<String>>((ref) async {
  final signedIn = ref.watch(signedInProvider).value ?? false;
  if (!signedIn) return <String>{};
  return ref.watch(authRepoProvider).roles();
});

final profileProvider = FutureProvider<Json?>((ref) async {
  ref.watch(signedInProvider);
  return ref.watch(authRepoProvider).profile();
});

final categoriesProvider = FutureProvider<List<ServiceCategory>>((ref) => ref.watch(catalogRepoProvider).categories());
final areasProvider = FutureProvider<List<ServiceArea>>((ref) => ref.watch(catalogRepoProvider).areas());
final popularServicesProvider = FutureProvider<List<Service>>((ref) async =>
    (await ref.watch(catalogRepoProvider).search()).where((s) => s.popular).toList());
final myBookingsProvider = FutureProvider<List<Booking>>((ref) => ref.watch(bookingRepoProvider).myBookings());
final addressesProvider = FutureProvider<List<Address>>((ref) => ref.watch(bookingRepoProvider).addresses());
final notificationsProvider = FutureProvider<List<AppNotification>>((ref) => ref.watch(bookingRepoProvider).notifications());
final workerJobsProvider = FutureProvider<List<WorkerJob>>((ref) => ref.watch(workerRepoProvider).jobs());
final workerProfileProvider = FutureProvider<Json?>((ref) => ref.watch(workerRepoProvider).myProfile());
final earningsProvider = FutureProvider<List<Earning>>((ref) => ref.watch(workerRepoProvider).earnings());

/// Which experience to show for users that hold both roles; defaults to worker only if the account is a worker.
class WorkerModeNotifier extends Notifier<bool?> {
  @override
  bool? build() => null;
  void set(bool v) => state = v;
}

final workerModeProvider = NotifierProvider<WorkerModeNotifier, bool?>(WorkerModeNotifier.new);
