import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/traveler_preferences.dart';
import 'package:travel_route_planner/providers/preferences_provider.dart';
import 'package:travel_route_planner/screens/preferences_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/preferences_api_service.dart';

import 'support/l10n_test_app.dart';

/// specs/entry-requirements (00081/#686) — the Travel profile's new storage
/// fields for the traveler's passport and residence country. Storage only:
/// no advice is derived from these yet, so these tests pin presence, seeding
/// and the save round-trip, not any text a later provider feature would add.
///
/// Per CLAUDE.md: the test font is a stand-in, so no assertion here depends
/// on rendered text size, width, or wrap.
class _FakePrefsApi implements PreferencesApiService {
  TravelerPreferences prefs;
  String? savedPassportCountry;
  String? savedResidenceCountry;
  int saveCalls = 0;

  _FakePrefsApi({this.prefs = const TravelerPreferences()});

  @override
  ApiClient get apiClient => throw UnsupportedError('unused in tests');

  @override
  Future<TravelerPreferences> getPreferences() async => prefs;

  @override
  Future<TravelerPreferences> savePreferences({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
    String? fitnessRoutine,
    String? outdoorIntensity,
    List<String>? companions,
    String? baggage,
    String? gender,
    String? passportCountry,
    String? residenceCountry,
  }) async {
    saveCalls++;
    savedPassportCountry = passportCountry;
    savedResidenceCountry = residenceCountry;
    return prefs;
  }
}

Future<void> _pump(WidgetTester tester, _FakePrefsApi api) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [preferencesApiServiceProvider.overrideWithValue(api)],
    child: localizedTestApp(home: const PreferencesScreen()),
  ));
  await tester.pumpAndSettle();
}

/// Both country fields share the same hint ("e.g. US") and nothing else on
/// the page does, so this finder is unambiguous without reaching into the
/// screen's private row widget.
final _countryFields = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == 'e.g. US',
);

void main() {
  group('travel profile: entry requirements', () {
    testWidgets('renders the passport and residence country fields',
        (tester) async {
      await _pump(tester, _FakePrefsApi());

      expect(find.text('Entry requirements'), findsOneWidget);
      expect(find.text('Passport country'), findsOneWidget);
      expect(find.text('Country of residence'), findsOneWidget);
      expect(_countryFields, findsNWidgets(2));
    });

    testWidgets('seeds both fields from the loaded profile', (tester) async {
      await _pump(
        tester,
        _FakePrefsApi(
          prefs: const TravelerPreferences(
            passportCountry: 'US',
            residenceCountry: 'DE',
          ),
        ),
      );

      final texts = tester
          .widgetList<TextField>(_countryFields)
          .map((f) => f.controller?.text)
          .toList();
      expect(texts, ['US', 'DE']);
    });

    testWidgets('an unset profile leaves both fields empty', (tester) async {
      await _pump(tester, _FakePrefsApi());

      final texts = tester
          .widgetList<TextField>(_countryFields)
          .map((f) => f.controller?.text)
          .toList();
      expect(texts, ['', '']);
    });

    // Document order puts passport country before residence country — the
    // field order the Travel profile screen renders them in.
    testWidgets('typed values are sent to save', (tester) async {
      final api = _FakePrefsApi();
      await _pump(tester, api);

      final passportField = _countryFields.at(0);
      final residenceField = _countryFields.at(1);
      await tester.ensureVisible(passportField);
      await tester.enterText(passportField, 'ca');
      await tester.ensureVisible(residenceField);
      await tester.enterText(residenceField, 'mx');

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(api.saveCalls, 1);
      expect(api.savedPassportCountry, 'ca');
      expect(api.savedResidenceCountry, 'mx');
    });
  });
}
