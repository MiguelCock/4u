import 'package:eyes4u/services/buzz.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('without a vibrator it falls back to haptic feedback', () async {
    final calls = <String?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add('${call.method}:${call.arguments}');
          return null;
        });
    await buzz(Buzz.long, hasVibrator: () async => false);
    await buzz(Buzz.short, hasVibrator: () async => false);
    expect(calls, [
      'HapticFeedback.vibrate:HapticFeedbackType.heavyImpact',
      'HapticFeedback.vibrate:HapticFeedbackType.mediumImpact',
    ]);
  });

  test('a long buzz is clearly longer than a short one', () {
    expect(buzzMillis[Buzz.long]! >= 3 * buzzMillis[Buzz.short]!, isTrue);
  });
}
