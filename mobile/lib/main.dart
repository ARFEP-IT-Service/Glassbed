import 'package:flutter/material.dart';

import 'app.dart';
import 'i18n.dart';

/// Default entry point (store build): the app without any update check.
/// The GitHub build starts from main_github.dart instead.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadI18n();
  runApp(const GlassbedApp());
}
