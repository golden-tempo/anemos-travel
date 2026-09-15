import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/trip_refine_chat.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';
import '../utils/trip_format.dart';

/// "Previous chats" (#639): the picker over a trip's up-to-5 archived
/// conversations, opened from the Continue-chat row's menu and from inside
/// the open refine panel. Returns the id of the entry the traveler tapped, or
/// null if they dismissed the sheet without choosing one.
///
/// [loadHistory] is called once, when the sheet first builds — not before,
/// so opening the sheet is the only thing that triggers the request, and
/// dismissing it without waiting costs nothing. Loading, error and empty
/// states are all rendered IN the sheet rather than gating whether it opens
/// at all, the same "show something immediately" shape as the refine panel's
/// own restoring/expired/failed states.
Future<String?> showPreviousChatsSheet(
  BuildContext context, {
  required Future<List<TripRefineChatHistoryEntry>> Function() loadHistory,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    // Width cap centers the sheet on desktop, matching the health/plan
    // progress sheets: a short list reads stranded at full bleed.
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetContext) {
      final screenHeight = MediaQuery.of(sheetContext).size.height;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: screenHeight * 0.7),
          child: _PreviousChatsSheetBody(loadHistory: loadHistory),
        ),
      );
    },
  );
}

class _PreviousChatsSheetBody extends StatefulWidget {
  final Future<List<TripRefineChatHistoryEntry>> Function() loadHistory;

  const _PreviousChatsSheetBody({required this.loadHistory});

  @override
  State<_PreviousChatsSheetBody> createState() =>
      _PreviousChatsSheetBodyState();
}

class _PreviousChatsSheetBodyState extends State<_PreviousChatsSheetBody> {
  late final Future<List<TripRefineChatHistoryEntry>> _future =
      widget.loadHistory();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
          child: Text(l10n.refinePreviousChats,
              style: Theme.of(context).textTheme.titleMedium),
        ),
        Flexible(
          child: FutureBuilder<List<TripRefineChatHistoryEntry>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: Center(
                    child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                );
              }
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0,
                      AppSpacing.lg, AppSpacing.lg),
                  child: Text(friendlyError(l10n, snapshot.error),
                      style: Theme.of(context).textTheme.bodySmall),
                );
              }
              final entries = snapshot.data ?? const [];
              if (entries.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0,
                      AppSpacing.lg, AppSpacing.lg),
                  child: Text(l10n.refinePreviousChatsEmpty,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                );
              }
              return ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                itemCount: entries.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final entry = entries[i];
                  return ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(
                      entry.preview.isEmpty
                          ? l10n.refineAssistantTitle
                          : entry.preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(l10n.tripContinueChatMeta(
                        entry.messageCount,
                        tripRelativeTime(l10n, entry.updatedAt))),
                    onTap: () => Navigator.pop(context, entry.id),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
