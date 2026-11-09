import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_extras.dart';
import 'i18n.dart';
import 'ui/home/home_screen.dart';
import 'ui/theme.dart';

class GlassbedApp extends StatefulWidget {
  const GlassbedApp({super.key, this.extras});

  /// Additions of the entry point (null in the default build).
  final AppExtras? extras;

  @override
  State<GlassbedApp> createState() => _GlassbedAppState();
}

class _GlassbedAppState extends State<GlassbedApp> {
  @override
  void initState() {
    super.initState();
    languageSetting.addListener(_onLanguageChanged);
  }

  @override
  void dispose() {
    languageSetting.removeListener(_onLanguageChanged);
    super.dispose();
  }

  void _onLanguageChanged() {
    setState(() {});
    // tr() does not depend on an InheritedWidget, so rebuild every widget once to pick up
    // the new texts without losing any screen state (scanned pages stay).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void visit(Element e) {
        e.markNeedsBuild();
        e.visitChildren(visit);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(visit);
    });
  }

  @override
  Widget build(BuildContext context) {
    final code = languageSetting.value;
    return MaterialApp(
      title: 'Glassbed',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      locale: code == null ? null : Locale(code),
      supportedLocales: [for (final c in supportedLanguages.keys) Locale(c)],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: HomeScreen(extras: widget.extras),
    );
  }
}
