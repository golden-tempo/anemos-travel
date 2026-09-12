import 'install_prompt_types.dart';

/// Non-web stub for the custom install prompt: `beforeinstallprompt` is a
/// browser-only event (web/index.html captures it), so native builds — and
/// VM widget tests, which resolve to this stub — never have one to show.
/// See install_prompt_web.dart for the real implementation and the contract.
bool isInstallPromptAvailable() => false;

/// No-op on non-web: availability can never change from "never available".
/// Returns a no-op unsubscribe function, matching the web implementation's
/// signature.
void Function() onInstallAvailabilityChanged(void Function() callback) {
  return () {};
}

Future<InstallPromptOutcome> showInstallPrompt() async =>
    InstallPromptOutcome.unavailable;
