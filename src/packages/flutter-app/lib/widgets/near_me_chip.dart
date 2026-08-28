import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'near_me_locate.dart';

/// "What's near me?" conversation starter (specs-free sibling of the
/// suggestion chips): one tap runs the shared [shareNearMeLocation] flow —
/// a geolocation fix becomes a seeded, labelled plan-chat message asking
/// what's good around the traveler right now, and the no-fix fallback asks
/// for a typed neighborhood instead. The chat composer's location button
/// runs the same flow mid-conversation; this chip stays the opening's way in.
class NearMeChip extends StatefulWidget {
  /// Delivers the composed message; hosts either send directly on the plan
  /// notifier (Agent tab) or switch tabs first (Home).
  final NearMeSend onSend;

  /// Styling knobs so the chip can sit among the white-on-photo hero chips as
  /// well as default Material chips. Null keeps the ambient chip theme.
  final Color? backgroundColor;
  final Color? foregroundColor;
  final TextStyle? labelStyle;

  /// Takes the chip's short spelling — the same idiom [ChatPanel] uses for its
  /// composer hint. Set by hosts whose panel is too narrow for the full label
  /// to share a row: "¿Qué hay cerca de mí?" is 210px, so the Plan tab's
  /// opening wrapped to a second row of chips in Spanish and pushed its own
  /// composer under the nav bar.
  final bool compact;

  const NearMeChip({
    super.key,
    required this.onSend,
    this.backgroundColor,
    this.foregroundColor,
    this.labelStyle,
    this.compact = false,
  });

  @override
  State<NearMeChip> createState() => _NearMeChipState();
}

class _NearMeChipState extends State<NearMeChip> {
  bool _locating = false;

  Future<void> _locate() => shareNearMeLocation(
        context,
        onSend: widget.onSend,
        onLocating: (locating) => setState(() => _locating = locating),
      );

  @override
  Widget build(BuildContext context) {
    final color = widget.foregroundColor;
    return ActionChip(
      avatar: _locating
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          : Icon(Icons.my_location, size: 16, color: color),
      label: Text(
        widget.compact
            ? context.l10n.nearMeChipLabelShort
            : context.l10n.nearMeChipLabel,
        style: widget.labelStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      backgroundColor: widget.backgroundColor,
      side: widget.backgroundColor != null ? BorderSide.none : null,
      onPressed: _locating ? null : _locate,
    );
  }
}
