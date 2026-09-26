# Plezy — Meta Quest / Horizon OS fork

A native **2D panel** build of Plezy for Horizon OS. Not an immersive VR app: no
Spatial SDK, no VR intent category. Horizon runs it as an ordinary resizable
Android window, which is what gives it snap points, move/scale, minimize/close
and the system keyboard overlay (including the dictation mic) for free.

The fork is built to stay close to upstream. Exactly two upstream files are
touched, by 26 added lines and **zero modified or deleted lines**; everything
else lives in new files upstream has no path for.

## Repository layout

| Remote | URL |
| --- | --- |
| `origin` | `https://github.com/HellboundGlory/plezy` (your fork) |
| `upstream` | `https://github.com/edde746/plezy` |

| Branch | Role |
| --- | --- |
| `main` | Clean mirror of `upstream/main`. Never commit here. |
| `quest` | `main` + the Quest commits. All work happens here. |

## Syncing with Plezy upstream

Keeping `main` pristine means the sync is always a clean rebase of a tiny
patch set:

```bash
git fetch upstream

# Fast-forward the pristine mirror
git checkout main
git merge --ff-only upstream/main
git push origin main

# Replay the Quest commits on top
git checkout quest
git rebase main
flutter pub get
git push --force-with-lease origin quest
```

If the rebase ever conflicts it will be in one of only two files —
`android/app/build.gradle.kts` or `android/settings.gradle.kts` — and the
resolution is always "keep upstream's version of the surrounding code, re-add
the `QUEST` block". Nothing in `android/quest/`, `lib/quest/` or `test/quest/`
can conflict, because upstream has no such paths.

## Toolchain

The versions the build pins (`android/app/build.gradle.kts`):

| Component | Version |
| --- | --- |
| Flutter | 3.47.2 stable (Dart 3.13.2) |
| JDK | **21** — Gradle/AGP reject 25 |
| Android platform | android-36 |
| Build tools | 36.1.0 |
| NDK | 29.0.14206865 |
| CMake | 4.1.2 |

```bash
export PATH=/home/james/flutter/bin:/home/james/Android/Sdk/platform-tools:$PATH
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
export ANDROID_HOME=/home/james/Android/Sdk
export ANDROID_SDK_ROOT=/home/james/Android/Sdk
```

This repo carries that block as `.questenv`, so `source .questenv` is enough.

Missing SDK pieces install with:

```bash
sdkmanager "platforms;android-36" "build-tools;36.1.0" \
           "ndk;29.0.14206865" "cmake;4.1.2" "platform-tools"
```

## Building the Quest APK

```bash
source .questenv
QUEST=1 flutter build apk --release \
  --dart-define=QUEST_BUILD=true \
  --target-platform=android-arm64
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

`QUEST=1` is the whole switch. It does three things and nothing else:

1. Restricts the ABI to `arm64-v8a`, the only architecture Horizon runs. This
   matters a lot: the default build is a three-ABI fat APK (armeabi-v7a,
   arm64-v8a, x86_64) at ~257 MB, of which ~155 MB is dead weight on Quest.

   Note the `clear()` in the `QUEST` block. Flutter's Gradle plugin calls
   `abiFilters.clear(); addAll(PLATFORM_ABI_LIST)` at plugin-apply time, which
   is *before* the `android {}` block runs — so the `abiFilters += ...` idiom
   unions with all three ABIs and filters nothing. `--target-platform` alone
   is not enough either: it only governs Flutter's own engine libraries, not
   libmpv/libass/Cronet. Both are needed.
2. Offsets `versionCode` by `+4000`, so Quest builds never collide with Play
   (`+0`) or Amazon (`+3000`) version codes.
3. Puts the `:quest` module on the classpath, which merges the Horizon panel
   attributes into the manifest.

`--dart-define=QUEST_BUILD=true` is optional; it only sets the `kQuestBuild`
hint in `lib/quest/quest_platform.dart`.

### Signing — required, not optional

`flutter build apk --release` produces an **unsigned** APK unless
`android/key.properties` exists, and Horizon refuses it with
`INSTALL_PARSE_FAILED_NO_CERTIFICATES`. (The comment in
`android/app/build.gradle.kts` claims it falls back to debug signing without
`key.properties`; it does not — AGP simply leaves `release` unsigned.)

This machine already has a keystore set up for the fork:

| | |
| --- | --- |
| Keystore | `~/.keystores/plezy-quest.jks` |
| Alias | `plezy-quest` |
| Password (store and key) | `plezyquest` |
| Validity | 10000 days |

and `android/key.properties` points at it. Both `key.properties` and `*.jks`
are already in upstream's `android/.gitignore`, so neither is committed — which
also means **the keystore is not backed up by git**. Copy it somewhere safe; if
you lose it you cannot upgrade an existing install in place, only uninstall and
reinstall.

To recreate it from scratch:

```bash
keytool -genkeypair -v -keystore ~/.keystores/plezy-quest.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias plezy-quest \
  -storepass plezyquest -keypass plezyquest \
  -dname "CN=Plezy Quest Fork, OU=Private, O=HellboundGlory, C=GB"

