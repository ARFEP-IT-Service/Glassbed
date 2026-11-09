import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/page_range.dart';
import 'package:glassbed/core/printing.dart';

void main() {
  test('valid page ranges', () {
    const cases = <(String, int, List<int>)>[
      ('', 4, [0, 1, 2, 3]),
      ('   ', 2, [0, 1]),
      ('1-2, 4', 5, [0, 1, 3]),
      ('1-3, 5', 5, [0, 1, 2, 4]),
      ('3-', 5, [2, 3, 4]),
      ('-2', 5, [0, 1]),
      ('2', 3, [1]),
      ('1;3', 3, [0, 2]),
      ('3, 1', 3, [2, 0]), // order as typed
      ('1, 1', 3, [0, 0]),
      ('2-9', 4, [1, 2, 3]), // cut at the last page
      (' 1 - 2 ,, ', 3, [0, 1]),
      ('', 0, []),
    ];
    for (final (text, count, expected) in cases) {
      expect(parsePageRange(text, count), expected, reason: '"$text" of $count');
    }
  });

  test('invalid page ranges', () {
    const cases = <(String, int)>[
      ('0', 3),
      ('5-3', 9), // reversed
      ('4', 3), // beyond the last page
      ('4-6', 3),
      ('a', 3),
      ('1-b', 3),
      ('1.5', 3),
      ('-1-2', 3),
      ('+2', 3),
      ('1-2-3', 3),
    ];
    for (final (text, count) in cases) {
      expect(() => parsePageRange(text, count), throwsFormatException, reason: '"$text" of $count');
    }
  });

  test('manual duplex plan', () {
    // even: fronts 1,3; backs 4,2 (reversed)
    final (f4, b4) = manualDuplexPlan([0, 1, 2, 3]);
    expect(f4, [0, 2]);
    expect(b4, [3, 1]);
    // odd: blank back for the last sheet comes first after reversing
    final (f5, b5) = manualDuplexPlan([0, 1, 2, 3, 4]);
    expect(f5, [0, 2, 4]);
    expect(b5, [null, 3, 1]);
    final (f1, b1) = manualDuplexPlan([7]);
    expect(f1, [7]);
    expect(b1, [null]);
    final (f2, b2) = manualDuplexPlan([4, 9]);
    expect(f2, [4]);
    expect(b2, [9]);
    final (f0, b0) = manualDuplexPlan([]);
    expect(f0, isEmpty);
    expect(b0, isEmpty);
  });
}
