import 'package:flutter/material.dart';

/// Room at the end of a list so its last row clears [FabRow] and the phone's
/// own bottom bar: a floating button is 56 px, with 16 px around it.
double fabClearance(BuildContext context) =>
    88 + MediaQuery.paddingOf(context).bottom;

/// Two floating buttons, [left] and [right], at the bottom corners. Goes in
/// `Scaffold.floatingActionButton` with
/// `FloatingActionButtonLocation.centerFloat`. The space between them takes
/// no taps, so the list behind stays usable there.
class FabRow extends StatelessWidget {
  final Widget? left;
  final Widget? right;

  const FabRow({super.key, this.left, this.right});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(children: [?left, const Spacer(), ?right]),
  );
}
