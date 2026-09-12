import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/utils/share_target.dart';

/// manifest.json's `share_target` (docs/pwa-status.md action item #4) lands
/// the OS share sheet on /import as `?title=&text=&url=`; import_trip_screen
/// reads it through [sharedTextFromCurrentUrl], which is only exercised on
/// web (kIsWeb is false in these VM tests) — so the pure parser is what's
/// under test here.
void main() {
  group('sharedTextFromUri', () {
    test('no share params is null', () {
      expect(sharedTextFromUri(Uri.parse('https://anemos.travel/app/import')),
          isNull);
    });

    test('text alone', () {
      expect(
        sharedTextFromUri(Uri.parse(
            'https://anemos.travel/app/import?text=Paris%2C+then+Rome')),
        'Paris, then Rome',
      );
    });

    test('title, text and url are joined in that order', () {
      expect(
        sharedTextFromUri(Uri.parse(
            'https://anemos.travel/app/import?title=My+trip&text=Day+1%3A+Paris&url=https%3A%2F%2Fchat.example%2Fabc')),
        'My trip\nDay 1: Paris\nhttps://chat.example/abc',
      );
    });

    test('blank/whitespace-only params are dropped', () {
      expect(
        sharedTextFromUri(
            Uri.parse('https://anemos.travel/app/import?title=&text=+&url=')),
        isNull,
      );
    });

    test('unrelated query params are ignored', () {
      expect(
        sharedTextFromUri(Uri.parse(
            'https://anemos.travel/app/import?utm_source=share&text=hi')),
        'hi',
      );
    });
  });

  group('sharedTextFromCurrentUrl', () {
    test('null off web (VM tests: kIsWeb is false)', () {
      expect(sharedTextFromCurrentUrl(), isNull);
    });
  });
}