cat > android/key.properties <<'EOF'
storeFile=/home/james/.keystores/plezy-quest.jks
storePassword=plezyquest
keyAlias=plezy-quest
keyPassword=plezyquest
EOF
```

The same keystore signs the Fire TV build, so both targets share one identity.

## Self-updating sideload builds

Both the Quest and Fire TV builds can install their own updates from your
fork's GitHub Releases. The default (Play Store) and desktop builds are
untouched — self-updating violates Play policy, and desktop keeps upstream's
Sparkle path.

### How it works

Plezy's existing `UpdateService` already polls
`api.github.com/repos/<repo>/releases/latest` on a 6-hour cooldown, with
skip-this-version support, and shows the update dialog. This fork changes only
where that dialog's primary button goes: on a sideload build it downloads the
release asset for this target and hands it to Android's package installer,
instead of opening the release page in a browser. Everything else — the check,
the cooldown, the dialog, the Settings entry — is upstream's.

The install needs no native code. `background_downloader` (already a Plezy
dependency) has `openFile(mimeType:)`, which builds an `ACTION_VIEW` intent with
a FileProvider `content://` URI and `FLAG_GRANT_READ_URI_PERMISSION`. Verified on
Quest 3: `com.android.packageinstaller/.InstallStart` resolves exactly that
intent. `REQUEST_INSTALL_PACKAGES` comes from the `:selfupdate` manifest module.
The user still confirms each install in the system dialog.

If anything fails — no matching asset, download error, installer refused — it
silently falls back to upstream's browser behaviour.

### Build flags

```bash
# Quest
QUEST=1 flutter build apk --release --target-platform=android-arm64 \
  --dart-define=QUEST_BUILD=true \
  --dart-define=ENABLE_UPDATE_CHECK=true \
  --dart-define=UPDATE_GITHUB_REPO=HellboundGlory/plezy \
  --dart-define=SELF_UPDATE_TARGET=quest

# Fire TV
AMAZON=1 flutter build apk --release \
  --dart-define=ENABLE_UPDATE_CHECK=true \
  --dart-define=UPDATE_GITHUB_REPO=HellboundGlory/plezy \
  --dart-define=SELF_UPDATE_TARGET=firetv
```

Omit `SELF_UPDATE_TARGET` and the build reverts to notify-and-open-browser.
Omit `ENABLE_UPDATE_CHECK` and it does not check at all.

### Asset naming is the contract

`SelfUpdateTarget.assetMarker` matches a release asset whose filename ends in
`.apk` and contains `plezy-quest` or `plezy-firetv`. Name the release assets
accordingly or the app will not find its update:

| Target | Asset filename |
| --- | --- |
| Quest | `plezy-quest-<version>-arm64.apk` |
| Fire TV | `plezy-firetv-<version>.apk` |

### Cutting a release

`UpdateService` compares the release **tag** against the installed
`versionName`, so tag with the plain version and bump `pubspec.yaml` first.
`versionCode` must also increase for Android to accept the upgrade — the
`+4000` / `+3000` offsets are derived from the pubspec build number, so bumping
it covers both.

