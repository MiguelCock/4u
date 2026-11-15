import 'package:eyes4u/user/position_source.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Where the trip thinks the user is (Phase C).
void main() {
  const raw = LatLng(6.2000, -75.5800);
  const corrected = LatLng(6.2001, -75.5800); // ~11 m north

  test('raw GPS until there is a correction', () {
    final where = PositionSource();
    expect(where.current(raw), raw);
    expect(where.usedCorrected, isFalse);
    expect(where.current(null), isNull);
  });

  test('the correction\'s offset follows the live fix while fresh', () {
    fakeAsync((async) {
      final where = PositionSource()..correct(raw, corrected, 2);
      // The user walked ~11 m east since the photo.
      const moved = LatLng(6.2000, -75.5799);
      final here = where.current(moved)!;
      expect(here.latitude, closeTo(6.2001, 1e-6));
      expect(here.longitude, closeTo(-75.5799, 1e-6));
      expect(where.usedCorrected, isTrue);
      expect(where.correctionError, 2);

      async.elapse(const Duration(seconds: 21));
      expect(where.live(moved), isNull);
    });
  });

  test('stale: back to raw GPS over 2 s, not in one jump', () {
    fakeAsync((async) {
      final where = PositionSource()..correct(raw, corrected, 2);
      expect(where.current(raw), corrected);
      async.elapse(const Duration(seconds: 20));

      final first = where.current(raw)!; // the blend starts here
      expect(first.latitude, closeTo(6.2001, 1e-6));
      async.elapse(const Duration(seconds: 1));
      expect(where.current(raw)!.latitude, closeTo(6.20005, 1e-6));
      async.elapse(const Duration(seconds: 1));
      expect(where.current(raw), raw);
      expect(where.usedCorrected, isFalse);
    });
  });
}
