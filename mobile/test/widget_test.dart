import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skillconnect/features/auth/auth_screens.dart';
import 'package:skillconnect/features/customer/bookings_screens.dart';
import 'package:skillconnect/features/customer/home_screen.dart';
import 'package:skillconnect/features/worker/worker_screens.dart';
import 'support.dart';

void main() {
  testWidgets('login validates input before calling the backend', (t) async {
    final auth = FakeAuth();
    await t.pumpWidget(wrap(const LoginScreen(), baseOverrides(auth: auth)));
    await t.tap(find.text('Sign in'));
    await t.pump();
    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(auth.calls, isEmpty);

    await t.enterText(find.widgetWithText(TextFormField, 'Email'), 'amina@example.test');
    await t.enterText(find.widgetWithText(TextFormField, 'Password'), 'secret-pass');
    await t.tap(find.text('Sign in'));
    await t.pump();
    expect(auth.calls, ['signIn:amina@example.test']);
  });

  testWidgets('home shows greeting, categories and popular services from the repository', (t) async {
    await t.pumpWidget(wrap(const Scaffold(body: HomeScreen()), baseOverrides()));
    await t.pumpAndSettle();
    expect(find.text('Hello, Amina'), findsOneWidget);
    expect(find.text('Plumbing'), findsOneWidget);
    expect(find.text('Plumber visit'), findsOneWidget);
    expect(find.text('What do you need help with?'), findsOneWidget);
  });

  testWidgets('extra time: declining never triggers a payment', (t) async {
    final bookings = FakeBookings();
    await t.pumpWidget(wrapRouted(ExtraTimeScreen(request: sampleExtra()), baseOverrides(bookings: bookings)));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('AED 63.00'), findsWidgets); // total shown before any decision
    expect(find.text('Found a second leak'), findsOneWidget);
    await t.tap(find.text('Decline'));
    await t.pumpAndSettle();
    expect(bookings.calls, ['decide:r1:false']);
  });

  testWidgets('extra time: approving asks for the decision first, then a server-verified payment step', (t) async {
    final bookings = FakeBookings();
    await t.pumpWidget(wrapRouted(ExtraTimeScreen(request: sampleExtra()), baseOverrides(bookings: bookings)));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('Approve & pay'));
    await t.pumpAndSettle();
    expect(bookings.calls, ['decide:r1:true', 'pay:b1:r1']);
  });

  testWidgets('worker job: shows the next action and sends the status change to the backend', (t) async {
    final worker = FakeWorker();
    await t.pumpWidget(wrap(const JobDetailScreen(jobId: 'b1'), baseOverrides(worker: worker)));
    await t.pumpAndSettle();
    expect(find.text('Accept job'), findsOneWidget);
    expect(find.text('Request extra time'), findsNothing, reason: 'only available while the job is in progress');
    expect(find.text('Exact address is shared once you are on your way.'), findsOneWidget);
    await t.tap(find.text('Accept job'));
    await t.pumpAndSettle();
    expect(worker.calls, ['status:accepted']);
    expect(find.text("I'm on my way"), findsOneWidget);
  });

  testWidgets('worker job in progress offers extra time and mark-done', (t) async {
    final worker = FakeWorker()..current = sampleJob('in_progress');
    await t.pumpWidget(wrap(const JobDetailScreen(jobId: 'b1'), baseOverrides(worker: worker)));
    await t.pumpAndSettle();
    expect(find.text('Request extra time'), findsOneWidget);
    expect(find.text('Mark work done'), findsOneWidget);
  });

  testWidgets('bookings screen shows an empty state when there are no bookings', (t) async {
    await t.pumpWidget(wrap(const Scaffold(body: BookingsScreen()), baseOverrides()));
    await t.pumpAndSettle();
    expect(find.text('Nothing here'), findsOneWidget);
  });
}
