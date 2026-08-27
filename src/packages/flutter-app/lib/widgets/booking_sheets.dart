import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/accommodation.dart';
import '../models/place_search_result.dart';
import '../models/trip_segment.dart';
import '../providers/places_api_provider.dart';
import '../theme/spacing.dart';

/// Test keys for the stay sheet's place-search elements. The name field needs
/// one too: with the search field mounted above it, position-based finders
/// (`find.byType(TextField).first`) land on search instead.
const kStaySearchFieldKey = Key('stay-search-field');
const kStayNameFieldKey = Key('stay-name-field');
const kStayPlacedRowKey = Key('stay-placed-row');
const kStayPlacedRemoveKey = Key('stay-placed-remove');

/// Transport modes are canonical API values ('flight', 'train', …) sent to the
/// server, so they are never translated — only their display labels are
/// (specs/i18n-spanish). Anything unrecognized renders as-is.
String transportModeLabel(AppLocalizations l10n, String value) =>
    switch (value) {
      'flight' => l10n.bookingsModeFlight,
      'train' => l10n.bookingsModeTrain,
      'bus' => l10n.bookingsModeBus,
      'car' => l10n.bookingsModeCar,
      'ferry' => l10n.bookingsModeFerry,
      'other' => l10n.bookingsModeOther,
      _ => value,
    };

/// Icon for a canonical transport mode, paired with [transportModeLabel].
IconData transportModeIcon(String value) => switch (value) {
      'train' => Icons.train,
      'bus' => Icons.directions_bus,
      'car' => Icons.directions_car,
      'ferry' => Icons.directions_boat,
      'other' => Icons.commute,
      _ => Icons.flight,
    };

/// Bottom-sheet form for adding or editing a stay. Pops with the POST/PATCH
/// body map or null. With [initial] set the fields prefill and the labels flip
/// to editing.
class AddStaySheet extends StatefulWidget {
  final Accommodation? initial;

  /// Optional prefills for a fresh (non-edit) sheet, used by the Trip Health
  /// "Add a stay" fix. Ignored when [initial] is set. Dates are YYYY-MM-DD.
  final String? initialName;
  final String? initialAddress;
  final String? initialCheckIn;
  final String? initialCheckOut;

  const AddStaySheet({
    super.key,
    this.initial,
    this.initialName,
    this.initialAddress,
    this.initialCheckIn,
    this.initialCheckOut,
  });

  @override
  State<AddStaySheet> createState() => _AddStaySheetState();
}

class _AddStaySheetState extends State<AddStaySheet> {
  final _name = TextEditingController();
  final _provider = TextEditingController();
  final _url = TextEditingController();
  final _address = TextEditingController();
  final _priceNote = TextEditingController();
  DateTime? _checkIn;
  DateTime? _checkOut;

  // Place attachment (specs day-travel-times, ticket C). The rule: coordinates
  // ride with a PICK, visibly. Picking a search result fills name + address
  // and attaches lat/lng; re-picking replaces all three; the X on the attached
  // row is the only detach. Free-typing name or address never touches the
  // coordinates — the attached row keeps that state visible instead of the
  // sheet guessing whether a rename meant a different place.
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = ''; // debounced search text driving placeSearchProvider
  double? _lat;
  double? _lng;
  bool _hadCoords = false; // the stay carried a renderable pin at open

