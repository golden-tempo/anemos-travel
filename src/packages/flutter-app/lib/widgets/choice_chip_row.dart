import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// A single-select row of [ChoiceChip]s. Tapping the selected chip again
/// clears the selection (passes null).
class ChoiceChipRow extends StatelessWidget {
  final List<String> options;
  final String? selected;
  final ValueChanged<String?> onSelected;

  /// Maps an option to its display text. [options] are canonical API values
  /// (`budget`/`mid`/`luxury`), so localized screens pass a translator here
  /// while the values sent to the server stay unchanged. Defaults to showing
  /// the value itself (specs/i18n-spanish).
  final String Function(String value)? labelBuilder;

  const ChoiceChipRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.labelBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      // Long localized labels (es) wrap onto extra runs; keep them breathing.
      runSpacing: AppSpacing.xs,
      children: options.map((o) {
        return ChoiceChip(
          label: Text(labelBuilder?.call(o) ?? o),
          selected: selected == o,
          onSelected: (sel) => onSelected(sel ? o : null),
        );
      }).toList(),
    );
  }
}

/// [ChoiceChipRow]'s multi-select twin: same chips, same wrap, selections
/// accumulate. For questions where one answer is a lie — "who you travel with"
/// is not one shape for someone who flies solo for work and takes the kids in
/// August.
///
/// [exclusiveOptions] are values that cannot coexist with any other: choosing
/// one clears the rest, and choosing anything else clears it. "It varies"
/// answers the same question the specific shapes do, about all of them at
/// once, so "solo AND it varies" states and unstates a fact in one breath.
///
/// The rule is enforced HERE as well as on the server, deliberately. The server
/// is the authority, but if only it knew, a traveler would watch two chips stay
/// lit and one of them quietly disappear on the next load.
class MultiChoiceChipRow extends StatelessWidget {
  final List<String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  /// See [ChoiceChipRow.labelBuilder] — canonical values in, localized text
  /// out, so what ships to the server never depends on the display language.
  final String Function(String value)? labelBuilder;

  final Set<String> exclusiveOptions;

  const MultiChoiceChipRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.labelBuilder,
    this.exclusiveOptions = const {},
  });

  void _toggle(String option) {
    final next = {...selected};
    if (next.contains(option)) {
      // Always removable: with no single-select fallback, an unselectable last
      // chip would leave no way back to "I never said".
      next.remove(option);
    } else if (exclusiveOptions.contains(option)) {
      next
        ..clear()
        ..add(option);
    } else {
      next
        ..removeAll(exclusiveOptions)
        ..add(option);
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: options.map((o) {
        return ChoiceChip(
          label: Text(labelBuilder?.call(o) ?? o),
          selected: selected.contains(o),
          onSelected: (_) => _toggle(o),
        );
      }).toList(),
    );
  }
}
