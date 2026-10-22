import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// AdminHomeScreen's layout: a RefreshIndicator around a TabBarView whose
/// tabs hold vertical lists. The lists' scroll notifications arrive at
/// depth 1 (the TabBarView is a horizontal pager), so the indicator needs
/// a predicate that accepts them.
Widget _tabbedLists({
  required Future<void> Function() onRefresh,
  ScrollNotificationPredicate? predicate,
}) {
  return MaterialApp(
    home: DefaultTabController(
      length: 2,
      child: Scaffold(
        body: RefreshIndicator(
          onRefresh: onRefresh,
          notificationPredicate:
              predicate ?? defaultScrollNotificationPredicate,
          child: TabBarView(
            children: [
              for (var tab = 0; tab < 2; tab++)
                ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    for (var i = 0; i < 3; i++) ListTile(title: Text('Row $i')),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the default predicate never refreshes lists inside tabs', (
    tester,
  ) async {
    var refreshed = false;
    await tester.pumpWidget(
      _tabbedLists(onRefresh: () async => refreshed = true),
    );
    await tester.fling(find.text('Row 0'), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(refreshed, isFalse);
  });

  testWidgets('accepting vertical notifications makes pulling refresh', (
    tester,
  ) async {
    var refreshed = false;
    await tester.pumpWidget(
      _tabbedLists(
        onRefresh: () async => refreshed = true,
        predicate: (n) => n.metrics.axis == Axis.vertical,
      ),
    );
    await tester.fling(find.text('Row 0'), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();
    expect(refreshed, isTrue);
  });
}