  @override
  void initState() {
    super.initState();
    final a = widget.initial;
    if (a != null) {
      _name.text = a.name;
      _provider.text = a.provider ?? '';
      _url.text = a.url ?? '';
      _address.text = a.address ?? '';
      _priceNote.text = a.priceNote ?? '';
      _checkIn = a.checkIn == null ? null : DateTime.tryParse(a.checkIn!);
      _checkOut = a.checkOut == null ? null : DateTime.tryParse(a.checkOut!);
      // Adopt only a pin the map would actually render — same predicate as
      // TripMap.stayHasCoords, inlined so this sheet doesn't import the map.
      // A junk (0,0) stay opens unattached rather than showing a row for a
      // pin that doesn't exist; picking a place overwrites the junk.
      final lat = a.latitude, lng = a.longitude;
      if (lat != null && lng != null && (lat != 0 || lng != 0)) {
        _lat = lat;
        _lng = lng;
        _hadCoords = true;
      }
    } else {
      if (widget.initialName != null) _name.text = widget.initialName!;
      if (widget.initialAddress != null) {
        _address.text = widget.initialAddress!;
      }
      _checkIn = widget.initialCheckIn == null
          ? null
          : DateTime.tryParse(widget.initialCheckIn!);
      _checkOut = widget.initialCheckOut == null
          ? null
          : DateTime.tryParse(widget.initialCheckOut!);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_name, _provider, _url, _address, _priceNote, _search]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  void _pick(PlaceSearchResult place) {
    // Cancel any in-flight debounce so a stale keystroke can't resurface the
    // results list after the field is gone.
    _debounce?.cancel();
    setState(() {
      _name.text = place.name;
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

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (range != null) {
      setState(() {
        _checkIn = range.start;
        _checkOut = range.end;
      });
    }
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(<String, dynamic>{
      'name': name,
      if (_provider.text.trim().isNotEmpty) 'provider': _provider.text.trim(),
      if (_url.text.trim().isNotEmpty) 'url': _url.text.trim(),
      if (_address.text.trim().isNotEmpty) 'address': _address.text.trim(),
      if (_priceNote.text.trim().isNotEmpty)
        'price_note': _priceNote.text.trim(),
      if (_checkIn != null) 'check_in': _fmt(_checkIn!),
      if (_checkOut != null) 'check_out': _fmt(_checkOut!),
      // Attached place → the pair rides the body (the server requires both
      // together). Detached during an edit → clear_location, because the
      // PATCH's COALESCE cannot write NULL from an omitted key. A stay that
      // never had coordinates sends neither — ungeocoded stays stay legal.
      if (_lat != null && _lng != null) ...{
        'latitude': _lat,
        'longitude': _lng,
      } else if (_hadCoords)
        'clear_location': true,
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final editing = widget.initial != null;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(editing ? l10n.bookingsEditStay : l10n.bookingsAddAStay,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            // Place search XOR attached row — the add-place dialog's mechanism
            // (add_itinerary_item_dialog.dart), mirrored rather than shared:
            // that dialog's search is welded into its search-or-manual state
            // machine, while here manual entry stays the default and search
            // only enhances it. Typing below never requires a pick.
            if (_lat == null) ...[
              TextField(
                key: kStaySearchFieldKey,
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
                key: kStayPlacedRowKey,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.place, color: theme.colorScheme.primary),
                title: Text(l10n.bookingsStayPlaced,
                    style: theme.textTheme.bodyMedium),
                trailing: IconButton(
                  key: kStayPlacedRemoveKey,
                  icon: const Icon(Icons.clear),
                  tooltip: l10n.bookingsStayPlacedRemove,
                  onPressed: _detach,
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: kStayNameFieldKey,
              controller: _name,
              decoration: InputDecoration(
                labelText: l10n.bookingsStayNameLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _provider,
              decoration: InputDecoration(
                labelText: l10n.bookingsStayProviderLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: l10n.bookingsStayUrlLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _address,
              decoration: InputDecoration(
                labelText: l10n.bookingsStayAddressLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickRange,
                    icon: const Icon(Icons.date_range, size: 18),
                    label: Text(
                      _checkIn != null && _checkOut != null
                          ? '${_fmt(_checkIn!)} → ${_fmt(_checkOut!)}'
                          : l10n.bookingsCheckInOut,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _priceNote,
              decoration: InputDecoration(
                labelText: l10n.bookingsPriceNoteLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonCancel),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: _save,
                  child: Text(editing ? l10n.commonSave : l10n.bookingsAddStay),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

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
          return Container(
            constraints: const BoxConstraints(maxHeight: 240),
            margin: const EdgeInsets.only(top: AppSpacing.sm),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: AppRadius.smAll,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (context, i) {
                final place = list[i] as PlaceSearchResult;
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.place),
                  title: Text(place.name),
                  subtitle: place.address.isEmpty ? null : Text(place.address),
                  onTap: () => _pick(place),
                );
              },
            ),
          );
        },
        loading: () => const Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: Center(child: CircularProgressIndicator()),
        ),
        // Search unavailable (e.g. no Places key): the manual fields below
        // are the path, same steer as the add-place dialog.
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(l10n.itemDialogSearchUnavailable,
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    });
  }
}

/// Bottom-sheet picker for a booking's "Move to…" action
/// (specs/booking-city-grouping): the trip's cities in visit order plus
/// "Other bookings". A picker sheet, not a submenu, because
/// [BookingRowMenuItem] is a flat list and `PopupMenuButton` cannot nest —
/// the "Reorder section" sheet is the precedent.
///
/// Pops with the chosen city label, `''` for "Other bookings", or null when
/// dismissed — the caller treats `''` as "clear the city".
class MoveBookingSheet extends StatelessWidget {
  /// Deduped city labels in trip order (the filter-chip dedupe: a revisited
  /// city appears once).
  final List<String> cities;

  /// The booking's current city label; null = "Other bookings".
  final String? current;

  const MoveBookingSheet({super.key, required this.cities, this.current});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final currentKey = current?.trim().toLowerCase();
    Widget option({
      required IconData icon,
      required String label,
      required bool selected,
      required String popValue,
    }) =>
        ListTile(
          leading: Icon(icon,
              size: 20,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant),
          title: Text(label),
          trailing: selected
              ? Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
              : null,
          onTap: () => Navigator.of(context).pop(popValue),
        );
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
                child: Text(l10n.bookingMoveToTitle,
                    style: theme.textTheme.titleMedium),
              ),
              for (final city in cities)
                option(
                  icon: Icons.place_outlined,
                  label: city,
                  selected: city.trim().toLowerCase() == currentKey,
                  popValue: city,
                ),
              option(
                icon: Icons.luggage_outlined,
                label: l10n.tripOtherBookings,
                selected: currentKey == null || currentKey.isEmpty,
                popValue: '',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom-sheet form for adding or editing a transport segment. Pops with the
/// POST/PATCH body map or null. With [initial] set the fields prefill and the
/// labels flip to editing.
class AddSegmentSheet extends StatefulWidget {
  final TripSegment? initial;

  /// Optional prefills for a fresh (non-edit) sheet, used by the Trip Health
  /// "Add transport" fix. Ignored when [initial] is set. Date is YYYY-MM-DD.
  final String? initialOrigin;
  final String? initialDestination;
  final String? initialMode;
  final String? initialDepartDate;

  /// Optional prefill for the arrival date — set for a leg that lands on a
  /// later calendar day than it leaves (an overnight flight, red-eye, night
  /// train or overnight ferry). Ignored when [initial] is set.
  final String? initialArriveDate;

  /// True when this sheet is filling in the details of a leg the itinerary
  /// already derives, so its endpoints are not this form's to change.
  ///
  /// Editing them here used to look like editing the leg and actually POSTed a
  /// second row: the page then showed "EWR → Amsterdam" with "ALB → Amsterdam"
  /// nested underneath it, two claims about one flight. A derived leg's
  /// endpoints come from the trip (its airports) or the itinerary (its cities),
  /// which is one obvious place each — so here they are shown, not typed.
  final bool endpointsLocked;

  /// Offered beside the locked endpoints of a home leg: the one control that
  /// really does change them. Null on an inter-city leg, whose endpoints follow
  /// the itinerary's cities and have no single field to send you to.
  final VoidCallback? onChangeAirport;

  const AddSegmentSheet({
    super.key,
    this.initial,
    this.initialOrigin,
    this.initialDestination,
    this.initialMode,
    this.initialDepartDate,
    this.initialArriveDate,
    this.endpointsLocked = false,
    this.onChangeAirport,
  });

  @override
  State<AddSegmentSheet> createState() => _AddSegmentSheetState();
}

class _AddSegmentSheetState extends State<AddSegmentSheet> {
  final _origin = TextEditingController();
  final _destination = TextEditingController();
  final _provider = TextEditingController();
  final _url = TextEditingController();
  final _notes = TextEditingController();
  final _priceNote = TextEditingController();
  String _mode = 'flight';
  DateTime? _departDate;
  DateTime? _arriveDate;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    if (s != null) {
      _origin.text = s.origin ?? '';
      _destination.text = s.destination ?? '';
      _provider.text = s.provider ?? '';
      _url.text = s.url ?? '';
      _notes.text = s.notes ?? '';
      _priceNote.text = s.priceNote ?? '';
      _mode = s.mode;
      _departDate =
          s.departDate == null ? null : DateTime.tryParse(s.departDate!);
      // Round-trip the arrival: the sheet is also the EDIT path, and omitting
      // the field would leave UpdateSegment's COALESCE holding a stored arrival
      // the traveler can no longer see while they move the departure past it.
      _arriveDate =
          s.arriveDate == null ? null : DateTime.tryParse(s.arriveDate!);
    } else {
      if (widget.initialOrigin != null) _origin.text = widget.initialOrigin!;
      if (widget.initialDestination != null) {
        _destination.text = widget.initialDestination!;
      }
      if (widget.initialMode != null) _mode = widget.initialMode!;
      _departDate = widget.initialDepartDate == null
          ? null
          : DateTime.tryParse(widget.initialDepartDate!);
      _arriveDate = widget.initialArriveDate == null
          ? null
          : DateTime.tryParse(widget.initialArriveDate!);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _origin,
      _destination,
      _provider,
      _url,
      _notes,
      _priceNote
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (picked == null) return;
    setState(() {
      _departDate = picked;
      // An arrival can never precede its departure — the server refuses the
      // pair (segment_handler.go) and the trip page would render a backwards
      // span. Drop a now-impossible arrival rather than submit-and-fail.
      if (_arriveDate != null && _arriveDate!.isBefore(picked)) {
        _arriveDate = null;
      }
    });
  }

  /// The arrival picker cannot open before the chosen departure, so a backwards
  /// pair is structurally unpickable rather than rejected after the fact.
  Future<void> _pickArriveDate() async {
    final now = DateTime.now();
    final first = _departDate ?? now.subtract(const Duration(days: 365));
    final picked = await showDatePicker(
      context: context,
      initialDate: _arriveDate ?? first,
      firstDate: first,
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (picked != null) setState(() => _arriveDate = picked);
  }

  void _save() {
    final origin = _origin.text.trim();
    final destination = _destination.text.trim();
    if (origin.isEmpty || destination.isEmpty) return;
    Navigator.of(context).pop(<String, dynamic>{
      'mode': _mode,
      'origin': origin,
      'destination': destination,
      if (_departDate != null) 'depart_date': _fmt(_departDate!),
      if (_arriveDate != null) 'arrive_date': _fmt(_arriveDate!),
      if (_provider.text.trim().isNotEmpty) 'provider': _provider.text.trim(),
      if (_url.text.trim().isNotEmpty) 'url': _url.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      if (_priceNote.text.trim().isNotEmpty)
        'price_note': _priceNote.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final editing = widget.initial != null;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                editing
                    ? l10n.bookingsEditTransport
                    : l10n.bookingsAddTransport,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: 8,
              children: [
                for (final m in const [
                  'flight',
                  'train',
                  'bus',
                  'car',
                  'ferry',
                  'other',
                ])
                  ChoiceChip(
                    label: Text(transportModeLabel(l10n, m)),
                    selected: _mode == m,
                    onSelected: (_) => setState(() => _mode = m),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _origin,
                    readOnly: widget.endpointsLocked,
                    decoration: InputDecoration(
                      labelText: l10n.bookingsSegmentFromLabel,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    controller: _destination,
                    readOnly: widget.endpointsLocked,
                    decoration: InputDecoration(
                      labelText: l10n.bookingsSegmentToLabel,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.endpointsLocked) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      l10n.bookingsSegmentEndpointsFromTrip,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (widget.onChangeAirport != null)
                    TextButton(
                      onPressed: widget.onChangeAirport,
                      child: Text(l10n.tripAirportsChangeLink),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.today, size: 18),
                  label: Text(
                    _departDate != null
                        ? _fmt(_departDate!)
                        : l10n.bookingsDepartureDate,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _pickArriveDate,
                  icon: const Icon(Icons.event_available, size: 18),
                  label: Text(
                    _arriveDate != null
                        ? _fmt(_arriveDate!)
                        : l10n.bookingsArrivalDate,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _provider,
              decoration: InputDecoration(
                labelText: l10n.bookingsSegmentProviderLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: l10n.bookingsSegmentUrlLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            // Parity with AddStaySheet: the column and API accepted
            // price_note all along — the form just never offered it.
            TextField(
              controller: _priceNote,
              decoration: InputDecoration(
                labelText: l10n.bookingsPriceNoteLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _notes,
              decoration: InputDecoration(
                labelText: l10n.bookingsNotesLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.commonCancel),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: _save,
                  child: Text(
                      editing ? l10n.commonSave : l10n.bookingsAddTransport),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
