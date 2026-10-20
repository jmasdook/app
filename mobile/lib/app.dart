import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/env.dart';
import 'core/theme.dart';
import 'data/models.dart';
import 'data/providers.dart';
import 'features/auth/auth_screens.dart';
import 'features/common/widgets.dart';
import 'features/customer/account_screens.dart';
import 'features/customer/booking_wizard.dart';
import 'features/customer/bookings_screens.dart';
import 'features/customer/home_screen.dart';
import 'features/customer/search_screen.dart';
import 'features/customer/service_detail_screen.dart';
import 'features/worker/worker_screens.dart';

const _authPaths = {'/login', '/register', '/forgot'};

/// True when the signed-in account should see the professional experience.
bool isWorkerExperience(Set<String> roles, bool? override) => roles.contains('worker') && (override ?? true);

class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(signedInProvider, (_, _) => notifyListeners());
    ref.listen(rolesProvider, (_, _) => notifyListeners());
    ref.listen(workerModeProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final signedIn = ref.read(signedInProvider).value ?? false;
      final loc = state.matchedLocation;
      if (!signedIn) return _authPaths.contains(loc) ? null : '/login';
      final rolesAsync = ref.read(rolesProvider);
      if (!rolesAsync.hasValue) return loc == '/splash' ? null : '/splash';
      final worker = isWorkerExperience(rolesAsync.value!, ref.read(workerModeProvider));
      if (_authPaths.contains(loc) || loc == '/splash' || loc == '/') return worker ? '/worker' : '/home';
      if (!worker && loc.startsWith('/worker') && !loc.startsWith('/worker/onboarding')) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (c, s) => const SizedBox.shrink()),
      GoRoute(path: '/splash', builder: (c, s) => const Scaffold(body: Center(child: CircularProgressIndicator()))),
      GoRoute(path: '/login', builder: (c, s) => const LoginScreen()),
      GoRoute(path: '/register', builder: (c, s) => const RegisterScreen()),
      GoRoute(path: '/forgot', builder: (c, s) => const ForgotPasswordScreen()),
      StatefulShellRoute.indexedStack(
        builder: (c, s, shell) => _Shell(shell, customer: true),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (c, s) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/bookings', builder: (c, s) => const BookingsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/notifications', builder: (c, s) => const NotificationsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/account', builder: (c, s) => const AccountScreen())]),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (c, s, shell) => _Shell(shell, customer: false),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/worker', builder: (c, s) => const WorkerHomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/worker/jobs', builder: (c, s) => const JobsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/worker/alerts', builder: (c, s) => const NotificationsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/worker/earnings', builder: (c, s) => const EarningsScreen())]),
        ],
      ),
      GoRoute(path: '/search', builder: (c, s) => SearchScreen(categoryId: s.uri.queryParameters['category'])),
      GoRoute(path: '/service/:id', builder: (c, s) => ServiceDetailScreen(serviceId: s.pathParameters['id']!)),
      GoRoute(path: '/book/:id', builder: (c, s) => BookingWizard(serviceId: s.pathParameters['id']!)),
      GoRoute(path: '/booking/:id', builder: (c, s) => BookingDetailScreen(bookingId: s.pathParameters['id']!)),
      GoRoute(
        path: '/extra/:id',
        builder: (c, s) => s.extra is ExtraTimeRequest ? ExtraTimeScreen(request: s.extra! as ExtraTimeRequest) : const Scaffold(body: EmptyState(icon: Icons.more_time, title: 'Open this request from the booking page')),
      ),
      GoRoute(path: '/chat/:id', builder: (c, s) => ChatScreen(bookingId: s.pathParameters['id']!)),
      GoRoute(path: '/support', builder: (c, s) => SupportScreen(bookingId: s.uri.queryParameters['booking'])),
      GoRoute(path: '/worker/job/:id', builder: (c, s) => JobDetailScreen(jobId: s.pathParameters['id']!)),
      GoRoute(path: '/worker/onboarding', builder: (c, s) => const OnboardingScreen()),
      GoRoute(path: '/worker/availability', builder: (c, s) => const AvailabilityScreen()),
    ],
  );
});

class _Shell extends ConsumerWidget {
  const _Shell(this.shell, {required this.customer});
  final StatefulNavigationShell shell;
  final bool customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = (ref.watch(notificationsProvider).value ?? const <AppNotification>[]).where((n) => !n.read).length;
    final destinations = customer
        ? const [('Home', Icons.home_outlined, Icons.home), ('Bookings', Icons.event_note_outlined, Icons.event_note), ('Alerts', Icons.notifications_none, Icons.notifications), ('Account', Icons.person_outline, Icons.person)]
        : const [('Today', Icons.today_outlined, Icons.today), ('Jobs', Icons.work_outline, Icons.work), ('Alerts', Icons.notifications_none, Icons.notifications), ('Earnings', Icons.account_balance_wallet_outlined, Icons.account_balance_wallet)];
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
        destinations: [
          for (var i = 0; i < destinations.length; i++)
            NavigationDestination(
              label: destinations[i].$1,
              icon: i == 2 && unread > 0 ? Badge.count(count: unread, child: Icon(destinations[i].$2)) : Icon(destinations[i].$2),
              selectedIcon: Icon(destinations[i].$3),
            ),
        ],
      ),
    );
  }
}

class SkillConnectApp extends ConsumerWidget {
  const SkillConnectApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        title: Env.brandName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        darkTheme: buildTheme(brightness: Brightness.dark),
        routerConfig: ref.watch(routerProvider),
      );
}
