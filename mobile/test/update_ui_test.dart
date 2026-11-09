import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/update/installer.dart';
import 'package:glassbed/update/update_controller.dart';
import 'package:glassbed/update/update_texts.dart' show allowInstallText, installStartedText;
import 'package:glassbed/update/update_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_download_test.dart' show FakeInstaller, apk, apkBytes, apkHash, github, withSha;
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
    expect(find.text(allowInstallText), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
    expect(opened, isEmpty);
  });
  /// Home with the banner and a settings button, like HomeScreen and SettingsScreen.
  Future<void> pumpHomeWithSettings(WidgetTester tester, UpdateExtras ui) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: ListView(children: [
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      Scaffold(appBar: AppBar(), body: ListView(children: ui.settingsSection(context))),
                ),
              ),
              child: const Text('settings'),
            ),
            ui.homeBanner(context),
          ]),
        );
      }),
    ));
  }

  testWidgets('settings: Check now shows a skipped version on the home screen too, Update there',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      keyAsked: true,
      keyEnabled: true,
      keySkipped: '0.9.0',
      keyLastCheck: DateTime.now().toUtc().toIso8601String(),
    });
    await pumpHomeWithSettings(tester, extras);
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('settings-update'));
    expect(row, findsNothing);

    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    // the result is said once, by the Update row
    expect(find.text('Glassbed 0.9.0 is available'), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Update')), findsOneWidget);
    expect((await prefs()).getString(keySkipped), isNull);

    // back home: the banner is there
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Glassbed 0.9.0 is available'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Update'), findsOneWidget);

    // Update in the settings: back home, the update starts there (here without an installer,
    // so the APK opens in the browser and its hint appears over the home screen)
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('Check now'), findsNothing);
    expect(find.text('settings'), findsOneWidget);
    expect(opened.single.toString(), endsWith('Glassbed-android-0.9.0-arm64-v8a.apk'));
    expect(find.textContaining('Install the downloaded APK'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Glassbed 0.9.0 is available'), findsOneWidget);
    expect(calls, hasLength(1));
  });

  testWidgets('settings: the Update row also comes from the daily check, not after Later',
      (tester) async {
    SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: true});
    await pumpHome(tester); // the daily check finds 0.9.0
    expect(calls, hasLength(1));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(body: ListView(children: extras.settingsSection(context))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-update')), findsOneWidget);
    expect(find.text('Glassbed 0.9.0 is available'), findsOneWidget);

    extras.controller.later();
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-update')), findsNothing);
  });

  testWidgets('allow install: back in the app the update goes on by itself', (tester) async {
    SharedPreferences.setMockInitialValues({
      keyAsked: true,
      keyEnabled: true,
      keyLastCheck: DateTime.now().toUtc().toIso8601String(),
    });
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('glassbed_ui')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final downloads = <http.BaseRequest>[];
    final installer =
        FakeInstaller(dir, results: [InstallResult.needsPermission, InstallResult.started]);
    final c = UpdateController(
      newClient: () => github(downloads),
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

    /// Leaves the app (Android's settings page) and comes back; the reused file is read and
    /// hashed for real, so that part runs outside the fake clock.
    Future<void> leaveAndComeBack() async {
      await tester.runAsync(() async {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        while (c.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
    }

    await tester.runAsync(() async {
      expect(await c.downloadAndInstall(), UpdateOutcome.needsPermission);
    });
    await tester.pump();
    expect(find.text(allowInstallText), findsOneWidget);
    expect(downloads, hasLength(4));

    // not allowed: nothing happens, the hint stays
    installer.allowed = false;
    await leaveAndComeBack();
    expect(installer.installed, hasLength(1));
    expect(find.text(allowInstallText), findsOneWidget);

    // allowed: the verified file goes to the installer, without a new download or a tap
    installer.allowed = true;
    await leaveAndComeBack();
    expect(installer.installed, hasLength(2));
    expect(downloads, hasLength(4));
    expect(c.outcome, UpdateOutcome.installStarted);
    expect(find.text(installStartedText.replaceAll('{version}', '0.9.0')), findsOneWidget);

    // coming back again does not start it a second time
    await leaveAndComeBack();
    expect(installer.installed, hasLength(2));
    expect(opened, isEmpty);
  });
}
