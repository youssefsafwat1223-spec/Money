import 'package:flutter/widgets.dart';

/// True while a transient overlay route (a bottom sheet or dialog) is on top
/// of the app.
///
/// The bottom nav bar is a native UIKit tab bar (native_glass_navbar) embedded
/// as a platform view. Flutter modal routes are drawn in the Flutter layer and
/// CANNOT occlude a native platform view, so the glass bar bleeds a darker band
/// over any open sheet. The shell watches this and removes the bar from the
/// tree while a sheet/dialog is up, then restores it on dismiss.
final ValueNotifier<bool> modalRouteOpen = ValueNotifier<bool>(false);

class ModalRouteObserver extends NavigatorObserver {
  int _openCount = 0;

  // Bottom sheets and dialogs are PopupRoutes; full-page navigations
  // (MaterialPageRoute) are not — those swap the whole screen and must not
  // toggle the bar.
  bool _isOverlay(Route<dynamic>? route) => route is PopupRoute;

  void _delta(int d) {
    _openCount += d;
    if (_openCount < 0) _openCount = 0;
    final open = _openCount > 0;
    if (modalRouteOpen.value != open) modalRouteOpen.value = open;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isOverlay(route)) _delta(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isOverlay(route)) _delta(-1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isOverlay(route)) _delta(-1);
  }
}

final ModalRouteObserver modalRouteObserver = ModalRouteObserver();
