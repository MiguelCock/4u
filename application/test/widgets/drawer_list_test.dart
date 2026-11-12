import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/widgets/drawer_list.dart';

void main() {
  testWidgets('the last item clears the phone\'s buttons and can be tapped', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          // The phone's own home and back buttons, 48 px at the bottom.
          data: const MediaQueryData(
            size: Size(400, 600),
            padding: EdgeInsets.only(bottom: 48),
          ),
          child: Scaffold(
            body: Drawer(
              child: DrawerList(
                children: [
                  for (var i = 0; i < 20; i++) ListTile(title: Text('Item $i')),
                  ListTile(
                    title: const Text('Test as user'),
                    onTap: () => tapped = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('Test as user'), 200);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final bottom = tester.getBottomLeft(find.text('Test as user')).dy;
    expect(bottom, lessThanOrEqualTo(600 - 48));
    await tester.tap(find.text('Test as user'));
    expect(tapped, isTrue);
  });
}
