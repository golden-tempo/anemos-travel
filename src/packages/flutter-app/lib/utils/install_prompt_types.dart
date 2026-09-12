/// Shared types for the PWA custom install prompt, imported by both
/// install_prompt_stub.dart and install_prompt_web.dart (and by callers) so
/// the conditional import only swaps the implementation, never the contract.
library;

/// What happened when [showInstallPrompt] (install_prompt_web.dart /
/// install_prompt_stub.dart) was called.
enum InstallPromptOutcome {
  /// The user accepted the browser's install dialog.
  accepted,

  /// The user dismissed the browser's install dialog.
  dismissed,

  /// There was nothing to prompt: non-web build, browser without
  /// `beforeinstallprompt` (e.g. iOS Safari, or the page hasn't received one
  /// yet), or the app is already installed.
  unavailable,
}
