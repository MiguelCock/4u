import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:eyes4u/l10n/app_localizations.dart';
import 'package:eyes4u/services/api_service.dart';
import 'package:eyes4u/widgets/map_conflict.dart';

const _point = {
  'id': 'p1',
  'location_description': 'Front door',
  'status': 'pending',
};

/// Answers the first PATCH with the 409 another admin's change causes, and
/// records every PATCH body.
ApiService _apiWithConflict(List<Map<String, dynamic>> sent) => ApiService(
  'http://gateway.example/map',
  client: MockClient((request) async {
    sent.add(jsonDecode(request.body) as Map<String, dynamic>);
    if (sent.length == 1) {
      return http.Response(
        jsonEncode({
          'detail': {
            'message': 'Another admin changed this point since you opened it.',
            'fields': ['location_description'],
            'current': {..._point, 'location_description': 'Main entrance'},
          },
        }),
        409,
      );
    }
    return http.Response(jsonEncode([_point]), 200);
  }),
  getAccessToken: () => null,
  refreshSession: () async {},
);

Future<bool?> _save(WidgetTester tester, ApiService api) async {
  bool? result;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await saveAnchorPoint(
            context,
            api,
            original: _point,
            changes: {'location_description': 'Door 2'},
            name: 'Front door',
          ),
          child: const Text('save'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('save'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('a conflict shows both versions; keeping theirs saves nothing', (
    tester,
  ) async {
    final sent = <Map<String, dynamic>>[];
    await _save(tester, _apiWithConflict(sent));

    expect(find.text('Another admin changed this point'), findsOneWidget);
    expect(find.textContaining('Main entrance'), findsOneWidget);
    expect(find.textContaining('Door 2'), findsOneWidget);
    expect(sent.single['expected'], {'location_description': 'Front door'});

    await tester.tap(find.text('Keep theirs'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
  });

  testWidgets('saving mine anyway sends it again without the check', (
    tester,
  ) async {
    final sent = <Map<String, dynamic>>[];
    final api = _apiWithConflict(sent);
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await saveAnchorPoint(
              context,
              api,
              original: _point,
              changes: {'location_description': 'Door 2'},
              name: 'Front door',
            ),
            child: const Text('save'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save mine anyway'));
    await tester.pumpAndSettle();

    expect(sent, hasLength(2));
    expect(sent.last, {'location_description': 'Door 2'});
    expect(result, isTrue);
  });

  testWidgets('without a conflict it saves once, with what it was based on', (
    tester,
  ) async {
    final sent = <Map<String, dynamic>>[];
    final api = ApiService(
      'http://gateway.example/map',
      client: MockClient((request) async {
        sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(jsonEncode([_point]), 200);
      }),
      getAccessToken: () => null,
      refreshSession: () async {},
    );
    final result = await _save(tester, api);
    expect(result, isTrue);
    expect(sent.single, {
      'location_description': 'Door 2',
      'expected': {'location_description': 'Front door'},
    });
  });
}
