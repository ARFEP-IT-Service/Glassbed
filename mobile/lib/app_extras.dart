import 'package:flutter/widgets.dart';

/// Optional additions that an entry point can plug into the app (see main_github.dart).
/// The default entry point passes none, so nothing of an extra is compiled into that build.
abstract class AppExtras {
  /// Called once after the home screen's first frame (e.g. to ask a one-time question).
  void onHomeReady(BuildContext context);

  /// Shown on the home screen under the printer card. Return an empty widget when idle.
  Widget homeBanner(BuildContext context);

  /// Extra rows on the settings screen, placed above "About".
  List<Widget> settingsSection(BuildContext context);

  /// Replaces the privacy sentence under "About" when the extra changes what the app connects to.
  String? get privacyNote => null;
}
