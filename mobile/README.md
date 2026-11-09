# Glassbed for Android

Scan on network multifunction printers from an Android phone: find the printer (or enter its IP
address), scan from the glass or the feeder in colour, grey or B/W, sort, rotate, crop, straighten,
adjust brightness/contrast, redact (black, white or blur – burned in), save as PDF/JPG/PNG through the
Android file picker and share. Same look, icon and texts as the Windows app (`../shared/`).

Download: GitHub releases *Glassbed for Android* (see the main README).

## Privacy

The app only talks to your printer on the local network (eSCL on port 80, IPP status on port 631,
mDNS to find it). No analytics, no crash reporting, no Firebase or other Google services, no ads.
Every request is checked against local network addresses before it is sent. The legal pages open in
the browser only when tapped. Only the github variant can also ask GitHub (api.github.com) for a new
version – once you agreed, at most once a day; GitHub sees your IP address then.

| Permission | Why |
|---|---|
| `INTERNET` | needed for any network socket, used only for the printer on the local network |
| `CHANGE_WIFI_MULTICAST_STATE` | multicast lock while searching for printers (mDNS) |
| `ACCESS_LOCAL_NETWORK` | Android 17+: access to devices on the local network; asked when you first search, connect or scan |

No storage permission: files are saved through the system file picker.

## Build

Flutter 3.47.9 (pinned in `pubspec.yaml`, packages pinned in `pubspec.lock`), JDK 21, Android SDK
platform 37.

```bash
flutter pub get --enforce-lockfile
flutter analyze
flutter test
# two variants, one APK per processor type (unsigned without android/key.properties)
flutter build apk --release --split-per-abi --flavor github -t lib/main_github.dart
flutter build apk --release --split-per-abi --flavor play -t lib/main.dart
```

- **github** – the APKs on GitHub releases, with the optional update notice (asks once; at most one
  request a day to api.github.com, only after consent). *Update* downloads the APK for the device
  and its `.sha256` from the same release (HTTPS, only github.com and GitHub's download hosts,
  at most 200 MB), checks the SHA-256 and hands the file to Android's package installer, which
  asks the user. A file that does not match is deleted. Only this flavor has
  `REQUEST_INSTALL_PACKAGES` and the FileProvider (`android/app/src/github/`).
- **play** – for an app store later: no update check at all and no connection to GitHub; the
  workflow checks that its code contains nothing of the update feature.

Signed APKs are built only by the *Mobile build* workflow inside the GitHub environment
`release` (approval required); the keystore never leaves it.

Release signing uses `android/key.properties` (not in the repository) pointing to a keystore outside
the repository. `THIRD_PARTY_NOTICES.md` and `licenses/` are generated from the release APK by
`../tools/mobile_notices.py`; the launcher icons by `../tools/make_android_icons.py`; the shared texts by
`../tools/export_shared.py`.
