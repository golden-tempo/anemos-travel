import 'package:flutter/material.dart';

/// Category glyphs in one place — the icon sibling of AppColors.forCategory:
/// one mapping from a place's canonical category (API values, never
/// translated) to the glyph every surface wears for it, so the itinerary
/// rows' spine markers and the map's pins cannot drift apart.
abstract final class AppIcons {
  /// Glyph for an itinerary place by its category. Null means "no glyph" —
  /// deliberate, not a missing fallback: the itinerary spine then shows the
  /// stop's number-in-day and the map pin stays a plain tinted dot.
  static IconData? forCategory(String? category) => switch (category) {
        'restaurant' => Icons.restaurant,
        'attraction' => Icons.attractions,
        _ => null,
      };
}
