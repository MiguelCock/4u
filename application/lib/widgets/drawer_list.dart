import 'package:flutter/material.dart';

/// A menu's list that ends clear of the phone's own home and back buttons:
/// with no bottom padding, the admin menu's last item (Test as user) sat
/// under them and couldn't be tapped (#250).
class DrawerList extends StatelessWidget {
  final List<Widget> children;

  const DrawerList({super.key, required this.children});

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
    children: children,
  );
}
