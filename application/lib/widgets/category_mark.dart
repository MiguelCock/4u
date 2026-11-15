import 'package:flutter/material.dart';

import '../services/location_types.dart';
import '../theme/admin_palette.dart';

/// A small square in a point's category colour (C8), put before its name in
/// lists and details, so the kind of place reads at a glance as on the map.
/// Nothing for a point whose type isn't known.
class CategoryMark extends StatelessWidget {
  final int? locationTypeId;
  final double size;

  const CategoryMark({super.key, required this.locationTypeId, this.size = 12});

  @override
  Widget build(BuildContext context) {
    final type = locationTypeById(locationTypeId);
    if (type == null) return SizedBox(width: size);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: kAdminPalette.category(type.category),
          borderRadius: BorderRadius.circular(size / 4),
        ),
      ),
    );
  }
}

/// [text] with its point's [CategoryMark] in front.
class CategoryTitle extends StatelessWidget {
  final String text;
  final int? locationTypeId;
  final TextStyle? style;

  const CategoryTitle(
    this.text, {
    super.key,
    required this.locationTypeId,
    this.style,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      CategoryMark(locationTypeId: locationTypeId),
      const SizedBox(width: 8),
      Flexible(child: Text(text, style: style)),
    ],
  );
}
