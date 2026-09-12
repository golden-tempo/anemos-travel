import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'install_prompt_types.dart';

/// Web implementation of the PWA custom install prompt
/// (docs/pwa-status.md action item #1): reads the `beforeinstallprompt` event
/// that web/index.html's inline script captures — the browser fires it at
/// most once per page load, well before this Dart code could ever attach a
/// listener directly, so the page-level shim is the only way to hold onto it
/// for a deliberate "Install Anemos" affordance instead of leaving install
/// entirely to the browser's own menu item.
///
/// `dart:js_interop_unsafe`'s [JSObject.callMethod] (rather than a `@JS()`
/// binding) is deliberate: `window.__anemosInstallAvailable` /
/// `window.__anemosInstallPrompt` are plain functions stashed by index.html,
/// not a typed Web IDL surface `package:web` knows about.
bool isInstallPromptAvailable() {
  try {
    return web.window.callMethod<JSBoolean>('__anemosInstallAvailable'.toJS)
        .toDart;
  } catch (_) {
    return false;
  }
}

/// Calls back whenever availability may have changed — a fresh
/// `beforeinstallprompt` capture, or the app just got installed and the
/// stash was cleared. Returns a function that removes both listeners.
void Function() onInstallAvailabilityChanged(void Function() callback) {
  final handler = ((web.Event _) => callback()).toJS;
  web.window.addEventListener('anemos-install-available', handler);
  web.window.addEventListener('anemos-install-consumed', handler);
  return () {
    web.window.removeEventListener('anemos-install-available', handler);
    web.window.removeEventListener('anemos-install-consumed', handler);
  };
}

/// Shows the browser's install dialog using the stashed event, if there is
/// one. The stash is consumed either way (the browser only lets an event be
/// used once), so a dismissed prompt does not show again until the next
/// `beforeinstallprompt` fire — the same one-shot behavior the native browser
/// affordance has.
Future<InstallPromptOutcome> showInstallPrompt() async {
  try {
    final promise =
        web.window.callMethod<JSPromise<JSString>>('__anemosInstallPrompt'.toJS);
    final outcome = (await promise.toDart).toDart;
    return switch (outcome) {
      'accepted' => InstallPromptOutcome.accepted,
      'dismissed' => InstallPromptOutcome.dismissed,
      _ => InstallPromptOutcome.unavailable,
    };
  } catch (_) {
    return InstallPromptOutcome.unavailable;
  }
}
