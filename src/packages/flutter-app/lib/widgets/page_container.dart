import 'package:flutter/material.dart';

/// Centers page content and caps its width on wide (web/desktop) layouts.
///
/// Place it *inside* the scroll view, around the content column, so the
/// scrollable region stays full-width (mouse wheel and scrollbar keep working
/// in the gutters) while the content is constrained. The house width tiers:
/// 700 (default, reading/list pages), 760 (chat column), 900 (dense pages
/// like trip detail).
class PageContainer extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  /// Force [child] to the full capped width. A page that lays its sections
  /// out as independent, lazily-built ListView children wraps each one with
  /// this in place of the `crossAxisAlignment: stretch` its old single
  /// Column applied — a Card or section handed the default loose
  /// constraints would shrink-wrap instead.
  final bool stretch;

  const PageContainer(
      {super.key, required this.child, this.maxWidth = 700, this.stretch = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: stretch
            ? SizedBox(width: double.infinity, child: child)
            : child,
      ),
    );
  }
}
