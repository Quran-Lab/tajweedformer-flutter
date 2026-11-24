#!/usr/bin/env python3
"""Builds the plugin the way an app does, at Android Gradle Plugin (AGP) versions other than the example's own.

CI only: it edits files in the checkout (or makes a throwaway app) and nothing it writes is committed.

Usage, from the repository root:

  # the example app at the newest stable AGP 9.x, with the newest stable Gradle 9.x
  python3 tool/agp_matrix.py pin --agp newest --gradle newest
  # the example app at the lowest AGP the current Flutter accepts (Flutter 3.50: 9.1.1)
  python3 tool/agp_matrix.py pin --agp 9.1.1 --gradle 9.5.0
  # an app on AGP 9 without the Flutter template's android.newDsl=false and android.builtInKotlin=false lines
  python3 tool/agp_matrix.py pin --agp newest --gradle newest --defaults
  # a fresh app from the running Flutter's own template, the plugin by path (for a Flutter older than the example's)
  python3 tool/agp_matrix.py fresh --out /tmp/agp_app
  python3 tool/agp_matrix.py pin --dir /tmp/agp_app/android --agp 8.13.2 --gradle 8.14.3

`pin` rewrites, in one app's android/ folder: the AGP and Kotlin plugin versions in settings.gradle.kts, the Gradle
distribution in gradle/wrapper/gradle-wrapper.properties, and (with --defaults) drops the two template flags from
gradle.properties. "newest" is read from Google's Maven (AGP: the highest stable version of --agp-major, default 9)
and from Gradle's version list (Gradle: the highest stable, not broken release of --gradle-major, default 9). It
prints what it set, so a CI log names the versions it built with.

`fresh` runs `flutter create` with the Flutter on PATH, so the app's settings are that Flutter's template (Flutter
3.44.9: AGP 9.0.1, 3.47.9: AGP 9.1.0, 3.50.0: AGP 9.3.1), adds quranlab_tajweedformer from this checkout by path,
and sets minSdk 26 (the SDK's minimum). The in-repo example needs Dart 3.14 (Flutter 3.50), so an older Flutter
builds a fresh app instead.

Why this exists (Flutter 4.0.4, 2026-11-24). Flutter 4.0.0 to 4.0.3 failed to configure in any app whose AGP is
older than 9.2 (every app made by the Flutter 3.44 or 3.47 template, AGP 9.0.1 or 9.1.0; Flutter 3.50's own minimum
9.1.1; AGP 8 apps):

  class com.android.build.gradle.internal.api.DefaultAndroidSourceSet_Decorated cannot be cast to class
  com.android.build.api.dsl.AndroidLibrarySourceSet (... loader @50700905; ... loader @1ffca457)

at the plugin's `android { sourceSets { getByName("main") { ... } } }`. The plugin's build file (Flutter 3.50's plugin
template) puts AGP 9.3.1 on its own buildscript classpath, so Gradle compiles that script against AGP 9.3.1, where a
library's source sets are AndroidLibrarySourceSet, a type AGP added in 9.2. The objects come from the app's older
AGP, loaded first, which has no such type: the cast fails, between two class loaders. Apps on AGP 9.2 or later
(including the example's 9.3.1, and 9.5.2) never saw it, which is why CI, building only the example, stayed green.
The block only registered src/main/kotlin and src/test/kotlin, which AGP and the Kotlin plugin use by default;
4.0.4 removes it, and the same Kotlin classes go into the AAR.

What was tried and kept or rejected:
- Removing the block (kept): green from AGP 8.13.2 to 9.5.2; the AAR's 164 classes are the same as 4.0.3's and the
  17 WireTest tests run.
- Keeping the block and dropping only the buildscript's AGP classpath line also configured at AGP 9.1.1 (that is how
  the cause was confirmed), but it changes how the plugin resolves AGP for every app; not needed for the fix.
- Flutter 3.41 cannot build the plugin on Android with or without the block (its Gradle plugin does not apply the
  Kotlin plugin to plugins, so `kotlin {` in the build file is unresolved; 3.44 and later apply it). A separate issue.
- Flutter 3.50 cannot build any app on AGP 8, before any plugin is configured (its Gradle plugin calls
  ApplicationExtension.getDefaultConfig() with AGP 9's signature, which AGP 8.13.2 lacks), so AGP 8 is checked with
  Flutter 3.47 and a fresh app.

Open: AGP 10 (Flutter 3.50 refuses it); raise --agp-major when Flutter accepts it.
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "packages/quranlab_tajweedformer"
EXAMPLE_ANDROID = PLUGIN / "example/android"
STABLE = re.compile(r"^\d+\.\d+\.\d+$")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "quranlab-ci-agp-matrix"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8")


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def newest_agp(major):
    xml = fetch("https://dl.google.com/android/maven2/com/android/tools/build/group-index.xml")
    m = re.search(r'<gradle versions="([^"]+)"', xml)
    if not m:
        sys.exit("agp_matrix: no com.android.tools.build:gradle versions in Google's Maven index")
    vs = [v for v in m.group(1).split(",") if STABLE.match(v) and v.split(".")[0] == str(major)]
    if not vs:
        sys.exit(f"agp_matrix: no stable AGP {major}.x in Google's Maven index")
    return max(vs, key=vkey)


def newest_gradle(major):
    rows = json.loads(fetch("https://services.gradle.org/versions/all"))
    vs = [r["version"] for r in rows
          if not (r.get("snapshot") or r.get("nightly") or r.get("releaseNightly") or r.get("broken")
                  or r.get("activeRc") or r.get("rcFor") or r.get("milestoneFor"))
          and re.match(r"^\d+\.\d+(\.\d+)?$", r["version"]) and r["version"].split(".")[0] == str(major)]
    if not vs:
        sys.exit(f"agp_matrix: no stable Gradle {major}.x in Gradle's version list")
    return max(vs, key=lambda v: vkey(v if v.count(".") == 2 else v + ".0"))


def read(path):
    with open(path, encoding="utf-8", newline="") as f:  # keep the file's own line endings
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def sub_once(path, pattern, repl, what):
    new, n = re.subn(pattern, repl, read(path))
    if n != 1:
        sys.exit(f"agp_matrix: {path}: expected one {what}, found {n}")
    write(path, new)


def pin(args):
    d = Path(args.dir).resolve()
    agp = newest_agp(args.agp_major) if args.agp == "newest" else args.agp
    gradle = newest_gradle(args.gradle_major) if args.gradle == "newest" else args.gradle
    settings = d / "settings.gradle.kts"
    sub_once(settings, r'(id\("com\.android\.application"\) version ")[^"]+(")', rf"\g<1>{agp}\g<2>", "AGP plugin line")
    if args.kgp:
        sub_once(settings, r'(id\("org\.jetbrains\.kotlin\.android"\) version ")[^"]+(")', rf"\g<1>{args.kgp}\g<2>",
                 "Kotlin plugin line")
    if gradle:
        sub_once(d / "gradle/wrapper/gradle-wrapper.properties", r"(gradle-)[0-9.]+(-(?:all|bin)\.zip)",
                 rf"\g<1>{gradle}\g<2>", "Gradle distribution")
    if args.defaults:
        props = d / "gradle.properties"
        lines = read(props).splitlines(keepends=True)
        keep = [ln for ln in lines if not re.search(r"android\.(newDsl|builtInKotlin)|flag was added by the Flutter", ln)]
        write(props, "".join(keep))
    kgp_line = re.search(r'id\("org\.jetbrains\.kotlin\.android"\) version "([^"]+)"', read(settings))
    dist = re.search(r"gradle-([0-9.]+)-", read(d / "gradle/wrapper/gradle-wrapper.properties"))
    flags = [ln.strip() for ln in read(d / "gradle.properties").splitlines()
             if re.match(r"android\.(newDsl|builtInKotlin)", ln)]
    print(f"agp_matrix: {d}: AGP {agp}, Kotlin plugin {kgp_line.group(1) if kgp_line else '(none)'}, "
          f"Gradle {dist.group(1) if dist else '?'}, flags {flags or 'AGP defaults'}")


def fresh(args):
    out = Path(args.out).resolve()
    if out.exists():
        sys.exit(f"agp_matrix: {out} exists")
    flutter = "flutter.bat" if sys.platform == "win32" else "flutter"
    subprocess.run([flutter, "create", "--platforms", "android", "--org", "dev.agpmatrix", "--project-name",
                    "agp_app", str(out)], check=True, stdout=subprocess.DEVNULL)
    pub = out / "pubspec.yaml"
    text = read(pub)
    dep = f"  quranlab_tajweedformer:\n    path: {PLUGIN.as_posix()}\n"
    text, n = re.subn(r"(?m)^dependencies:\n  flutter:\n    sdk: flutter\n", lambda m: m.group(0) + dep, text)
    if n != 1:
        sys.exit("agp_matrix: the template's pubspec.yaml has no dependencies: flutter: block")
    write(pub, text)
    sub_once(out / "android/app/build.gradle.kts", r"minSdk = flutter\.minSdkVersion", "minSdk = 26", "minSdk line")
    subprocess.run([flutter, "pub", "get"], cwd=out, check=True, stdout=subprocess.DEVNULL)
    print(f"agp_matrix: fresh app at {out} (this Flutter's template), quranlab_tajweedformer from {PLUGIN}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("pin", help="set one app's AGP, Kotlin plugin and Gradle versions")
    p.add_argument("--dir", default=str(EXAMPLE_ANDROID), help="the app's android/ folder (default: the example's)")
    p.add_argument("--agp", required=True, help="an AGP version, or newest")
    p.add_argument("--agp-major", type=int, default=9)
    p.add_argument("--gradle", help="a Gradle version, or newest (default: unchanged)")
    p.add_argument("--gradle-major", type=int, default=9)
    p.add_argument("--kgp", help="the Kotlin Gradle plugin version (default: unchanged)")
    p.add_argument("--defaults", action="store_true", help="drop android.newDsl and android.builtInKotlin")
    p.set_defaults(func=pin)
    f = sp.add_parser("fresh", help="a fresh app from the running Flutter's template, the plugin by path")
    f.add_argument("--out", required=True)
    f.set_defaults(func=fresh)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
