import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/l10n/app_localizations_en.dart';

import 'support/account_settings_harness.dart';

/// docs/pwa-status.md action item #1: the "Install Anemos" row only renders
/// once the browser has actually captured `beforeinstallprompt` — VM widget
/// tests always resolve to the non-web stub (see install_prompt_test.dart),
/// so this pins the "never shown when unavailable" half of that contract on
/// the real settings screen (there is no VM-testable way to exercise the
/// available branch, which lives entirely behind the web conditional
/// import).
void main() {
  testWidgets('install row is absent when no install prompt is available',
      (tester) async {
    await pumpAccountSettings(tester, user: testUser());

    final l10n = AppLocalizationsEn();
    expect(find.text(l10n.settingsInstallSection), findsNothing);
    expect(find.text(l10n.settingsInstallAction), findsNothing);
  });
}
