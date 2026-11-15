import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../services/app_preferences.dart' show voiceGuidanceNotifier;

/// Shows text the app has just said (#257), so that it's heard once.
///
/// With TalkBack off, a SnackBar, for anyone who couldn't hear it. With
/// TalkBack on, nothing: a SnackBar is a live region, and TalkBack read the
/// camera notice again on top of the app's voice, over and over in a user
/// test. With TalkBack on and the app's voice off ([spoken] false), TalkBack
/// says it instead.
void showSpokenNotice(
  BuildContext context,
  String text, {
  bool? spoken,
  Duration duration = const Duration(seconds: 4),
  bool replace = false,
}) {
  if (MediaQuery.accessibleNavigationOf(context)) {
    if (!(spoken ?? voiceGuidanceNotifier.value)) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        text,
        Directionality.of(context),
      );
    }
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  if (replace) messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(duration: duration, content: Text(text)));
}

/// Whether TalkBack (or another screen reader) is on: the app then keeps
/// what it says out of the screen reader's way, see [showSpokenNotice].
bool screenReaderOn(BuildContext context) =>
    MediaQuery.accessibleNavigationOf(context);

/// [child], kept from the screen reader while it's on: for text the app
/// says aloud itself, such as a dialog's body, which TalkBack would
/// otherwise read at the same time.
class SpokenText extends StatelessWidget {
  final Widget child;

  const SpokenText({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      ExcludeSemantics(excluding: screenReaderOn(context), child: child);
}
