import 'package:flutter_test/flutter_test.dart';
import 'package:hisab_kitab/services/split_calculator.dart';

void main() {
  group('SplitCalculator Equal Split Tests', () {
    test('₹500 split equally among 3 friends', () {
      final friends = [
        (name: 'Rahul', uid: 'u1'),
        (name: 'Aman', uid: 'u2'),
        (name: 'Priya', uid: 'u3'),
      ];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 500.0,
        friends: friends,
      );

      expect(shares.length, 3);
      expect(shares[0].amount, 166.67);
      expect(shares[1].amount, 166.67);
      expect(shares[2].amount, 166.66);

      final total = shares.fold<double>(0.0, (sum, s) => sum + s.amount);
      expect(double.parse(total.toStringAsFixed(2)), 500.0);
    });

    test('₹100 split equally among 3 friends', () {
      final friends = [
        (name: 'Rahul', uid: 'u1'),
        (name: 'Aman', uid: 'u2'),
        (name: 'Priya', uid: 'u3'),
      ];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 100.0,
        friends: friends,
      );

      expect(shares.length, 3);
      expect(shares[0].amount, 33.34);
      expect(shares[1].amount, 33.33);
      expect(shares[2].amount, 33.33);

      final total = shares.fold<double>(0.0, (sum, s) => sum + s.amount);
      expect(double.parse(total.toStringAsFixed(2)), 100.0);
    });

    test('₹1000 split equally between 2 friends', () {
      final friends = [(name: 'Rahul', uid: 'u1'), (name: 'Aman', uid: 'u2')];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 1000.0,
        friends: friends,
      );

      expect(shares.length, 2);
      expect(shares[0].amount, 500.0);
      expect(shares[1].amount, 500.0);

      final total = shares.fold<double>(0.0, (sum, s) => sum + s.amount);
      expect(total, 1000.0);
    });

    test('Single friend ₹250', () {
      final friends = [(name: 'Rahul', uid: 'u1')];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 250.0,
        friends: friends,
      );

      expect(shares.length, 1);
      expect(shares[0].amount, 250.0);
    });
  });

  group('SplitCalculator Custom and Percentage Split Tests', () {
    test('Validate custom split amounts', () {
      expect(
        SplitCalculator.validateCustomSplit(
          totalAmount: 500.0,
          customAmounts: [200.0, 150.0, 150.0],
        ),
        isNull,
      );

      expect(
        SplitCalculator.validateCustomSplit(
          totalAmount: 500.0,
          customAmounts: [200.0, 100.0, 150.0],
        ),
        isNotNull,
      );
    });

    test('Percentage split 40%, 30%, 30% for ₹500', () {
      final friends = [
        (name: 'Rahul', uid: 'u1', percentage: 40.0),
        (name: 'Aman', uid: 'u2', percentage: 30.0),
        (name: 'Priya', uid: 'u3', percentage: 30.0),
      ];

      final shares = SplitCalculator.calculatePercentageSplit(
        totalAmount: 500.0,
        friends: friends,
      );

      expect(shares[0].amount, 200.0);
      expect(shares[1].amount, 150.0);
      expect(shares[2].amount, 150.0);

      final total = shares.fold<double>(0.0, (sum, s) => sum + s.amount);
      expect(total, 500.0);
    });

    test('7-way equal split with uneven remainder preserves exact total in paise', () {
      final friends = List.generate(
        7,
        (i) => (name: 'Friend $i', uid: 'u$i'),
      );

      // ₹100.00 / 7 = 10000 paise / 7 = 1428 paise base + 4 remainder paise
      // First 4 get 14.29, remaining 3 get 14.28
      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 100.0,
        friends: friends,
      );

      expect(shares.length, 7);
      expect(shares[0].amount, 14.29);
      expect(shares[1].amount, 14.29);
      expect(shares[2].amount, 14.29);
      expect(shares[3].amount, 14.29);
      expect(shares[4].amount, 14.28);
      expect(shares[5].amount, 14.28);
      expect(shares[6].amount, 14.28);

      final sumPaise = shares.fold<int>(
        0,
        (sum, s) => sum + (s.amount * 100).round(),
      );
      expect(sumPaise, 10000); // exactly ₹100.00
    });

    test('Decimal total amount ₹123.45 split across 4 friends reconciles exactly', () {
      final friends = List.generate(
        4,
        (i) => (name: 'Person $i', uid: 'p$i'),
      );

      // 12345 paise / 4 = 3086 base + 1 remainder
      // First person: 30.87, other 3: 30.86
      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 123.45,
        friends: friends,
      );

      expect(shares[0].amount, 30.87);
      expect(shares[1].amount, 30.86);
      expect(shares[2].amount, 30.86);
      expect(shares[3].amount, 30.86);

      final sumPaise = shares.fold<int>(
        0,
        (sum, s) => sum + (s.amount * 100).round(),
      );
      expect(sumPaise, 12345);
    });

    test('Micro amounts: 5 paise (₹0.05) split across 3 friends never loses money', () {
      final friends = [
        (name: 'A', uid: 'a'),
        (name: 'B', uid: 'b'),
        (name: 'C', uid: 'c'),
      ];

      // 5 paise / 3 = 1 base + 2 remainder -> 2 paise, 2 paise, 1 paisa
      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 0.05,
        friends: friends,
      );

      expect(shares[0].amount, 0.02);
      expect(shares[1].amount, 0.02);
      expect(shares[2].amount, 0.01);

      final sumPaise = shares.fold<int>(
        0,
        (sum, s) => sum + (s.amount * 100).round(),
      );
      expect(sumPaise, 5);
    });

    test('1 paisa (₹0.01) split across 4 friends gives 1 paisa to first and 0 to others', () {
      final friends = [
        (name: 'A', uid: 'a'),
        (name: 'B', uid: 'b'),
        (name: 'C', uid: 'c'),
        (name: 'D', uid: 'd'),
      ];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 0.01,
        friends: friends,
      );

      expect(shares[0].amount, 0.01);
      expect(shares[1].amount, 0.0);
      expect(shares[2].amount, 0.0);
      expect(shares[3].amount, 0.0);

      final sumPaise = shares.fold<int>(
        0,
        (sum, s) => sum + (s.amount * 100).round(),
      );
      expect(sumPaise, 1);
    });

    test('Percentage split with uneven fractions adjusts rounding discrepancy to match total', () {
      final friends = [
        (name: 'A', uid: 'a', percentage: 33.33),
        (name: 'B', uid: 'b', percentage: 33.33),
        (name: 'C', uid: 'c', percentage: 33.34),
      ];

      final shares = SplitCalculator.calculatePercentageSplit(
        totalAmount: 1000.0,
        friends: friends,
      );

      final sumPaise = shares.fold<int>(
        0,
        (sum, s) => sum + (s.amount * 100).round(),
      );
      expect(sumPaise, 100000); // strictly ₹1000.00
    });

    test('Invalid split inputs return empty list safely without throwing', () {
      final friends = [(name: 'A', uid: 'a')];

      expect(
        SplitCalculator.calculateEqualSplit(totalAmount: 0, friends: friends),
        isEmpty,
      );
      expect(
        SplitCalculator.calculateEqualSplit(totalAmount: -50, friends: friends),
        isEmpty,
      );
      expect(
        SplitCalculator.calculateEqualSplit(totalAmount: 100, friends: []),
        isEmpty,
      );

      expect(
        SplitCalculator.calculateEqualSplit(
          totalAmount: double.nan,
          friends: [(name: 'A', uid: 'a')],
        ),
        isEmpty,
      );
      expect(
        SplitCalculator.calculateEqualSplit(
          totalAmount: double.infinity,
          friends: [(name: 'A', uid: 'a')],
        ),
        isEmpty,
      );

      expect(
        SplitCalculator.calculatePercentageSplit(
          totalAmount: 0,
          friends: [(name: 'A', uid: 'a', percentage: 100)],
        ),
        isEmpty,
      );
      expect(
        SplitCalculator.calculatePercentageSplit(
          totalAmount: -100,
          friends: [(name: 'A', uid: 'a', percentage: 100)],
        ),
        isEmpty,
      );
      expect(
        SplitCalculator.calculatePercentageSplit(
          totalAmount: double.nan,
          friends: [(name: 'A', uid: 'a', percentage: 100)],
        ),
        isEmpty,
      );
      expect(
        SplitCalculator.calculatePercentageSplit(
          totalAmount: 100,
          friends: [(name: 'A', uid: 'a', percentage: double.nan)],
        ),
        isEmpty,
      );
      expect(
        SplitCalculator.calculatePercentageSplit(
          totalAmount: 100,
          friends: [(name: 'A', uid: 'a', percentage: -10)],
        ),
        isEmpty,
      );
      expect(
        SplitCalculator.calculatePercentageSplit(
          totalAmount: 100,
          friends: [],
        ),
        isEmpty,
      );
    });

    test('Custom split validation handles negative amounts, under-allocation, and over-allocation', () {
      // Negative amount
      final negResult = SplitCalculator.validateCustomSplit(
        totalAmount: 100.0,
        customAmounts: [120.0, -20.0],
      );
      expect(negResult, contains('negative'));

      // Under-allocated
      final underResult = SplitCalculator.validateCustomSplit(
        totalAmount: 100.0,
        customAmounts: [40.0, 30.0],
      );
      expect(underResult, contains('remaining'));
      expect(underResult, contains('30.00'));

      // Over-allocated
      final overResult = SplitCalculator.validateCustomSplit(
        totalAmount: 100.0,
        customAmounts: [60.0, 60.0],
      );
      expect(overResult, contains('exceeds'));
      expect(overResult, contains('20.00'));
    });
  });
}
