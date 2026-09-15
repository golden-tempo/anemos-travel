import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/place_search_result.dart';
import '../providers/places_api_provider.dart';
import '../theme/spacing.dart';

/// Test keys for the prompt's place-search elements — mirrors
/// [kStaySearchFieldKey] & co. in booking_sheets.dart.
const kStayAddressPromptSearchFieldKey = Key('stay-address-prompt-search-field');
const kStayAddressPromptAddressFieldKey =
    Key('stay-address-prompt-address-field');
const kStayAddressPromptPlacedRowKey = Key('stay-address-prompt-placed-row');
const kStayAddressPromptPlacedRemoveKey =
    Key('stay-address-prompt-placed-remove');

/// What the traveler confirmed in [showStayAddressPrompt]: a free-typed
/// address, or one attached to a real place — coordinates ride with a PICK,
/// same pairing rule as [AddStaySheet] (a lone coordinate can never render a
/// pin or feed a route request).
class StayAddressDraft {
  final String address;
  final double? latitude;
  final double? longitude;
  const StayAddressDraft(
      {required this.address, this.latitude, this.longitude});
}

/// Prompts for the address of where the traveler is staying, right after they
/// check a stay booking item as booked — the moment they actually have it in
/// hand (specs/booking-address-prompt). Saving it is what lets the
/// itinerary's hotel-anchor travel times ("~15 min from the hotel" / "back to
/// the hotel", already computed from a stay's coordinates) and the trip
/// page's "Nearby" action work for this stay; both stay silent without one.
/// Returns null on Skip/dismiss — the caller treats that as "not now", never
/// as an error.
Future<StayAddressDraft?> showStayAddressPrompt(BuildContext context,
    {required String stayTitle}) {
  return showDialog<StayAddressDraft>(
    context: context,
    builder: (_) => _StayAddressDialog(stayTitle: stayTitle),
  );
}

class _StayAddressDialog extends StatefulWidget {
  final String stayTitle;
  const _StayAddressDialog({required this.stayTitle});

  @override
  State<_StayAddressDialog> createState() => _StayAddressDialogState();
}

class _StayAddressDialogState extends State<_StayAddressDialog> {
  final _address = TextEditingController();
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  double? _lat;
  double? _lng;

  @override
  void dispose() {
    _debounce?.cancel();
    _address.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  void _pick(PlaceSearchResult place) {
    _debounce?.cancel();
    setState(() {
      if (place.address.isNotEmpty) _address.text = place.address;
      _lat = place.latitude;
      _lng = place.longitude;
      _search.clear();
      _query = '';
    });
  }

  void _detach() {
    setState(() {
      _lat = null;
      _lng = null;
    });
  }

  void _save() {
    final address = _address.text.trim();
    if (address.isEmpty) return;
    Navigator.of(context).pop(StayAddressDraft(
      address: address,
      latitude: _lat,
      longitude: _lng,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.stayAddressPromptTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.stayAddressPromptBody(widget.stayTitle),
                style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.md),
            // Place search XOR attached row, mirrored from AddStaySheet: a
            // pick fills the address AND attaches coordinates; typing below
            // never requires one.
            if (_lat == null) ...[
              TextField(
                key: kStayAddressPromptSearchFieldKey,
                controller: _search,
                decoration: InputDecoration(
                  labelText: l10n.bookingsStaySearchLabel,
                  hintText: l10n.bookingsStaySearchHint,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                ),
                onChanged: _onSearchChanged,
              ),
              if (_query.isNotEmpty) _buildSearchResults(theme),
            ] else
              ListTile(
                key: kStayAddressPromptPlacedRowKey,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.place, color: theme.colorScheme.primary),
                title: Text(l10n.bookingsStayPlaced,
                    style: theme.textTheme.bodyMedium),
                trailing: IconButton(
                  key: kStayAddressPromptPlacedRemoveKey,
                  icon: const Icon(Icons.clear),
                  tooltip: l10n.bookingsStayPlacedRemove,
                  onPressed: _detach,
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: kStayAddressPromptAddressFieldKey,
              controller: _address,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.bookingsStayAddressLabel,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.budgetPromptSkip),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }

  /// Rendered as a plain (non-scrolling) Column, not a ListView: the dialog
  /// content already sits inside a [SingleChildScrollView], and AlertDialog
  /// wraps its content in intrinsic-width sizing, which a shrink-wrapped
  /// ListView cannot answer (RenderShrinkWrappingViewport has no intrinsic
  /// dimensions) — capped at [_maxResults] so an unbounded Column stays
  /// reasonable.
  static const _maxResults = 5;

  Widget _buildSearchResults(ThemeData theme) {
    final l10n = context.l10n;
    return Consumer(builder: (context, ref, _) {
      final results = ref.watch(placeSearchProvider(_query));
      return results.when(
        data: (list) {
          if (list.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(l10n.itemDialogNoResults),
            );
          }
          final shown = list.take(_maxResults).toList();
          return Container(
            margin: const EdgeInsets.only(top: AppSpacing.sm),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: AppRadius.smAll,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final r in shown)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.place),
                    title: Text((r as PlaceSearchResult).name),
                    subtitle:
                        r.address.isEmpty ? null : Text(r.address),
                    onTap: () => _pick(r),
                  ),
              ],
            ),
          );
        },
        loading: () => const Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(l10n.itemDialogSearchUnavailable,
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    });
  }
}
