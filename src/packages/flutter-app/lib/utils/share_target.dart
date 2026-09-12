import 'package:flutter/foundation.dart';

/// Web share-target landing (manifest.json `share_target`,
/// docs/pwa-status.md action item #4): once Anemos is installed, the OS
/// share sheet offers it as a target for a URL or selected text, and lands
/// here as `?title=&text=&url=` query parameters (the Web Share Target API).
///
/// Reads straight off the current URL rather than threading through the nav
/// grammar in navigation/app_routes.dart — [parseBootTarget] deliberately
/// ignores query strings and fragments, and that stays true; this is a
/// one-time prefill for the import screen's paste box, not a routing change.
///
/// Any of the three fields may be present depending on what was shared
/// (sharing a page usually fills `url` and/or `title`; sharing selected text
/// fills `text`); present ones are joined so nothing shared is dropped.
String? sharedTextFromUri(Uri uri) {
  final parts = [
    uri.queryParameters['title'],
    uri.queryParameters['text'],
    uri.queryParameters['url'],
  ].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
  if (parts.isEmpty) return null;
  return parts.join('\n');
}

/// [sharedTextFromUri] against the browser's current URL. Null off web —
/// `Uri.base` there reflects the process's working directory, never a
/// share-target query — so native builds never see a spurious prefill.
String? sharedTextFromCurrentUrl() {
  if (!kIsWeb) return null;
  return sharedTextFromUri(Uri.base);
}
