import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/widgets/admin_guide.dart';

void main() {
  final base = Uri.parse('https://example.org/admin/#/');

  test('the guide sits next to the web app, in the app language', () {
    expect(
      adminGuideUrl(base, 'es').toString(),
      'https://example.org/admin/guide/es/',
    );
    expect(
      adminGuideUrl(base, 'en').toString(),
      'https://example.org/admin/guide/en/',
    );
  });

  test('another language gets the English guide', () {
    expect(adminGuideUrl(base, 'fr').path, '/admin/guide/en/');
  });

  test('a section is an anchor in the page', () {
    expect(
      adminGuideUrl(base, 'es', section: 'connections').toString(),
      'https://example.org/admin/guide/es/#connections',
    );
  });
}
