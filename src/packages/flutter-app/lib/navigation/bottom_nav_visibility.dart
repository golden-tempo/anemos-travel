import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether [AppShell] renders its persistent bottom [NavigationBar] at
/// narrow widths (issue #594).
///
/// True everywhere except one screen: [TripDetailScreen] is the densest page
/// in the app, and on a phone the tab bar was eating a full row underneath it
/// for no reason once the traveler had already landed there. It drives this
/// false for as long as it is the Trips tab's foreground content at narrow
/// widths, and shows its own small button in the bar's place so the tabs are
/// never unreachable — tapping it sets this back to true for the rest of that
/// visit (reset to true again the next time the screen is opened, and always
/// on dispose so leaving the page never strands the bar hidden).
///
/// A [StateProvider] rather than a [ShellScope]-style [InheritedWidget]:
/// [ShellScope] flows from an ancestor (`AppShell`) down to descendants, but
/// here the direction is reversed — a screen INSIDE a tab's own [Navigator]
/// needs to reach [AppShell], which renders above every tab's subtree, not
/// below it. Neither is an ancestor of the other for an InheritedWidget to
/// travel through, so a shared provider is the only seam available.
final bottomNavVisibleProvider = StateProvider<bool>((ref) => true);
