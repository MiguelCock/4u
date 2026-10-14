import 'dart:typed_data' show Uint8List;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eyes4u/services/image_utils.dart';

Uint8List _jpegOfColor(int r, int g, int b) {
  final image = img.Image(width: 32, height: 32);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(image));
}

Uint8List _jpegOfCheckerboard({int dark = 10, int light = 240}) {
  final image = img.Image(width: 32, height: 32);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final onLightSquare = ((x ~/ 4) + (y ~/ 4)) % 2 == 0;
      final value = onLightSquare ? light : dark;
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  test('a uniformly dark frame reads as blocked', () {
    expect(isFrameBlocked(_jpegOfColor(2, 2, 2)), isTrue);
  });

  test('a uniformly bright, textureless frame reads as blocked', () {
    // High mean luma, but zero variance - a lens pressed against a bright
    // surface shouldn't slip through just because it isn't dark.
    expect(isFrameBlocked(_jpegOfColor(250, 250, 250)), isTrue);
  });

  test('a textured scene does not read as blocked', () {
    expect(isFrameBlocked(_jpegOfCheckerboard()), isFalse);
  });

  test('bytes that fail to decode never block navigation', () {
    expect(isFrameBlocked(Uint8List.fromList([1, 2, 3])), isFalse);
  });

  test('meanLumaThreshold is respected', () {
    // A dim but textured checkerboard (mean luma ~11, so it has real
    // variance - well above the default stdDevThreshold) is blocked by
    // the default mean-luma check, but not once that threshold is lowered
    // past its actual mean.
    final dimChecker = _jpegOfCheckerboard(dark: 2, light: 20);
    expect(isFrameBlocked(dimChecker), isTrue);
    expect(isFrameBlocked(dimChecker, meanLumaThreshold: 5.0), isFalse);
  });
}
