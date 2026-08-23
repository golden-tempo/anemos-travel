import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The traveler's explicit choice about the trip map's home-airport overlay
/// (the flight_takeoff pin plus its dashed journey legs): true = show,
/// false = hide, null = no choice made this session. Every surface resolves
/// the null through [homeOverlayVisible] to OFF: the hop home is context,
/// not the trip, so the destinations own the frame — on the inline
/// trip-detail card and the full-screen map alike — until the traveler asks
/// otherwise.
///
/// App-wide rather than per-trip: this is a framing preference ("do I want
/// the hop home in frame"), not trip data — the same scope as
/// themeModeProvider, and the scope a stored device key would have. A
/// provider rather than widget state so the inline card and the full-screen
/// map read ONE choice live in both directions, and so tests can drive it
/// directly (the rickRollProvider rationale).
///
/// Session-only, like dailySpendSettingsProvider: the choice resets on
/// restart so the off default re-asserts. To persist instead, follow the
/// theme_mode_provider pattern — a load() plus a best-effort
/// shared_preferences write in [HomeOverlayChoiceNotifier.setShown]; the
/// call sites would not change.
class HomeOverlayChoiceNotifier extends StateNotifier<bool?> {
  HomeOverlayChoiceNotifier() : super(null);

  /// Records an explicit choice (a toggle tap passes the inverse of the
  /// visibility it was displaying).
  void setShown(bool shown) => state = shown;
}

final homeOverlayChoiceProvider =
    StateNotifierProvider<HomeOverlayChoiceNotifier, bool?>(
        (ref) => HomeOverlayChoiceNotifier());

/// Effective home-overlay visibility: the explicit [choice] when one has
/// been made, else hidden. The default is the absence of a choice: null is
/// never written back as a decision.
bool homeOverlayVisible({required bool? choice}) => choice ?? false;
