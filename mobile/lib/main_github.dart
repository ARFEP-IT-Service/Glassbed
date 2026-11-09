import 'package:flutter/material.dart';

import 'app.dart';
import 'i18n.dart';
import 'update/update_controller.dart';
import 'update/update_texts.dart';
import 'update/update_ui.dart';

/// Entry point of the build published on GitHub: the app plus the optional update notice.
/// The default entry point (main.dart) has no update code at all.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadI18n();
  addTexts(updateTexts);
  runApp(GlassbedApp(extras: UpdateExtras(UpdateController())));
}
