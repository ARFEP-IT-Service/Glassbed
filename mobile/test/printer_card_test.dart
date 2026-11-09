import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/device.dart';
import 'package:glassbed/core/ipp.dart';
import 'package:glassbed/ui/home/printer_card.dart';
import 'package:glassbed/ui/theme.dart';

const ip = '192.168.178.33';

const fourMarkers = [
  Marker(name: 'Black', color: '#000000', level: 60),
  Marker(name: 'Cyan', color: '#00FFFF', level: 80),
  Marker(name: 'Magenta', color: '#FF00FF', level: 10),
  Marker(name: 'Yellow', color: '#FFFF00', level: 100),
];

PrinterInfo info(List<Marker> markers) => PrinterInfo(
      state: 'idle',
      stateReasons: const [],
      makeAndModel: 'HP Color LaserJet Pro MFP M283fdw with a very long model name',
      markers: markers,
    );

/// Roboto from the Flutter SDK, so text widths are those of a phone and not of the test font
/// (whose glyphs are all 1 em wide).
Future<void> loadRoboto() async {
  final artifacts = File(Platform.resolvedExecutable).parent.parent.parent.path;
  final file = File('$artifacts/material_fonts/roboto-regular.ttf');
  expect(file.existsSync(), isTrue, reason: 'Roboto not found in the Flutter SDK: ${file.path}');
  final bytes = file.readAsBytesSync();
  await (FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

void main() {
  setUpAll(loadRoboto);

  Future<void> pumpCard(
    WidgetTester tester,
    double width, {
    List<Marker> markers = fourMarkers,
    bool searching = false,
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(brightness),
      home: Scaffold(
        // the home screen's padding
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          PrinterCard(
            hostController: TextEditingController(text: ip),
            searching: searching,
            devices: null,
            selected: Device.fromHost(ip, name: 'HP'),
            link: Link.online,
            info: info(markers),
            scanner: true,
            onConnect: () {},
            onSearch: () {},
            onPick: (_) {},
            onCheck: () {},
          ),
        ]),
      ),
    ));
  }

  /// Width the address needs in the field's own style.
  double ipWidth(WidgetTester tester) {
    final field = tester.widget<EditableText>(find.byType(EditableText));
    final painter = TextPainter(
      text: TextSpan(text: ip, style: field.style),
      textDirection: TextDirection.ltr,
      textScaler: field.textScaler ?? TextScaler.noScaling,
    )..layout();
    addTearDown(painter.dispose);
    return painter.width;
  }

  for (final width in [320.0, 360.0, 400.0]) {
    testWidgets('$width dp: no overflow, the full IP fits, search and menu next to it',
        (tester) async {
      await pumpCard(tester, width);
      expect(tester.takeException(), isNull);
      final field = tester.getSize(find.byType(EditableText)).width;
      expect(field, greaterThanOrEqualTo(ipWidth(tester)), reason: 'text area $field dp');
      final search = find.byKey(const ValueKey('printer-search'));
      expect(find.byTooltip('Search'), findsOneWidget);
      expect(find.text('Search'), findsNothing); // an icon, no pill
      final menu = find.byKey(const ValueKey('printer-menu'));
      // one row: field, search, menu
      final fieldBox = tester.getRect(find.byKey(const ValueKey('printer-host')));
      expect(tester.getCenter(search).dy, closeTo(fieldBox.center.dy, 1));
      expect(tester.getCenter(menu).dy, closeTo(fieldBox.center.dy, 1));
      expect(tester.getRect(search).left, greaterThanOrEqualTo(fieldBox.right));
      expect(tester.getRect(menu).left, greaterThanOrEqualTo(tester.getRect(search).right));
      expect(find.byTooltip('Connect'), findsOneWidget);
    });
  }

  for (final width in [320.0, 400.0]) {
    testWidgets('$width dp: four markers in one compact row, the card stays short', (tester) async {
      await pumpCard(tester, width);
      expect(tester.takeException(), isNull);
      final items = [
        find.byTooltip('Black: 60 % left'),
        find.byTooltip('Cyan: 80 % left'),
        find.byTooltip('Magenta: 10 % left – Toner low'),
        find.byTooltip('Yellow: 100 % left'),
      ];
      for (final item in items) {
        expect(item, findsOneWidget);
      }
      final top = tester.getTopLeft(items.first).dy;
      for (var i = 1; i < items.length; i++) {
        expect(tester.getTopLeft(items[i]).dy, top);
        expect(tester.getTopLeft(items[i]).dx, greaterThan(tester.getTopRight(items[i - 1]).dx));
      }
      for (final text in ['60 %', '80 %', '10 %', '100 %']) {
        expect(find.text(text), findsOneWidget);
      }
      // low keeps its highlighting
      expect(find.text('Toner low'), findsOneWidget);
      final low = tester.widget<Text>(find.text('10 %'));
      expect(low.style?.color, Palette.dark.danger);
      // the black bar keeps its outline on the dark theme
      final blackBar = tester.widget<Container>(
          find.descendant(of: items.first, matching: find.byType(Container)).first);
      expect((blackBar.decoration as BoxDecoration).border, isNotNull);
      // the status line stays one line
      expect(tester.getSize(find.textContaining('HP Color LaserJet')).height, lessThan(24));
      // before: about 275 dp (a 56 dp field with a pill button, a label and a bar per marker)
      expect(tester.getSize(find.byType(Card)).height, lessThan(160));
    });
  }

  testWidgets('screen readers get the full sentence for each marker', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpCard(tester, 400, brightness: Brightness.light);
    expect(find.bySemanticsLabel('Black: 60 % left'), findsOneWidget);
    expect(find.bySemanticsLabel('Magenta: 10 % left – Toner low'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('320 dp: six markers shrink to one row without overflow', (tester) async {
    await pumpCard(tester, 320, markers: const [
      ...fourMarkers,
      Marker(name: 'Light cyan', color: '#80FFFF', level: 5),
      Marker(name: 'Light magenta', color: '#FF80FF', level: 100),
    ]);
    expect(tester.takeException(), isNull);
    final first = tester.getTopLeft(find.byTooltip('Black: 60 % left')).dy;
    expect(tester.getTopLeft(find.byTooltip('Light magenta: 100 % left')).dy, first);
    final card = tester.getRect(find.byType(Card));
    expect(tester.getRect(find.byTooltip('Light magenta: 100 % left')).right, lessThan(card.right));
  });

  testWidgets('one marker and unknown levels', (tester) async {
    await pumpCard(tester, 320, markers: const [
      Marker(name: 'Black', color: '#000000', level: 60),
      Marker(name: 'Waste', color: 'none', level: -1),
    ]);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Black: 60 % left'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Toner low'), findsNothing);
  });

  testWidgets('while searching: a small progress indicator instead of the icon', (tester) async {
    await pumpCard(tester, 360, searching: true);
    final search = find.byKey(const ValueKey('printer-search'));
    expect(find.descendant(of: search, matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    expect(find.descendant(of: search, matching: find.byIcon(Icons.wifi_find)), findsNothing);
    expect(tester.widget<IconButton>(search).onPressed, isNull);
    expect(tester.widget<IconButton>(search).tooltip, 'Search');
  });
}