```bash
# 1. bump `version:` in pubspec.yaml, e.g. 2.17.2+147, and commit

# 2. build both targets (see flags above), copying each out
cp build/app/outputs/flutter-apk/app-release.apk \
   ~/Downloads/Projects/plezy-apks/plezy-quest-2.17.2-arm64.apk
cp build/app/outputs/flutter-apk/app-release.apk \
   ~/Downloads/Projects/plezy-apks/plezy-firetv-2.17.2.apk

# 3. publish
gh release create v2.17.2 \
  ~/Downloads/Projects/plezy-apks/plezy-quest-2.17.2-arm64.apk \
  ~/Downloads/Projects/plezy-apks/plezy-firetv-2.17.2.apk \
  --title "v2.17.2" --notes "..."
```

Installed builds pick it up within 6 hours, or immediately via
**Settings → Check for updates**.

### Signing must not change

An APK signed with a different key cannot upgrade an existing install. Keep
using `~/.keystores/plezy-quest.jks` for every release, for both targets.

### Licensing note

Plezy is GPL-3.0, which permits distributing binaries as long as the
corresponding source is available under the same licence and the notices are
preserved. Publishing the APKs from this public fork satisfies that, since the
source that built them is the repo they are attached to. The README carries the
"modified version" notice GPLv3 §5a requires. Do not publish builds from a
private repo without also making that source available to recipients.

## Both targets write to the same path

`flutter build apk` always produces
`build/app/outputs/flutter-apk/app-release.apk`, whichever switch you used — so
a Fire TV build **silently overwrites** the Quest APK and vice versa. There is
no per-variant filename because the fork uses env vars rather than product
flavors (see the end of this file).

Copy each build out as you make it. Finished APKs live outside the repo so
`flutter clean` cannot delete them:

```bash
mkdir -p ~/Downloads/Projects/plezy-apks

# Quest
QUEST=1 flutter build apk --release \
  --dart-define=QUEST_BUILD=true --target-platform=android-arm64
cp build/app/outputs/flutter-apk/app-release.apk \
   ~/Downloads/Projects/plezy-apks/plezy-quest-$(git describe --always)-arm64.apk

# Fire TV
AMAZON=1 flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk \
   ~/Downloads/Projects/plezy-apks/plezy-firetv-$(git describe --always).apk
```

Check which one you are holding with:

```bash
aapt2 dump badging <apk> | grep -E "^package|native-code"
```

`versionCode` disambiguates them: Quest is `+4000` (e.g. 4146), Fire TV `+3000`
(3146), a plain build `+0` (146).

## Sideloading with ADB

Developer mode must be enabled for the headset (Meta Horizon phone app →
your headset → Developer Mode), then plug in over USB-C and accept the
*Allow USB debugging* prompt inside the headset.

```bash
adb devices                     # confirm the headset appears
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

`-r` reinstalls in place and keeps app data. If it fails with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` the signing key changed:

```bash
adb uninstall com.edde746.plezy
adb install build/app/outputs/flutter-apk/app-release.apk
```

The app then appears in the headset's app library under **Unknown Sources**
(sideloaded apps are not listed with Store apps).

Logs:

```bash
adb logcat -s flutter:V ActivityManager:I
```

## Building the Fire TV / Amazon version

Unchanged from upstream — the Quest work does not touch this path:

```bash
source .questenv
AMAZON=1 flutter build apk --release
```

Do not set `AMAZON` and `QUEST` together: both write `versionCode` and
`abiFilters`, and `QUEST` would win because its block runs second.

**This fork patches upstream's `AMAZON` block.** Upstream uses
`abiFilters += listOf("armeabi-v7a", "arm64-v8a")`, which — because of the
plugin-apply ordering described above — does not actually drop `x86_64`, so
stock Amazon APKs ship a dead x86_64 slice. This fork adds `abiFilters.clear()`
there, which drops x86_64 and cuts the Fire TV APK from **256.7 MB to 169.4 MB**
(measured; `native-code: 'arm64-v8a' 'armeabi-v7a'`, `versionCode` still 3146).
Every Fire TV device is ARM, so nothing is lost.

This is the one place the fork deliberately changes upstream *behaviour* rather
than just adding to it, so it is the one change worth re-checking after a
rebase. It is still an insertion (`+6, -0`) and sits directly above the line it
modifies the effect of.

## What Horizon OS actually needed

Plezy's stock ARM64 APK already runs on Quest — Horizon hosts unmodified
Android APKs as 2D windows, and upstream already declares
`android.hardware.touchscreen` as `required="false"`, which is the usual
blocker. The Quest overlay only adds window polish:

