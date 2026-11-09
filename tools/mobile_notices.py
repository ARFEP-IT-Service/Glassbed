"""License notices for the Android app, from what the release APK actually contains.

Sources (all from the real build, nothing hard-coded per package):
  * Dart packages compiled into libapp.so – Flutter's size analysis
    (flutter build apk --release --analyze-size --target-platform android-arm64)
  * Java/Kotlin libraries – Gradle's releaseRuntimeClasspath
  * native libraries – the lib/ folder of the APK

Writes mobile/THIRD_PARTY_NOTICES.md and mobile/licenses/*.txt. Stops when a component has no
license file, an unknown license, a GPL-family license, or comes from Google Play services /
Firebase (the app must not contain them).

    python tools/mobile_notices.py --size-json <apk-code-size-analysis.json> --apk <app-release.apk>
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOBILE = ROOT / "mobile"
OUT_DIR = MOBILE / "licenses"
NOTICES = MOBILE / "THIRD_PARTY_NOTICES.md"
APACHE = (ROOT / "tools" / "licenses" / "Apache-2.0.txt").read_text(encoding="utf-8").strip()
FORBIDDEN_GROUPS = ("com.google.android.gms", "com.google.firebase", "com.google.android.play",
                    "com.google.mlkit", "com.crashlytics", "io.sentry")

# Java/Kotlin groups and their license (checked against the resolved classpath; unknown = stop)
JAVA_LICENSES = {
    "androidx.": ("Apache-2.0", "https://developer.android.com/jetpack/androidx"),
    "org.jetbrains.kotlin": ("Apache-2.0", "https://kotlinlang.org/"),
    "org.jetbrains.kotlinx": ("Apache-2.0", "https://github.com/Kotlin/kotlinx.coroutines"),
    "org.jetbrains:annotations": ("Apache-2.0", "https://github.com/JetBrains/java-annotations"),
    "org.jspecify": ("Apache-2.0", "https://jspecify.dev/"),
    "com.google.guava": ("Apache-2.0", "https://github.com/google/guava"),
    "com.google.errorprone": ("Apache-2.0", "https://errorprone.info/"),
    "com.getkeepsafe.relinker": ("Apache-2.0", "https://github.com/KeepSafe/ReLinker"),
    "com.squareup.okio": ("Apache-2.0", "https://github.com/square/okio"),
}

# native libraries in the APK and where their license comes from:
# "dart:<package>" – that Dart package must be in the APK, "java:<prefix>" – a library with that prefix
NATIVE_LIBS = {
    "libflutter.so": "flutter",                     # Flutter engine (component added below)
    "libapp.so": "app",                             # Glassbed's and the packages' compiled Dart code
    "libdartjni.so": "dart:jni",                    # JNI bridge of the jni package
    "libdatastore_shared_counter.so": "java:androidx.datastore",
}


def classify(text: str) -> str:
    t = " ".join(text.split())
    if re.search(r"GNU (Lesser |Library |Affero )?General Public License", t, re.I) and \
            "Permission is hereby granted" not in t and "Redistribution and use" not in t:
        return "GPL-family"
    if "Apache License" in t and "Version 2.0" in t:
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in t:
        return "MIT"
    if "Redistribution and use in source and binary forms" in t:
        return "BSD-3-Clause" if re.search(r"Neither the name|names of its contributors", t) else "BSD-2-Clause"
    if "provided 'as-is', without any express or implied warranty" in t:
        return "Zlib"
    return "unknown"


def pub_cache() -> Path:
    env = os.environ.get("PUB_CACHE")
    if env:
        return Path(env)
    if sys.platform == "win32":
        return Path(os.environ["LOCALAPPDATA"]) / "Pub" / "Cache"
    return Path.home() / ".pub-cache"


def flutter_root() -> Path:
    flutter = subprocess.run(["flutter.bat" if sys.platform == "win32" else "flutter", "--version",
                              "--machine"], capture_output=True, text=True, check=True, cwd=MOBILE)
    return Path(json.loads(flutter.stdout[flutter.stdout.index("{"):])["flutterRoot"])


# --------------------------------------------------------------------------- Dart
def dart_packages(size_json: Path) -> set[str]:
    names = set()

    def walk(node):
        n = node.get("n", "")
        if n.startswith("package:"):
            names.add(n.split(":", 1)[1].split("/")[0])
        for child in node.get("children", []):
            walk(child)

    walk(json.loads(size_json.read_text(encoding="utf-8")))
    return names


def package_versions() -> dict[str, tuple[str, str]]:
    lock = (MOBILE / "pubspec.lock").read_text(encoding="utf-8")
    out = {}
    for m in re.finditer(r"^  ([a-z0-9_]+):\n((?:    .*\n)+)", lock, re.M):
        body = m.group(2)
        version = re.search(r'version: "([^"]+)"', body).group(1)
        source = re.search(r"source: (\w+)", body).group(1)
        out[m.group(1)] = (version, source)
    return out


# --------------------------------------------------------------------------- Java / native
def java_dependencies() -> set[str]:
    gradlew = MOBILE / "android" / ("gradlew.bat" if sys.platform == "win32" else "gradlew")
    r = subprocess.run([str(gradlew), "-q", ":app:dependencies", "--configuration", "releaseRuntimeClasspath"],
                       cwd=gradlew.parent, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("ERROR: gradle dependencies failed\n" + r.stderr[-2000:])
    deps = set()
    for line in r.stdout.splitlines():
        m = re.search(r"--- ([\w.\-]+):([\w.\-]+):([\w.\-]+)(?: -> ([\w.\-]+))?", line)
        if m and "(c)" not in line:
            deps.add(f"{m.group(1)}:{m.group(2)}:{m.group(4) or m.group(3)}")
    return deps


def native_libs(apk: Path) -> set[str]:
    with zipfile.ZipFile(apk) as z:
        return {Path(n).name for n in z.namelist() if n.startswith("lib/") and n.endswith(".so")}


# --------------------------------------------------------------------------- main
def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--size-json", type=Path, required=True)
    ap.add_argument("--apk", type=Path, required=True)
    args = ap.parse_args()

    errors, components = [], []      # component: name, version, license, url, texts, note
    versions = package_versions()
    froot = flutter_root()

    # Flutter framework + engine (libflutter.so, the Dart runtime and the engine's third-party code)
    engine_license = froot / "bin" / "cache" / "pkg" / "sky_engine" / "LICENSE"
    components.append(dict(
        name="Flutter (framework, engine, Dart runtime)", version=(froot / "version").read_text().strip()
        if (froot / "version").is_file() else "3.47.9", license="BSD-3-Clause (and the licenses listed in it)",
        url="https://flutter.dev/", texts=[("Flutter LICENSE", (froot / "LICENSE").read_text(encoding="utf-8").strip()),
                                          ("Flutter engine and its third-party components", engine_license.read_text(encoding="utf-8").strip())],
        note="libflutter.so, the Flutter framework packages (flutter, flutter_localizations) and the Dart runtime."))

    sdk_packages = {"flutter", "flutter_localizations", "flutter_web_plugins", "sky_engine"}
    used = sorted(dart_packages(args.size_json) - sdk_packages - {"glassbed"})   # glassbed = the app
    for name in used:
        if name not in versions:
            errors.append(f"Dart package {name} is in the APK but not in pubspec.lock")
            continue
        version, source = versions[name]
        if source != "hosted":
            errors.append(f"Dart package {name} has source {source}")
            continue
        folder = pub_cache() / "hosted" / "pub.dev" / f"{name}-{version}"
        lic_files = [p for p in folder.glob("*") if p.is_file() and re.match(r"(?i)^(license|copying)", p.name)]
        if not lic_files:
            errors.append(f"Dart package {name} {version}: no LICENSE file")
            continue
        # the main LICENSE decides; further files (e.g. LICENSE-other.md) are listed as extra licenses
        lic_files.sort(key=lambda f: (f.name.upper() != "LICENSE", f.name))
        texts = [(f.name, f.read_text(encoding="utf-8", errors="replace").strip()) for f in lic_files]
        kinds = [classify(text) for _, text in texts]
        bad = [f"{n}: {k}" for (n, _), k in zip(texts, kinds) if k in ("unknown", "GPL-family")]
        if bad:
            errors.append(f"Dart package {name} {version}: license " + ", ".join(bad))
            continue
        extra = sorted(set(kinds[1:]) - {kinds[0]})
        label = kinds[0] + (f" (parts: {', '.join(extra)})" if extra else "")
        components.append(dict(name=name, version=version, license=label,
                               url=f"https://pub.dev/packages/{name}", texts=texts, note="Dart package"))

    # Java/Kotlin libraries
    by_license: dict[str, list[str]] = {}
    java = sorted(java_dependencies())
    for dep in java:
        group = dep.split(":")[0]
        if group.startswith(FORBIDDEN_GROUPS):
            errors.append(f"forbidden library in the APK: {dep} (Google services / tracking)")
            continue
        if group == "io.flutter":
            continue                                    # the Flutter engine, see above
        match = next((v for prefix, v in JAVA_LICENSES.items() if dep.startswith(prefix)), None)
        if match is None:
            errors.append(f"Java/Kotlin library without license entry: {dep}")
            continue
        by_license.setdefault(match[0], []).append(dep)
    if by_license.get("Apache-2.0"):
        libs = by_license["Apache-2.0"]
        components.append(dict(name="AndroidX, Kotlin and other Java libraries", version=f"{len(libs)} libraries",
                               license="Apache-2.0", url="https://developer.android.com/jetpack/androidx",
                               texts=[("Libraries", "\n".join(libs)), ("Apache License 2.0", APACHE)],
                               note="Java/Kotlin libraries in the APK (Gradle releaseRuntimeClasspath)."))

    # native libraries
    dart_names = {c["name"] for c in components}
    for so in sorted(native_libs(args.apk)):
        source = NATIVE_LIBS.get(so)
        if source is None:
            errors.append(f"native library {so} has no license entry")
        elif source.startswith("dart:") and source[5:] not in dart_names:
            errors.append(f"native library {so} belongs to Dart package {source[5:]}, which has no entry")
        elif source.startswith("java:") and not any(d.startswith(source[5:]) for d in java):
            errors.append(f"native library {so} belongs to {source[5:]}, which is not on the classpath")

    if errors:
        sys.exit("ERROR: license collection failed\n  " + "\n  ".join(errors))

    OUT_DIR.mkdir(exist_ok=True)
    for old in OUT_DIR.glob("*.txt"):
        old.unlink()
    rule = "=" * 78
    rows = []
    for c in components:
        slug = re.sub(r"[^A-Za-z0-9]+", "-", c["name"]).strip("-")
        body = f"{c['name']} {c['version']}\nLicense: {c['license']}\nWebsite: {c['url']}\nNote: {c['note']}\n"
        for label, text in c["texts"]:
            body += f"\n{rule}\n{label}\n{rule}\n\n{text}\n"
        (OUT_DIR / f"{slug}.txt").write_text(body, encoding="utf-8", newline="\n")
        rows.append(f"| [{c['name']}]({c['url']}) | {c['version']} | {c['license']} | `licenses/{slug}.txt` |")
    NOTICES.write_text(
        "# Third-party notices – Glassbed for Android\n\n"
        "Glassbed for Android is licensed under the MIT License (see `LICENSE` in the repository root).\n"
        "The app contains the following third-party components, each under its own license. This file\n"
        "is generated by `tools/mobile_notices.py` from the release APK (Dart code compiled into the\n"
        "app, Java/Kotlin libraries, native libraries); the full texts are in `licenses/`. The app\n"
        "also shows all licenses under *Settings → Licenses*.\n\n"
        "| Component | Version | License | Text |\n|---|---|---|---|\n" + "\n".join(rows) + "\n",
        encoding="utf-8", newline="\n")
    print("\n".join(rows))
    print(f"wrote {len(components)} components to {OUT_DIR.relative_to(ROOT)} and {NOTICES.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
