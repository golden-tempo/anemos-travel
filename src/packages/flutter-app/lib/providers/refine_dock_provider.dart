import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/spacing.dart';

/// How wide the trip page's docked refine chat is — the geometry contract and
/// the traveler's saved choice, in one place.
///
/// The dock used to be a `SizedBox(width: 400)` written at the call site, with
/// `constraints.maxWidth - 401` written a thousand lines above it as the
/// itinerary's share. Two spellings of one number is exactly the shape that
/// goes stale, and neither could move without the other. Everything that needs
/// to know how wide the dock is now asks [clampRefineDockWidth].
///
/// **Two widths, deliberately.** [refineDockWidthProvider] holds what the
/// traveler dragged to and what persists; [clampRefineDockWidth] answers what a
/// given window can actually give them. Keeping the preference un-narrowed by a
/// small window is the point — shrinking the browser and growing it back must
/// not silently rewrite the choice.

/// Body width at or above which the chat docks beside the itinerary instead of
/// opening as a bottom sheet. Unchanged; it just lives here now, beside the
/// floor it implies.
const double kRefineDockBreakpoint = 900;

/// Where the dock opens before anyone drags it.
///
/// Was 400, which put a bubble at 312 — `ChatPanel` spans 78% of its host — so
/// the assistant's bulleted answers wrapped every four or five words on the one
/// surface the whole refine feature lives on. 480 buys a 374px bubble while
/// still clearing [kRefineDockMinBodyWidth] on every window that docks the
/// panel at all, so no layout that worked before gets narrower than it was.
const double kRefineDockDefaultWidth = 480;

/// Narrowest the dock goes.
///
/// The same `ChatPanel` already renders at this width full-screen on a 375pt
/// phone, so its header buttons, composer and quick-reply chips are known to
/// survive it — a width the panel has shipped at rather than a guess.
const double kRefineDockMinWidth = 360;

/// Widest the dock goes on any window.
///
/// At 78% this puts a bubble at 562px, around 75 characters of Inter at body
/// size — the top of a comfortable measure. Past it the transcript stops
/// gaining line length (bubbles cap at 720 and the extra becomes gutter) while
/// the itinerary keeps paying for it, so there is nothing left to buy.
const double kRefineDockMaxWidth = 720;

/// What the itinerary keeps no matter how far the dock is dragged.
///
/// Not a new number: the dock only appears from [kRefineDockBreakpoint] of body
/// width, and at 900 the old fixed 400px dock plus its 1px divider left the
/// trip exactly 499. Stating that floor rather than inventing one means the
/// widest allowed dock can never squeeze the itinerary harder than the layout
/// already did at its own threshold.
const double kRefineDockMinBodyWidth = 500;

/// The grab strip between the itinerary and the dock.
///
/// A hairline is not a pointer target, so the seam gets a real box and the
/// hairline is drawn centred inside it — the divider looks exactly as it did,
/// it is just finally hittable. Part of the geometry because the itinerary's
/// share is `layoutWidth - dockWidth - kRefineDockHandleWidth`.
const double kRefineDockHandleWidth = AppSpacing.sm;

/// The dock's real width inside a row [layoutWidth] wide, given a [preferred]
/// one.
///
/// The ONE clamp — the layout, the drag and the keyboard step all read it, so
/// a width that renders is always a width you can drag back from. The ceiling
/// never falls below [kRefineDockMinWidth]: a window too narrow to grant the
/// itinerary its floor still has to draw a usable chat, and whether the dock
/// appears at all is [kRefineDockBreakpoint]'s question, not this one's.
double clampRefineDockWidth(double preferred, {required double layoutWidth}) {
  final ceiling = max(
    kRefineDockMinWidth,
    min(
      kRefineDockMaxWidth,
      layoutWidth - kRefineDockMinBodyWidth - kRefineDockHandleWidth,
    ),
  );
  return preferred.clamp(kRefineDockMinWidth, ceiling);
}

/// Storage key for the dragged width. Device-wide rather than per-trip: this is
/// how someone likes their window split, not something about one trip — the
/// same reason the theme and the locale are stored device-wide.
const String refineDockWidthKey = 'refine_dock_width';

class RefineDockWidthNotifier extends StateNotifier<double> {
  // Render at the default immediately; the stored width arrives a frame or two
  // later and only redraws if it differs.
  RefineDockWidthNotifier() : super(kRefineDockDefaultWidth);

  /// Reads the stored width. Called once, when the provider is first read.
  Future<void> load() async {
    double? stored;
    try {
      final prefs = await SharedPreferences.getInstance();
      stored = prefs.getDouble(refineDockWidthKey);
    } catch (_) {
      // Storage unavailable (private browsing, first run) — the default holds
      // for this session.
    }
    // A width written by a build with different limits, or hand-edited
    // storage, is folded into today's range rather than trusted: nothing about
    // this value is worth a broken layout.
    if (stored == null || !stored.isFinite) return;
    state = stored.clamp(kRefineDockMinWidth, kRefineDockMaxWidth);
  }

  /// The live drag, and every keyboard step. State only — a drag emits a value
  /// per frame, and on web `SharedPreferences` is a synchronous localStorage
  /// write, so persistence waits for [save].
  void resize(double width) {
    if (!width.isFinite) return;
    state = width.clamp(kRefineDockMinWidth, kRefineDockMaxWidth);
  }

  /// Records where the drag landed. Best-effort: the width already applies
  /// either way, so a failed write costs the next session, not this one.
  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(refineDockWidthKey, state);
    } catch (_) {
      // The width still applies for this session.
    }
  }

  /// Double-click on the seam: back to [kRefineDockDefaultWidth]. Stored, so
  /// "put it back" survives a reload the same way a drag does.
  Future<void> reset() async {
    resize(kRefineDockDefaultWidth);
    await save();
  }
}

final refineDockWidthProvider =
    StateNotifierProvider<RefineDockWidthNotifier, double>(
        (ref) => RefineDockWidthNotifier()..load());
