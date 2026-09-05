import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../utils/geolocation_stub.dart'
    if (dart.library.js_interop) '../utils/geolocation_web.dart';
import '../utils/geolocation_types.dart';

/// Delivers a composed near-me message to a chat surface. The label, when
/// set, makes [PlanNotifier.sendMessage] render the message as a compact
/// context chip instead of a coordinate-bearing bubble.
typedef NearMeSend = void Function(String text, {String? displayLabel});

/// The one "share my location" flow, behind both [NearMeChip] (the Plan tab's
/// conversation starter) and the chat composer's location button (available
/// mid-conversation on both chat hosts).
///
/// Grabs a geolocation fix and sends a seeded message carrying the
/// coordinates in its text — the server's search_nearby tool reads them from
/// the message stream — labelled so the transcript shows "Near my current
/// location" rather than the numbers. Coordinates arrive pre-rounded to 4
/// decimals (~11 m) from the geolocation util, so the exact position never
/// enters the visible or the stored transcript.
///
/// When no fix is available (permission denied, non-web build, timeout), a
/// small dialog asks for a typed city or neighborhood instead; that branch
/// sends a natural-language message with no coordinates and no label.
///
/// [onLocating] drives the caller's progress affordance: true before the
/// lookup starts, false the moment it settles — before any fallback dialog,
/// so a spinner never runs while the traveler reads a prompt. It is not
/// called again after the caller unmounts.
///
/// [getPosition] is the test seam. Null resolves to the real conditional
/// import — which in VM widget tests is the stub, reporting
/// [GeoErrorKind.unsupported]; injecting a fake is the only way a test can
/// reach the success branch.
Future<void> shareNearMeLocation(
  BuildContext context, {
  required NearMeSend onSend,
  required ValueChanged<bool> onLocating,
  Future<GeoResult> Function()? getPosition,
}) async {
  onLocating(true);
  final result = await (getPosition ?? getCurrentPosition)();
  if (!context.mounted) return;
  onLocating(false);

  final l10n = context.l10n;
  if (result.ok) {
    onSend(
      l10n.nearMeSeedMessage(
        result.latitude!.toStringAsFixed(4),
        result.longitude!.toStringAsFixed(4),
        (result.accuracyMeters ?? 0).round().toString(),
      ),
      displayLabel: l10n.nearMeSeedLabel,
    );
    return;
  }

  final place = await showDialog<String>(
    context: context,
    builder: (_) => const _NearMeLocationDialog(),
  );
  if (!context.mounted || place == null || place.trim().isEmpty) return;
  onSend(context.l10n.nearMeManualMessage(place.trim()));
}

/// Fallback location entry when no geolocation fix is available. Pops with the
/// typed place name, or null on cancel.
class _NearMeLocationDialog extends StatefulWidget {
  const _NearMeLocationDialog();

  @override
  State<_NearMeLocationDialog> createState() => _NearMeLocationDialogState();
}

class _NearMeLocationDialogState extends State<_NearMeLocationDialog> {
  final _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final place = _controller.text.trim();
    if (place.isEmpty) return;
    Navigator.of(context).pop(place);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.nearMeDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.nearMeDialogMessage),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(hintText: l10n.nearMeDialogHint),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _hasText ? _submit : null,
          child: Text(l10n.nearMeDialogCta),
        ),
      ],
    );
  }
}
