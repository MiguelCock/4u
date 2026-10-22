import 'package:flutter/material.dart';

/// A centred message (empty list, load error) that still scrolls, so a
/// surrounding `RefreshIndicator` can be pulled on it - a plain `Center`
/// can't be, which left pull-to-refresh dead exactly when a reload was
/// most needed.
class ScrollableMessage extends StatelessWidget {
  final String text;
  final bool liveRegion;

  const ScrollableMessage(this.text, {super.key, this.liveRegion = false});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          child: Semantics(
            liveRegion: liveRegion,
            child: Text(text, textAlign: TextAlign.center),
          ),
        ),
      ],
    );
  }
}
