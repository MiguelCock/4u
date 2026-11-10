/// How well a palette reads on the map, for C4: WCAG contrast against the
/// map's backgrounds, colour-blind simulation (Machado, Oliveira and
/// Fernandes 2009, full severity), and CIEDE2000 colour distance. Pure, so
/// `test/theme/admin_palette_test.dart` measures every option.
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'admin_palette.dart';

/// OpenStreetMap's standard style, where the admin maps are drawn.
const kMapBackgrounds = {
  'land': Color(0xFFF2EFE9),
  'park': Color(0xFFC8FACC),
  'grass': Color(0xFFCDEBB0),
  'water': Color(0xFFAAD3DF),
  'building': Color(0xFFD9D0C9),
};

/// WCAG's minimum for graphics that carry meaning (1.4.11).
const double kMinContrast = 3;

/// Below this CIEDE2000 distance two colours are hard to tell apart at a
/// glance on a small marker.
const double kMinDistance = 10;

enum Vision { normal, protanopia, deuteranopia, tritanopia }

const _machado = {
  Vision.protanopia: [
    [0.152286, 1.052583, -0.204868],
    [0.114503, 0.786281, 0.099216],
    [-0.003882, -0.048116, 1.051998],
  ],
  Vision.deuteranopia: [
    [0.367322, 0.860646, -0.227968],
    [0.280085, 0.672501, 0.047413],
    [-0.011820, 0.042940, 0.968881],
  ],
  Vision.tritanopia: [
    [1.255528, -0.076749, -0.178779],
    [-0.078411, 0.930809, 0.147602],
    [0.004733, 0.691367, 0.303900],
  ],
};

double _toLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _toSrgb(double c) {
  final v = c.clamp(0.0, 1.0);
  return v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
}

List<double> _linear(Color c) => [
  _toLinear(c.r),
  _toLinear(c.g),
  _toLinear(c.b),
];

/// [color] as someone with [vision] sees it.
Color simulate(Color color, Vision vision) {
  final m = _machado[vision];
  if (m == null) return color;
  final rgb = _linear(color);
  final out = [
    for (final row in m) row[0] * rgb[0] + row[1] * rgb[1] + row[2] * rgb[2],
  ];
  return Color.from(
    alpha: 1,
    red: _toSrgb(out[0]),
    green: _toSrgb(out[1]),
    blue: _toSrgb(out[2]),
  );
}

/// The colour as drawn over [background] (a line drawn see-through).
Color over(Color color, Color background) =>
    Color.alphaBlend(color, background);

double _luminance(Color c) {
  final rgb = _linear(c);
  return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
}

/// WCAG contrast ratio, 1 to 21.
double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

List<double> _lab(Color c) {
  final rgb = _linear(c);
  double f(double t) => t > 216 / 24389
      ? math.pow(t, 1 / 3).toDouble()
      : (24389 / 27 * t + 16) / 116;
  final x = (0.4124 * rgb[0] + 0.3576 * rgb[1] + 0.1805 * rgb[2]) / 0.95047;
  final y = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
  final z = (0.0193 * rgb[0] + 0.1192 * rgb[1] + 0.9505 * rgb[2]) / 1.08883;
  return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
}

/// CIEDE2000 distance between two colours (0 = the same).
double distance(Color c1, Color c2) => deltaE2000(_lab(c1), _lab(c2));

/// CIEDE2000 between two CIELAB colours ([L, a, b]).
double deltaE2000(List<double> lab1, List<double> lab2) {
  final (l1, a1, b1) = (lab1[0], lab1[1], lab1[2]);
  final (l2, a2, b2) = (lab2[0], lab2[1], lab2[2]);
  double deg(double r) => r * 180 / math.pi;
  double rad(double d) => d * math.pi / 180;
  final cBar =
      (math.sqrt(a1 * a1 + b1 * b1) + math.sqrt(a2 * a2 + b2 * b2)) / 2;
  final g =
      0.5 *
      (1 -
          math.sqrt(math.pow(cBar, 7) / (math.pow(cBar, 7) + math.pow(25, 7))));
  final a1p = (1 + g) * a1;
  final a2p = (1 + g) * a2;
  final c1p = math.sqrt(a1p * a1p + b1 * b1);
  final c2p = math.sqrt(a2p * a2p + b2 * b2);
  double hue(double b, double ap) {
    if (b == 0 && ap == 0) return 0;
    final h = deg(math.atan2(b, ap));
    return h < 0 ? h + 360 : h;
  }

  final h1p = hue(b1, a1p);
  final h2p = hue(b2, a2p);
  final dLp = l2 - l1;
  final dCp = c2p - c1p;
  double dhp;
  if (c1p * c2p == 0) {
    dhp = 0;
  } else if ((h2p - h1p).abs() <= 180) {
    dhp = h2p - h1p;
  } else {
    dhp = h2p - h1p > 180 ? h2p - h1p - 360 : h2p - h1p + 360;
  }
  final dHp = 2 * math.sqrt(c1p * c2p) * math.sin(rad(dhp / 2));
  final lBarp = (l1 + l2) / 2;
  final cBarp = (c1p + c2p) / 2;
  double hBarp;
  if (c1p * c2p == 0) {
    hBarp = h1p + h2p;
  } else if ((h1p - h2p).abs() <= 180) {
    hBarp = (h1p + h2p) / 2;
  } else {
    hBarp = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2;
  }
  final t =
      1 -
      0.17 * math.cos(rad(hBarp - 30)) +
      0.24 * math.cos(rad(2 * hBarp)) +
      0.32 * math.cos(rad(3 * hBarp + 6)) -
      0.20 * math.cos(rad(4 * hBarp - 63));
  final dTheta = 30 * math.exp(-math.pow((hBarp - 275) / 25, 2));
  final rc =
      2 *
      math.sqrt(math.pow(cBarp, 7) / (math.pow(cBarp, 7) + math.pow(25, 7)));
  final sl =
      1 +
      (0.015 * math.pow(lBarp - 50, 2)) /
          math.sqrt(20 + math.pow(lBarp - 50, 2));
  final sc = 1 + 0.045 * cBarp;
  final sh = 1 + 0.015 * cBarp * t;
  final rt = -math.sin(rad(2 * dTheta)) * rc;
  return math.sqrt(
    math.pow(dLp / sl, 2) +
        math.pow(dCp / sc, 2) +
        math.pow(dHp / sh, 2) +
        rt * (dCp / sc) * (dHp / sh),
  );
}