| Manifest addition | Why |
| --- | --- |
| `android:resizeableActivity="true"` | Earns the native Horizon window affordances: snap points, move/scale, minimize/close. |
| `<layout defaultWidth=912dp defaultHeight=750dp minWidth=384dp minHeight=500dp>` | Horizon's panel bounds are min 384×500dp / max 1440×1000dp; 912×750 is the midpoint and is the size the panel opens at. |
| `<uses-feature android:glEsVersion="0x00030001">` | Flutter's renderer needs GLES 3; Quest is GLES 3.2 hardware. |
| `com.oculus.supportedDevices` | Inert when sideloading, required if this is ever submitted to the Horizon Store. |

Deliberately **not** declared, because any of them would make Horizon treat this
as an immersive app instead of a 2D panel — which forfeits the system keyboard
overlay and the native window chrome:

- `<category android:name="com.oculus.intent.category.VR" />`
- `<uses-feature android:name="android.hardware.vr.headtracking" />`
- passthrough / `vr.focusaware` metadata

## Input on Quest

The controller raycast and hand-tracking pinch arrive as ordinary pointer
events, so Plezy's existing tap handling works untouched. Bluetooth gamepads
pair with the headset and drive Plezy's existing D-pad/focus navigation with no
Quest-specific code.

### Thumbstick navigation (fixed)

Quest Touch controllers report their thumbstick on the **right-stick** axes —
`ABS_RX`/`ABS_RY`, surfaced to Android as `AXIS_RX`/`AXIS_RY`. Confirmed with
`getevent` on a Quest 3: across a full stick sweep the controllers emit only
`ABS_RX`/`ABS_RY` and **never** `ABS_X`/`ABS_Y`. They also expose no scroll
wheel (`REL_WHEEL`/`REL_HWHEEL` are absent), so the stick is a joystick axis,
not a scroll source.

Two stacked gaps meant none of that reached the UI, which is why the stick could
not scroll Home, Explore, or a library's Recommended rows:

1. `universal_gamepad` 1.5.8 maps only `AXIS_X`, `AXIS_Y`, `AXIS_Z` and
   `AXIS_RZ`. `AXIS_RX`/`AXIS_RY` were dropped in the plugin before ever
   reaching Dart. Fixed in `packages/universal_gamepad`, vendored the same way
   upstream already vendors `saf_util`.
2. `GamepadService._handleAxis` only acted on `leftStickX`/`leftStickY`, with
   every other axis hitting `default: break`. It now routes the right stick
   through the same handlers, so either stick navigates.

Both halves are needed; either alone leaves the stick dead. Confirmed by
Plezy's own gamepad diagnostics (`--dart-define=PLEZY_TEXT_INPUT_DIAGNOSTICS=true`)
logging nothing at all during 45 seconds of stick movement before the fix.

Note that Horizon reports **no touchscreen**, and Plezy's `TvDetection`
(`android/app/src/main/kotlin/com/edde746/plezy/TvDetection.kt`) counts absence
of a touchscreen as a TV signal — so Plezy renders its **TV/10-foot UI** on
Quest. That is left as-is deliberately: it is a reasonable fit for a large
virtual panel, it keeps the fork's behaviour identical to upstream, and Settings
already exposes a force-TV toggle if you want to experiment. See "Known
considerations" below.

## Verified on device

Confirmed on a Quest 3 (`eureka`, Horizon OS on Android 14) over ADB:

- Installs and launches; Plezy's sign-in screen (Plex / Jellyfin / Emby)
  renders correctly in the panel.
- `primaryCpuAbi=arm64-v8a`, `versionCode=4146`, `minSdk=25 targetSdk=36`.
- The window manager reports `isResizeable=true supportsMultiWindow=true`
  with `minWidth=480 minHeight=625` px — exactly the 384×500 dp from the
  overlay at the headset's 1.25 density — and the panel opens at
  `1140×938` px, which is the configured 912×750 dp. The `<layout>` bounds
  are being honoured.
- Horizon's `KeyboardInputMethodService` binds to the app, so the system
  keyboard overlay (and its dictation mic) works — the payoff for staying a
  2D panel app rather than declaring VR.
