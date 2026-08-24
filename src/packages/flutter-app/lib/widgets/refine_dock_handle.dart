import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../providers/refine_dock_provider.dart';

/// How far one arrow-key press moves the seam. A spacing-ladder step, so a
/// keyboard user lands on the same round widths a dragging one does.
const double _kKeyStep = 16;

/// The seam between the itinerary and the docked refine chat, made draggable.
///
/// It draws what has always been here — a hairline in the divider colour —
/// inside a box wide enough to hit, and thickens to the primary while it is
/// hovered, focused or dragged. Nothing it does is destructive or asynchronous,
/// so the whole interaction is direct: drag it, arrow-key it, or double-click
/// to put it back.
///
/// The width itself lives in [refineDockWidthProvider]; this widget only
/// reports where the seam went. That split is what lets the host screen apply
/// one width to both the dock and the itinerary's gutter in the same frame.
class RefineDockHandle extends StatefulWidget {
  /// The dock's width right now. The drag anchors to it, so the hairline
  /// tracks the pointer instead of drifting once a clamp bites.
  final double dockWidth;

  /// Width of the row the itinerary and the dock share — [clampRefineDockWidth]'s
  /// other input, so this widget and the layout agree on the limits by reading
  /// the same function rather than by two copies of the arithmetic.
  final double layoutWidth;

  /// Per drag frame, and per arrow-key press.
  final ValueChanged<double> onChanged;

  /// Where it came to rest — the only moment worth a storage write.
  final ValueChanged<double> onChangeEnd;

  /// Double-click, or Home: back to [kRefineDockDefaultWidth].
  final VoidCallback onReset;

  const RefineDockHandle({
    super.key,
    required this.dockWidth,
    required this.layoutWidth,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onReset,
  });

  @override
  State<RefineDockHandle> createState() => _RefineDockHandleState();
}

class _RefineDockHandleState extends State<RefineDockHandle> {
  bool _hovered = false;
  bool _focused = false;
  bool _dragging = false;

  /// Anchor for the in-flight drag: the pointer's start x and the width it
  /// started from. Recomputing from these rather than accumulating per-frame
  /// deltas is what makes a drag past the limit and back re-attach to the
  /// pointer instead of jumping.
  double _dragStartX = 0;
  double _dragStartWidth = 0;

  /// The last width handed to [RefineDockHandle.onChanged]. `widget.dockWidth`
  /// only catches up on the next build, so a drag that ends in the same event
  /// batch as its last move would otherwise report — and persist — the
  /// second-to-last width.
  double? _emitted;

  /// The dock sits at the row's end, so moving the seam towards the row's
  /// start widens it. In RTL the row flips and so does that.
  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  /// Where the seam is right now, newest answer first.
  double get _current => _emitted ?? widget.dockWidth;

  void _emit(double width) {
    _emitted = width;
    widget.onChanged(width);
  }

  double _clamped(double width) =>
      clampRefineDockWidth(width, layoutWidth: widget.layoutWidth);

  void _onDragStart(DragStartDetails details) {
    setState(() => _dragging = true);
    _dragStartX = details.globalPosition.dx;
    _dragStartWidth = widget.dockWidth;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final travelled = _dragStartX - details.globalPosition.dx;
    _emit(_clamped(_dragStartWidth + (_rtl ? -travelled : travelled)));
  }

  void _onDragEnd() {
    setState(() => _dragging = false);
    widget.onChangeEnd(_current);
    _emitted = null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final towardsStart = key == LogicalKeyboardKey.arrowLeft;
    final towardsEnd = key == LogicalKeyboardKey.arrowRight;

    if (event is KeyUpEvent) {
      // The release is the "landed" moment, so held arrows cost one write
      // rather than one per repeat.
      if (!towardsStart && !towardsEnd) return KeyEventResult.ignored;
      widget.onChangeEnd(_current);
      _emitted = null;
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _emitted = null;
      widget.onReset();
      return KeyEventResult.handled;
    }
    if (!towardsStart && !towardsEnd) return KeyEventResult.ignored;
    final widen = _rtl ? towardsEnd : towardsStart;
    _emit(_clamped(_current + (widen ? _kKeyStep : -_kKeyStep)));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final active = _hovered || _focused || _dragging;

    return Semantics(
      label: l10n.refineDockResize,
      value: l10n.refineDockResizeValue(widget.dockWidth.round()),
      slider: true,
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            // The hairline paints 1px of an 8px box; without this the other
            // 7 aren't a target and the seam stays as ungrabbable as it was.
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: (_) => _onDragEnd(),
            onHorizontalDragCancel: _onDragEnd,
            onDoubleTap: widget.onReset,
            child: Tooltip(
              message: l10n.refineDockResizeHint,
              // Long enough that crossing the seam on the way to the chat
              // doesn't summon it; this is discoverability, not a label.
              waitDuration: const Duration(milliseconds: 600),
              child: SizedBox(
                width: kRefineDockHandleWidth,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: active ? 2 : 1,
                    height: double.infinity,
                    color: active
                        ? theme.colorScheme.primary
                        : theme.dividerColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
