import 'package:eyes4u/services/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

const _policy = AppVersionPolicy(
  latest: '0.5.3',
  minSupported: '0.5.2',
  downloadUrl: 'https://example.com',
);

void main() {
  test('compareVersions', () {
    expect(compareVersions('0.5.2', '0.5.2'), 0);
    expect(compareVersions('0.5.2+502', '0.5.2'), 0);
    expect(compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    expect(compareVersions('0.5', '0.5.1'), lessThan(0));
  });

  test(
    'the newest is current, the one before deprecated, older unsupported',
    () {
      expect(appVersionStatus('0.5.3', _policy), AppVersionStatus.current);
      expect(appVersionStatus('0.6.0', _policy), AppVersionStatus.current);
      expect(appVersionStatus('0.5.2', _policy), AppVersionStatus.deprecated);
      expect(appVersionStatus('0.5.1', _policy), AppVersionStatus.unsupported);
    },
  );

  test('parses the backend policy', () {
    final policy = AppVersionPolicy.tryParse(
      '{"detail": "update", "latest": "0.5.3", "min_supported": "0.5.2", '
      '"download_url": "https://example.com"}',
    );
    expect(policy?.minSupported, '0.5.2');
    expect(AppVersionPolicy.tryParse('not json'), isNull);
    expect(AppVersionPolicy.tryParse('{"detail": "x"}'), isNull);
  });
}
