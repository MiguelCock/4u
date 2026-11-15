import 'package:flutter/material.dart';

import '../services/location_types.dart' show LocationCategory;

/// Every colour the admin screens give a meaning to, in one place (C4,
/// `docs/decisions/c4-palette.md`). Shape carries meaning as well as colour:
/// floors are ▲/▼, and an option may draw a status as a ring or a ✕, so no
/// meaning rests on colour alone.
class AdminPalette {
  final String name;

  // A point's review status.
  final Color verified;
  final Color pending;
  final Color rejected;

  /// Pending drawn as a ring instead of a dot.
  final bool pendingHollow;

  /// Rejected drawn as a ✕ instead of a dot.
  final bool rejectedCross;

  /// Around every dot, so it stands out on any map background.
  final Color? dotOutline;

  // The floors directly above and below the one shown (▲ and ▼).
  final Color floorAbove;
  final Color floorBelow;

  // Connections: faint on the map, strong while connecting, grey while
  // saving.
  final Color connection;
  final Color connectionActive;
  final Color connectionPending;

  /// The point selected or being moved, and the pin of a move.
  final Color selected;

  /// The location picker's pin.
  final Color pickPin;

  final Color university;
  final Color building;
  final Color inactive;

  // A session's map.
  final Color planned;
  final Color raw;
  final Color corrected;
  final Color match;

  /// Exact shades for confident and weak matches; else derived from [match].
  final Color? matchStrong;
  final Color? matchWeak;
  final Color report;
  final Color checkpoint;

  /// The menu's notices of things to fix.
  final Color notice;

  /// A connection's colour by length (C7): up to 5 m, at 15 m (the warning),
  /// at 30 m (the limit), and past it. Blended between the first three.
  final Color connectionShort;
  final Color connectionMid;
  final Color connectionLong;
  final Color connectionTooLong;

  /// Each kind of place (C8): destinations on the map, and the mark before
  /// a point's name in lists.
  final Map<LocationCategory, Color> categories;

  const AdminPalette({
    required this.name,
    required this.verified,
    required this.pending,
    required this.rejected,
    this.pendingHollow = false,
    this.rejectedCross = false,
    this.dotOutline,
    required this.floorAbove,
    required this.floorBelow,
    required this.connection,
    required this.connectionActive,
    required this.connectionPending,
    required this.selected,
    required this.pickPin,
    required this.university,
    required this.building,
    required this.inactive,
    required this.planned,
    required this.raw,
    required this.corrected,
    required this.match,
    this.matchStrong,
    this.matchWeak,
    required this.report,
    required this.checkpoint,
    required this.notice,
    required this.connectionShort,
    required this.connectionMid,
    required this.connectionLong,
    required this.connectionTooLong,
    required this.categories,
  });

  /// The colour of a connection [meters] long: green when short, orange at
  /// the 15 m warning, red at the 30 m limit, black past it.
  Color connectionFor(double meters) {
    if (meters > 30) return connectionTooLong;
    if (meters <= 5) return connectionShort;
    if (meters <= 15) {
      return Color.lerp(connectionShort, connectionMid, (meters - 5) / 10)!;
    }
    return Color.lerp(connectionMid, connectionLong, (meters - 15) / 15)!;
  }

  /// A kind of place's colour.
  Color category(LocationCategory category) => categories[category] ?? inactive;

  /// A status's colour (null or unknown: pending).
  Color status(String? status) => switch (status) {
    'verified' => verified,
    'rejected' => rejected,
    _ => pending,
  };

  /// A photo match's dot, stronger for a more confident match.
  Color matchFor(double confidence) => confidence >= 0.9
      ? matchStrong ?? Color.lerp(match, Colors.black, 0.25)!
      : confidence >= 0.8
      ? match
      : matchWeak ?? Color.lerp(match, Colors.white, 0.45)!;
}

/// The admin palette (C4): the Okabe–Ito colour-blind-safe set, darkened
/// where it was too light for the map. Chosen over two other options and the
/// old colours by its numbers and look; see `docs/decisions/c4-palette.md`.
/// Rejected is a ✕, and dots have a black outline, which carries their
/// contrast on the light map.
const kAdminPalette = AdminPalette(
  name: 'c',
  verified: Color(0xFF009E73),
  pending: Color(0xFFBDBDBD),
  rejected: Color(0xFFA84400),
  rejectedCross: true,
  dotOutline: Color(0xFF000000),
  floorAbove: Color(0xFF0072B2),
  floorBelow: Color(0xFF6A3D9A),
  connection: Color(0x990072B2),
  connectionActive: Color(0xFF0072B2),
  connectionPending: Color(0xFF9E9E9E),
  selected: Color(0xFF000000),
  pickPin: Color(0xFFA84400),
  university: Color(0xFF7B3294),
  building: Color(0xFFE69F00),
  inactive: Color(0xFF9E9E9E),
  planned: Color(0xFF56656F),
  raw: Color(0xFFE69F00),
  corrected: Color(0xFF009E73),
  match: Color(0xFF6A3D9A),
  report: Color(0xFFA84400),
  checkpoint: Color(0xFF0072B2),
  notice: Color(0xFFA84400),
  connectionShort: Color(0xFF007A5A),
  connectionMid: Color(0xFFB35900),
  connectionLong: Color(0xFF8B0000),
  connectionTooLong: Color(0xFF000000),
  // Paul Tol's colour-blind-safe "muted" set, its darker members.
  categories: {
    LocationCategory.paths: Color(0xFF6E6E6E),
    LocationCategory.gettingAround: Color(0xFF332288),
    LocationCategory.academic: Color(0xFF882255),
    LocationCategory.services: Color(0xFF117733),
    LocationCategory.wellbeing: Color(0xFFAA4499),
    LocationCategory.other: Color(0xFF6E6E6E),
  },
);
