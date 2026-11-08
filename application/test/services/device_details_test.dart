import 'package:eyes4u/services/device_details.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('androidDetails keeps the fields the trip report shows', () {
    expect(
      androidDetails({
        'manufacturer': 'samsung',
        'model': 'SM-A245M',
        'version': {'release': '14', 'sdkInt': 34, 'codename': 'REL'},
        'fingerprint': 'not wanted',
      }),
      {
        'manufacturer': 'samsung',
        'model': 'SM-A245M',
        'os_version': '14',
        'sdk': 34,
      },
    );
  });

  test('androidDetails leaves out what the phone did not say', () {
    expect(androidDetails({'model': 'X'}), {'model': 'X'});
  });

  test('deviceDetails never throws, even with no platform plugin', () async {
    final details = await deviceDetails();
    expect(details['platform'], isA<String>());
  });
}
