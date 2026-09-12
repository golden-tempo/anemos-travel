import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/utils/install_prompt_stub.dart';
import 'package:travel_route_planner/utils/install_prompt_types.dart';

/// VM widget tests always resolve the conditional import
/// (install_prompt_stub.dart / install_prompt_web.dart) to the stub — this
/// pins its contract so account_settings_screen.dart's "Install Anemos" row
/// stays hidden by default (settings_polish_test.dart /
/// account_settings_harness.dart exercise the rest of that screen without
/// ever seeing this row).
void main() {
  group('install prompt (non-web stub)', () {
    test('never available', () {
      expect(isInstallPromptAvailable(), isFalse);
    });

    test('showInstallPrompt resolves to unavailable', () async {
      expect(await showInstallPrompt(), InstallPromptOutcome.unavailable);
    });

    test('availability listener is a harmless, callable no-op', () {
      var called = false;
      final remove = onInstallAvailabilityChanged(() => called = true);
      remove();
      expect(called, isFalse);
    });
  });
}
