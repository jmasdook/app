import 'package:flutter_test/flutter_test.dart';
import 'package:skillconnect/app.dart';
import 'package:skillconnect/core/money.dart';
import 'package:skillconnect/data/models.dart';
import 'package:skillconnect/features/auth/auth_screens.dart';
import 'support.dart';

void main() {
  group('money', () {
    test('formats minor units exactly', () {
      expect(formatMoney(15750), 'AED 157.50');
      expect(formatMoney(5), 'AED 0.05');
      expect(formatMoney(123456789), 'AED 1,234,567.89');
      expect(formatMoney(-250), 'AED -2.50');
      expect(formatMoney(null), '-');
    });
    test('durations', () {
      expect(formatDuration(45), '45 min');
      expect(formatDuration(120), '2 h');
      expect(formatDuration(150), '2 h 30 min');
    });
  });

  group('worker job state', () {
    test('offers only the next lawful step; the server still validates every transition', () {
      expect(sampleJob('assigned').nextAction?.to, 'accepted');
      expect(sampleJob('accepted').nextAction?.to, 'en_route');
      expect(sampleJob('en_route').nextAction?.to, 'arrived');
      expect(sampleJob('arrived').nextAction?.to, 'in_progress');
      expect(sampleJob('in_progress').nextAction?.to, 'awaiting_confirmation');
      for (final s in ['awaiting_confirmation', 'completed', 'cancelled', 'disputed']) {
        expect(sampleJob(s).nextAction, isNull, reason: s);
      }
    });
  });

  group('booking buckets', () {
    Booking b(String status) => Booking(id: '1', ref: 'SC-1', status: status, start: DateTime(2030), end: DateTime(2030), currency: 'AED', totalMinor: 1, serviceName: 's');
    test('upcoming / active / cancellable', () {
      expect(b('pending_payment').isUpcoming, isTrue);
      expect(b('assigned').canCancel, isTrue);
      expect(b('in_progress').isActive, isTrue);
      expect(b('in_progress').canCancel, isFalse);
      expect(b('completed').canCancel, isFalse);
    });
  });

  test('friendlyError hides internals and maps backend error codes', () {
    expect(friendlyError(Exception('P0001 slot_unavailable')), contains('just taken'));
    expect(friendlyError(Exception('SocketException: Failed host lookup')), contains('No connection'));
    expect(friendlyError(Exception('relation "x" does not exist at line 5')), 'Something went wrong. Please try again.');
  });

  test('form validators', () {
    expect(validateEmail('a@b.co'), isNull);
    expect(validateEmail('nope'), isNotNull);
    expect(validatePassword('short'), isNotNull);
    expect(validatePassword('longenough'), isNull);
  });

  test('role-based experience selection', () {
    expect(isWorkerExperience({'customer'}, null), isFalse);
    expect(isWorkerExperience({'customer', 'worker'}, null), isTrue);
    expect(isWorkerExperience({'customer', 'worker'}, false), isFalse);
  });
}
