import '../l10n/app_localizations.dart';
import 'turn_guidance.dart';

/// What a trip says, in words (Phase C). A turn is never in degrees: it's
/// slight (≤ 60°), normal or around (> 150°).

/// "Turn right", "turn slightly left", "turn around".
String turnWords(AppLocalizations l10n, TurnCue cue) => switch (cue) {
  TurnCue(turnAround: true) => l10n.navTurnAround,
  TurnCue(kind: TurnKind.slight, right: true) => l10n.navTurnSlightRight,
  TurnCue(kind: TurnKind.slight) => l10n.navTurnSlightLeft,
  TurnCue(right: true) => l10n.navTurnRightShort,
  TurnCue() => l10n.navTurnLeftShort,
};

/// "Turn right and walk about N steps", for a leg of [steps].
String legWords(AppLocalizations l10n, TurnCue cue, int steps) => switch (cue) {
  TurnCue(turnAround: true) => l10n.navLegAround(steps),
  TurnCue(kind: TurnKind.slight, right: true) => l10n.navLegSlightRight(steps),
  TurnCue(kind: TurnKind.slight) => l10n.navLegSlightLeft(steps),
  TurnCue(right: true) => l10n.navLegRight(steps),
  TurnCue() => l10n.navLegLeft(steps),
};

/// Location type ids (db_schema/location_type.sql) that change how a floor
/// change and a hazard are said. An elevator wins when the two ends of a
/// floor change differ, like the backend's route cost.
const int kElevatorType = 3;
const int kRampType = 11;

/// "Stairs", "elevator" or "ramp", for a warning ahead.
String hazardLabel(AppLocalizations l10n, int type) => switch (type) {
  kElevatorType => l10n.navHazardElevator,
  kRampType => l10n.navHazardRamp,
  _ => l10n.navHazardStairs,
};

/// How to get to [floor] (1-based, as said): by the elevator or the ramp
/// when either end is one ([types]), by the stairs for any other hazard,
/// else just up or down.
String floorChangeAction(
  AppLocalizations l10n, {
  required Set<int?> types,
  required bool up,
  required int floor,
}) {
  if (types.contains(kElevatorType)) return l10n.navFloorElevator(floor);
  if (types.contains(kRampType)) {
    return up ? l10n.navFloorUpRamp(floor) : l10n.navFloorDownRamp(floor);
  }
  if (types.any((t) => t != null)) {
    return up ? l10n.navFloorUpStairs(floor) : l10n.navFloorDownStairs(floor);
  }
  return up ? l10n.navFloorUp(floor) : l10n.navFloorDown(floor);
}