/// Two meanings that must be told apart on the map.
class PalettePair {
  final String a;
  final String b;

  /// Told apart by shape in this palette (a ring, a ✕, ▲ against ▼), so
  /// colour is a second signal there, not the only one.
  final bool byShape;

  const PalettePair(this.a, this.b, {required this.byShape});
}

/// The colours a palette gives each meaning that's drawn on the map.
Map<String, Color> mapColours(AdminPalette p) => {
  'verified': p.verified,
  'pending': p.pending,
  'rejected': p.rejected,
  'floorAbove': p.floorAbove,
  'floorBelow': p.floorBelow,
  'selected': p.selected,
};

/// The pairs that matter, and which ones [p] tells apart by shape.
List<PalettePair> pairsFor(AdminPalette p) => [
  PalettePair('verified', 'pending', byShape: p.pendingHollow),
  PalettePair('verified', 'rejected', byShape: p.rejectedCross),
  PalettePair(
    'pending',
    'rejected',
    byShape: p.pendingHollow || p.rejectedCross,
  ),
  // ▲ and ▼ always.
  const PalettePair('floorAbove', 'floorBelow', byShape: true),
  // Floors and statuses: the issue's worry (red floors beside red rejected).
  for (final floor in ['floorAbove', 'floorBelow'])
    for (final status in ['verified', 'pending', 'rejected'])
      PalettePair(floor, status, byShape: false),
  for (final status in ['verified', 'pending', 'rejected'])
    PalettePair('selected', status, byShape: false),
];

/// One option's numbers: the lowest contrast of each meaning against the
/// map, and each pair's distance for each kind of vision.
class PaletteReport {
  final AdminPalette palette;
  final Map<String, double> minContrast;
  final Map<PalettePair, Map<Vision, double>> distances;

  PaletteReport(this.palette)
    : minContrast = {
        for (final e in mapColours(palette).entries)
          e.key: kMapBackgrounds.values
              .map((bg) => contrast(e.value, bg))
              .reduce(math.min),
      },
      distances = {
        for (final pair in pairsFor(palette))
          pair: {
            for (final vision in Vision.values)
              vision: distance(
                simulate(mapColours(palette)[pair.a]!, vision),
                simulate(mapColours(palette)[pair.b]!, vision),
              ),
          },
      };

  /// A dot with an outline takes its contrast from the outline, if the
  /// outline itself stands out on every background (a white one doesn't).
  bool hasOutline(String meaning) {
    final outline = palette.dotOutline;
    // A ✕ or a ring is drawn without an outline.
    final drawnAsDot = switch (meaning) {
      'verified' => true,
      'pending' => !palette.pendingHollow,
      'rejected' => !palette.rejectedCross,
      _ => false,
    };
    return outline != null &&
        drawnAsDot &&
        kMapBackgrounds.values.every(
          (bg) => contrast(outline, bg) >= kMinContrast,
        );
  }

  /// What fails: low contrast without an outline, and pairs told apart
  /// only by colour that some vision can't tell apart.
  List<String> problems() => [
    for (final e in minContrast.entries)
      if (e.value < kMinContrast && !hasOutline(e.key))
        '${e.key}: contrast ${e.value.toStringAsFixed(1)} on the map',
    for (final e in distances.entries)
      if (!e.key.byShape)
        for (final v in e.value.entries)
          if (v.value < kMinDistance)
            '${e.key.a}/${e.key.b}: ${v.value.toStringAsFixed(1)} '
                'for ${v.key.name}',
  ];
}
