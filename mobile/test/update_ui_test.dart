import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/update/installer.dart';
import 'package:glassbed/update/update_controller.dart';
import 'package:glassbed/update/update_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_download_test.dart' show FakeInstaller, apk, apkBytes, apkHash, withSha;
import 'update_test.dart' show release;

void main() {
  late List<http.BaseRequest> calls;
  late List<Uri> opened;
  late UpdateExtras extras;

  setUp(() {
    calls = [];
    opened = [];
    extras = UpdateExtras(
      UpdateController(
        newClient: () => MockClient((request) async {
          calls.add(request);
          return http.Response(jsonEncode([release('android-v0.9.0')]), 200);
        }),
        deviceAbi: () async => 'arm64-v8a',
      ),
      openUrl: (url) async {
        opened.add(url);
        return true;
      },
    );
  });

  /// A home-like screen that calls onHomeReady after its first frame, like HomeScreen.
  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(body: ListView(children: [const Text('printer'), extras.homeBanner(context)]));
      }),
    ));
    extras.onHomeReady(tester.element(find.text('printer')));
    await tester.pumpAndSettle();
  }

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  testWidgets('question: No is the filled default, asked is stored at once, nothing requested',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpHome(tester);
    expect(find.text('Check for updates?'), findsOneWidget);
    final p = await prefs();
    expect(p.getBool(keyAsked), isTrue);
    expect(p.getBool(keyEnabled), isFalse);

    final filled = tester.widget<FilledButton>(find.byType(FilledButton));
    expect((filled.child as Text).data, 'No');
    expect(filled.autofocus, isTrue);
    expect(find.widgetWithText(TextButton, 'Yes'), findsOneWidget);
    expect(calls, isEmpty);

    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    expect(find.text('Check for updates?'), findsNothing);
    expect(p.getBool(keyEnabled), isFalse);
    expect(calls, isEmpty);
  });

  testWidgets('question: back closes it as No', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpHome(tester);
    expect(find.text('Check for updates?'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Check for updates?'), findsNothing);
    expect((await prefs()).getBool(keyEnabled), isFalse);
    expect(calls, isEmpty);
  });

  testWidgets('question: tapping outside closes it as No', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpHome(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Check for updates?'), findsNothing);
    expect((await prefs()).getBool(keyEnabled), isFalse);
    expect(calls, isEmpty);
  });

  testWidgets('question: Learn more opens only on tap', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpHome(tester);
    expect(opened, isEmpty);
    await tester.tap(find.text('Learn more'));
    expect(opened, [learnMoreUrl]);
    expect(calls, isEmpty);
  });

  testWidgets('question: Yes switches on, checks and shows the banner', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpHome(tester);
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect((await prefs()).getBool(keyEnabled), isTrue);
    expect(calls, hasLength(1));
    expect(find.text('Glassbed 0.9.0 is available'), findsOneWidget);
  });

  testWidgets('never asked twice', (tester) async {
    SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: false});
    await pumpHome(tester);
    expect(find.text('Check for updates?'), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets('banner: Update opens the APK and explains the install, Later hides it',
      (tester) async {
    SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: true});
    await pumpHome(tester);
    expect(calls, hasLength(1));
    expect(find.text('Glassbed 0.9.0 is available'), findsOneWidget);

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(opened.single.toString(),
        'https://github.com/ARFEP-IT-Service/Glassbed/releases/download/android-v0.9.0/Glassbed-android-0.9.0-arm64-v8a.apk');
    expect(find.textContaining('Install the downloaded APK'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.text("What's new"));
    expect(opened.last.toString(),
        'https://github.com/ARFEP-IT-Service/Glassbed/releases/tag/android-v0.9.0');

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.text('Glassbed 0.9.0 is available'), findsNothing);
  });

  testWidgets('settings: Check now only when switched on', (tester) async {
    SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: false});
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(body: ListView(children: extras.settingsSection(context))),
      ),
    ));
    await tester.pumpAndSettle();
    final checkNow = find.widgetWithText(ListTile, 'Check now');
    expect(tester.widget<ListTile>(checkNow).enabled, isFalse);
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect((await prefs()).getBool(keyEnabled), isTrue);
    expect(calls, isEmpty);
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(find.text('Glassbed 0.9.0 is available'), findsOneWidget);
  });

  testWidgets('banner: in-app update shows progress and Cancel, then the allow-install hint',
      (tester) async {
    SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: true});
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('glassbed_ui')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final body = StreamController<List<int>>();
    final installer = FakeInstaller(dir, results: [InstallResult.needsPermission]);
    final c = UpdateController(
      newClient: () => MockClient.streaming((request, _) async =>
          request.url.toString().endsWith('.sha256')
              ? http.StreamedResponse(Stream.value(utf8.encode('$apkHash  $apk')), 200)
              : http.StreamedResponse(body.stream, 200, contentLength: apkBytes.length)),
      deviceAbi: () async => 'arm64-v8a',
      installer: installer,
    )..release = withSha('0.9.0');
    final ui = UpdateExtras(c, openUrl: (url) async {
      opened.add(url);
      return true;
    });
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => Scaffold(body: ListView(children: [ui.homeBanner(context)]))),
    ));
    expect(find.text('Glassbed 0.9.0 is available'), findsOneWidget);

    // The download does real file I/O, so it runs outside the test's fake clock; the button
    // calls exactly this (UpdateExtras.update → downloadAndInstall).
    late Future<UpdateOutcome> running;
    await tester.runAsync(() async {
      running = c.downloadAndInstall();
      body.add(apkBytes.sublist(0, 100 * 1024));
      while (c.received == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();
    expect(find.text('Downloading Glassbed 0.9.0… 0.1 of 0.3 MB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Later'), findsNothing);

    await tester.runAsync(() async {
      body.add(apkBytes.sublist(100 * 1024));
      await body.close();
      expect(await running, UpdateOutcome.needsPermission);
    });
    await tester.pump();
    expect(installer.installed, hasLength(1));
    expect(find.text('Allow Glassbed to install updates, then tap Update again.'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
    expect(opened, isEmpty);
  });
}