- Renders through Adreno Vulkan. No fatals in logcat.
- `adb shell pm list features` confirms Horizon exposes **no**
  `android.hardware.touchscreen`, `leanback` or `television` feature, and does
  expose `oculus.hardware.standalone_vr`. Device ABI list is
  `arm64-v8a,armeabi-v7a,armeabi` — no x86, confirming the arm64-only APK.

## Known considerations

None of these are bugs in the fork; they are consequences of running upstream
Plezy unmodified on Horizon OS, listed so they are a deliberate choice rather
than a surprise.

**Plezy renders its TV UI on Quest.** `TvDetection.kt` counts "no touchscreen"
as a TV signal, and Horizon reports no touchscreen, so Quest takes the leanback
path. This was left alone on purpose — overriding it would mean patching shared
upstream Kotlin and Dart, which is exactly the divergence this fork is built to
avoid. The 10-foot layout is a defensible fit for a large virtual panel and the
laser pointer still taps every control. If you decide you want the touch layout
instead, that is a one-line change in the Quest overlay's favour, but it should
be a deliberate decision made after using it on the headset.

**Audio passthrough is advertised as available.** `PlatformDetector.supportsAudioPassthrough()`
returns true for `Platform.isAndroid && isTV()`, so it will be offered on Quest.
The headset cannot bitstream AC3/EAC3, so if you enable it and a title fails to
play with audio, turn passthrough off in Settings. It is opt-in and defaults to
off, so this only bites if you go looking for it.

**Picture-in-picture is correctly disabled**, since `pictureInPictureAllowed()`
vetoes it for TV form factors. Horizon's own window manager already provides
the equivalent affordance by letting you resize and park the panel.

## Files this fork adds

```
android/quest/build.gradle.kts                  # code-free panel-overlay module
android/quest/src/main/AndroidManifest.xml      # the Horizon panel overlay
android/selfupdate/build.gradle.kts             # code-free permission module
android/selfupdate/src/main/AndroidManifest.xml # REQUEST_INSTALL_PACKAGES
lib/quest/quest_platform.dart                   # Quest/Horizon device detection
lib/selfupdate/self_update_target.dart          # target + release-asset selection
lib/selfupdate/apk_self_updater.dart            # download + hand to the installer
packages/universal_gamepad/                     # vendored 1.5.8 + AXIS_RX/RY fix
test/quest/quest_platform_test.dart
test/selfupdate/self_update_target_test.dart
test/services/gamepad_right_stick_quest_test.dart
QUEST_BUILD.md                                  # this file
.questenv                                       # toolchain environment
```

## Upstream files this fork modifies

Both changes are pure insertions guarded by `System.getenv("QUEST")`, so the
default and Amazon builds are byte-identical to upstream.

- `android/settings.gradle.kts` — `include(":quest")` and `include(":selfupdate")`
- `android/app/build.gradle.kts` — the `QUEST` block mirroring the existing
  `AMAZON` block, `abiFilters.clear()` in the `AMAZON` block, and the two
  conditional module dependencies
- `pubspec.yaml` — points `universal_gamepad` at the vendored copy, exactly as
  upstream already does for `saf_util`
- `lib/services/gamepad_service.dart` — routes the right stick through the
  existing navigation handlers
- `lib/services/update_service.dart` — repo and appcast URL become
  `String.fromEnvironment` with upstream's values as defaults
- `lib/utils/update_dialog.dart` — the primary button tries the self-updater
  before falling back to upstream's browser path
- `README.md` — the GPLv3 §5a "modified version" notice

Only `gamepad_service.dart` and the `AMAZON` `abiFilters.clear()` change
upstream *behaviour*; the rest either add new code paths or preserve upstream
defaults exactly. Those two are the ones to re-check after a rebase.

### Why not product flavors?

A `quest` product flavor would be the textbook AGP answer, but declaring any
flavor renames every Gradle variant (`assembleRelease` →
`assembleStandardRelease`) and makes `--flavor` mandatory on *every* build
command. That would break upstream's `android/fastlane/Fastfile`, the GitHub
Actions workflows, the `plezy.testBuildType` instrumentation gate, and the
`AMAZON=1 flutter build apk --release` Fire TV command. The env-var switch
mirrors the idiom upstream already uses for Amazon and leaves all of those
untouched.
