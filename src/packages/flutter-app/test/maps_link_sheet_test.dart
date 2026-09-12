import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/widgets/maps_link_sheet.dart';

import 'support/l10n_test_app.dart';

/// Captures launched URLs and the requested web window target, instead of
/// hitting a real platform.
class _FakeUrlLauncher extends UrlLauncherPlatform {
  final launched = <String>[];
  final windowNames = <String?>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    windowNames.add(options.webOnlyWindowName);
    return true;
  }
}

/// No-op analytics so tracked_launch's fire-and-forget record never touches
/// the network in the test env.
class _NoopAnalytics extends AnalyticsApiService {
  _NoopAnalytics() : super(ApiClient(baseUrl: 'http://test/api/v1'));

  @override
  Future<void> recordBookingLinkClicked({
    String? tripId,
    String? todoKey,
    String? provider,
    String? surface,
    String? kind,
  }) =>
      Future.value();
}

void main() {
  late _FakeUrlLauncher launcher;

  setUp(() {
    launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  Widget harness() {
    return ProviderScope(
      overrides: [
        analyticsApiServiceProvider.overrideWithValue(_NoopAnalytics()),
      ],
      child: localizedTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showMapsLinkSheet(
                context,
                name: 'Acropolis',
                placeId: 'place-123',
                surface: 'chat_place_card',
              ),
              child: const Text('Get directions'),
            ),
          ),
        ),
      ),
    );
  }

  // Both options launch same-tab on web: a "get directions" tap is a quick
  // errand, not a booking handoff, so it shouldn't leave a second (often
  // blank, once Maps hands off to a native app) tab behind.
  testWidgets('Google Maps option launches same-tab', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('Get directions'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Google Maps'));
    await tester.pumpAndSettle();

    expect(launcher.launched, hasLength(1));
    expect(launcher.launched.single, contains('google.com/maps'));
    expect(launcher.windowNames, ['_self']);
  });

  testWidgets('Apple Maps option launches same-tab', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('Get directions'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Apple Maps'));
    await tester.pumpAndSettle();

    expect(launcher.launched, hasLength(1));
    expect(launcher.launched.single, contains('maps.apple.com'));
    expect(launcher.windowNames, ['_self']);
  });
}
