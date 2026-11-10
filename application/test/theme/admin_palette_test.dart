import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/theme/admin_palette.dart';
import 'package:eyes4u/theme/palette_checks.dart';

void main() {
  test('contrast and distance agree with the published values', () {
    expect(contrast(const Color(0xFF000000), const Color(0xFFFFFFFF)), 21);
    // Sharma, Wu and Dalal's CIEDE2000 test data, pair 1.
    expect(
      deltaE2000([50, 2.6772, -79.7751], [50, 0, -82.7485]),
      closeTo(2.0425, 1e-4),
    );
    expect(deltaE2000([50, 2.5, 0], [73, 25, -18]), closeTo(27.1492, 1e-4));
  });

  test('colour-blind simulation keeps greys grey and changes reds', () {
    const grey = Color(0xFF808080);
    for (final vision in Vision.values) {
      final g = simulate(grey, vision);
      expect(distance(g, grey), lessThan(2), reason: vision.name);
    }
    const red = Color(0xFFF44336);
    const green = Color(0xFF4CAF50);
    // Today's verified and rejected: clear for most, close for protanopia.
    expect(distance(red, green), greaterThan(40));
    expect(
      distance(
        simulate(red, Vision.protanopia),
        simulate(green, Vision.protanopia),
      ),
      lessThan(distance(red, green) / 2),
    );
  });

  test('the admin palette meets the thresholds', () {
    final report = PaletteReport(kAdminPalette);
    expect(report.problems(), isEmpty);
    // Shape as well as colour: rejected is a ✕, and dots are outlined.
    expect(kAdminPalette.rejectedCross, isTrue);
    expect(kAdminPalette.dotOutline, isNotNull);
  });
}
