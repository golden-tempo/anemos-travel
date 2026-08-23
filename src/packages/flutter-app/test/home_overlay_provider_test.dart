import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/home_overlay_provider.dart';

void main() {
  test('no choice: hidden, on every surface', () {
    expect(homeOverlayVisible(choice: null), isFalse);
  });

  test('an explicit choice wins both ways', () {
    expect(homeOverlayVisible(choice: true), isTrue);
    expect(homeOverlayVisible(choice: false), isFalse);
  });

  test('the provider starts with no choice and records setShown', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(homeOverlayChoiceProvider), isNull);

    container.read(homeOverlayChoiceProvider.notifier).setShown(false);
    expect(container.read(homeOverlayChoiceProvider), isFalse);

    container.read(homeOverlayChoiceProvider.notifier).setShown(true);
    expect(container.read(homeOverlayChoiceProvider), isTrue);
  });
}
