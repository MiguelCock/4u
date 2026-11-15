import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/trip_words.dart';
import 'package:eyes4u/services/turn_guidance.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('es'));

  test('turns in words, never degrees', () {
    expect(turnWords(l10n, TurnCue.from(90)), l10n.navTurnRightShort);
    expect(turnWords(l10n, TurnCue.from(-90)), l10n.navTurnLeftShort);
    expect(turnWords(l10n, TurnCue.from(40)), l10n.navTurnSlightRight);
    expect(turnWords(l10n, TurnCue.from(-40)), l10n.navTurnSlightLeft);
    expect(turnWords(l10n, TurnCue.from(170)), l10n.navTurnAround);
  });

  test('a leg: the turn and the steps', () {
    expect(legWords(l10n, TurnCue.from(90), 12), l10n.navLegRight(12));
    expect(legWords(l10n, TurnCue.from(-40), 12), l10n.navLegSlightLeft(12));
    expect(legWords(l10n, TurnCue.from(170), 12), l10n.navLegAround(12));
  });

  test('hazards', () {
    expect(hazardLabel(l10n, kElevatorType), l10n.navHazardElevator);
    expect(hazardLabel(l10n, kRampType), l10n.navHazardRamp);
    expect(hazardLabel(l10n, 4), l10n.navHazardStairs);
  });

  test('a floor change: the elevator wins, then the ramp, then stairs', () {
    String say(Set<int?> types, {bool up = true}) =>
        floorChangeAction(l10n, types: types, up: up, floor: 2);
    expect(say({kElevatorType, 4}), l10n.navFloorElevator(2));
    expect(say({kRampType, null}), l10n.navFloorUpRamp(2));
    expect(say({4, null}, up: false), l10n.navFloorDownStairs(2));
    expect(say({null}), l10n.navFloorUp(2));
  });
}
