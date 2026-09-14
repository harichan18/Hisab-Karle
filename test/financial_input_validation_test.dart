import 'package:flutter_test/flutter_test.dart';
import 'package:hisab_kitab/utils/amount_parser.dart';

void main() {
  group('Financial Input Validation Tests', () {
    test('1. Empty and whitespace-only inputs are rejected (return null)', () {
      expect(AmountParser.parseAmount(null), isNull);
      expect(AmountParser.parseAmount(''), isNull);
      expect(AmountParser.parseAmount('   '), isNull);
      expect(AmountParser.parseAmount('\t\n'), isNull);
    });

    test('2. Zero amounts in various forms are rejected (return null)', () {
      expect(AmountParser.parseAmount('0'), isNull);
      expect(AmountParser.parseAmount('0.0'), isNull);
      expect(AmountParser.parseAmount('0.00'), isNull);
      expect(AmountParser.parseAmount('₹0'), isNull);
      expect(AmountParser.parseAmount('Rs 0.00'), isNull);
      expect(AmountParser.parseAmount('०'), isNull); // Devanagari zero
      expect(AmountParser.parseAmount('०.००'), isNull);
    });

    test('3. Negative amounts are strictly rejected (return null)', () {
      expect(AmountParser.parseAmount('-1'), isNull);
      expect(AmountParser.parseAmount('-500'), isNull);
      expect(AmountParser.parseAmount('-0.01'), isNull);
      expect(AmountParser.parseAmount('₹-250'), isNull);
      expect(AmountParser.parseAmount('Rs. -100'), isNull);
    });

    test('4. Non-numeric or invalid text is rejected without crashing', () {
      expect(AmountParser.parseAmount('abc'), isNull);
      expect(AmountParser.parseAmount('₹'), isNull);
      expect(AmountParser.parseAmount('Rs.'), isNull);
      expect(AmountParser.parseAmount('NaN'), isNull);
      expect(AmountParser.parseAmount('Infinity'), isNull);
      expect(AmountParser.parseAmount('...'), isNull);
      expect(AmountParser.parseAmount('12.34.56'), isNull);
    });

    test('5. Valid integers are parsed accurately', () {
      expect(AmountParser.parseAmount('1'), 1.0);
      expect(AmountParser.parseAmount('12'), 12.0);
      expect(AmountParser.parseAmount('500'), 500.0);
      expect(AmountParser.parseAmount('10000'), 10000.0);
      expect(AmountParser.parseAmount('9999999'), 9999999.0);
    });

    test('6. Valid decimal amounts with 1, 2, or micro decimals are parsed accurately', () {
      expect(AmountParser.parseAmount('0.5'), 0.5);
      expect(AmountParser.parseAmount('0.05'), 0.05);
      expect(AmountParser.parseAmount('0.01'), 0.01);
      expect(AmountParser.parseAmount('125.50'), 125.50);
      expect(AmountParser.parseAmount('9999.99'), 9999.99);
    });

    test('7. Indian numbering comma format (lakhs/crores) parsed correctly', () {
      expect(AmountParser.parseAmount('1,000'), 1000.0);
      expect(AmountParser.parseAmount('10,000'), 10000.0);
      expect(AmountParser.parseAmount('1,00,000'), 100000.0);
      expect(AmountParser.parseAmount('12,34,567.89'), 1234567.89);
      expect(AmountParser.parseAmount('1,00,00,000'), 10000000.0);
    });

    test('8. Diverse currency indicators (₹, Rs, INR, words) are stripped cleanly', () {
      expect(AmountParser.parseAmount('₹500'), 500.0);
      expect(AmountParser.parseAmount('₹ 1,500.00'), 1500.0);
      expect(AmountParser.parseAmount('Rs. 250'), 250.0);
      expect(AmountParser.parseAmount('Rs 750'), 750.0);
      expect(AmountParser.parseAmount('INR 2,000'), 2000.0);
      expect(AmountParser.parseAmount('Paid ₹12'), 12.0);
      expect(AmountParser.parseAmount('Amount: ₹999'), 999.0);
    });

    test('9. Devanagari numerals are normalized to standard numbers', () {
      expect(AmountParser.parseAmount('१२'), 12.0);
      expect(AmountParser.parseAmount('₹५००'), 500.0);
      expect(AmountParser.parseAmount('₹१,२५,५००.५०'), 125500.50);
    });

    test('10. Upper ceiling limit check: values exceeding ₹10,00,00,000 are identified', () {
      bool isWithinAppCeiling(double amount) {
        const double maxAllowed = 100000000.0; // ₹10 crore
        return amount <= maxAllowed;
      }

      expect(isWithinAppCeiling(100.0), isTrue);
      expect(isWithinAppCeiling(10000000.0), isTrue); // ₹1 crore
      expect(isWithinAppCeiling(100000000.0), isTrue); // ₹10 crore (exact boundary)
      expect(isWithinAppCeiling(100000000.01), isFalse); // exceeds boundary
      expect(isWithinAppCeiling(500000000.0), isFalse);
    });

    test('11. Integer paise round-trip maintains exact precision', () {
      final testValues = [0.01, 0.50, 1.0, 12.34, 100.0, 999.99, 125500.50];

      for (final val in testValues) {
        final paise = AmountParser.toPaise(val);
        expect(paise, isNotNull);
        final backToRupees = AmountParser.fromPaise(paise!);
        expect(double.parse(backToRupees.toStringAsFixed(2)), val);
      }
    });

    test('12. Friend name validation rejects empty or whitespace-only names', () {
      String? validateFriendName(String? name) {
        if (name == null || name.trim().isEmpty) {
          return 'Friend name cannot be empty';
        }
        if (name.trim().length > 50) {
          return 'Friend name is too long';
        }
        return null;
      }

      expect(validateFriendName(null), isNotNull);
      expect(validateFriendName(''), isNotNull);
      expect(validateFriendName('   '), isNotNull);
      expect(validateFriendName('A' * 51), isNotNull);
      expect(validateFriendName('Aman'), isNull);
      expect(validateFriendName('  Priya Sharma  '), isNull);
    });
  });
}
