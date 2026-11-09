import 'package:flutter/material.dart';

import 'app.dart';
import 'i18n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadI18n();
  runApp(const GlassbedApp());
}
