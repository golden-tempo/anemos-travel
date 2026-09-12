import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';
import '../utils/place_links.dart';
import '../utils/tracked_launch.dart';

/// A place's "get directions" sheet: Google Maps (name + place_id, when the
/// wire result carries one) and Apple Maps (name only — Apple's scheme has no
/// place_id equivalent), each a plain outbound URL so both work offline-queued
/// and for read-only viewers. Same shape as every other "pick one" affordance
/// in this app (trip actions, calendar export) rather than a bespoke menu.
///
/// Shared by every chat photo card (places, local picks, parking) on both
/// hosts — the trip-detail chat tab and the Plan tab both render through the
/// same [PlacePhotoCard] rails.
Future<void> showMapsLinkSheet(
  BuildContext context, {
  required String name,
  required String placeId,
  required String surface,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // Width cap centers the sheet on desktop, matching the other pick-one
    // sheets (trip actions, wear/pack, health).
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetContext) {
      final l10n = sheetContext.l10n;

      Future<void> open(String url, String provider) async {
        Navigator.pop(sheetContext);
        if (!context.mounted) return;
        // Same-tab on web: a "get directions" tap is a quick errand, not a
        // booking handoff, so it shouldn't leave a second (often blank, once
        // Maps hands off to a native app) tab behind — see trackedLaunchUrl.
        await trackedLaunchUrl(context, url,
            provider: provider, surface: surface, webOnlyWindowName: '_self');
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.chatCardGetDirections,
                  style: Theme.of(sheetContext).textTheme.titleSmall,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: Text(l10n.chatCardOpenInGoogleMaps),
              onTap: () =>
                  open(googleMapsSearchUrl(name, placeId), 'google_maps'),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: Text(l10n.chatCardOpenInAppleMaps),
              onTap: () => open(appleMapsSearchUrl(name), 'apple_maps'),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      );
    },
  );
}
