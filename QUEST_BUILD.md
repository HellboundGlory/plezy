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

### Signing

Release signing uses `android/key.properties` if present, exactly as upstream:

```properties
storeFile=/absolute/path/to/keystore.jks
storePassword=...
keyAlias=...
keyPassword=...
```

Without it the build falls back to the debug key, which is fine for sideloading
but means an existing install must be uninstalled before a differently-signed
APK will install.

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

Heads-up on an upstream quirk found while validating this (**not** introduced by
this fork, and deliberately left alone): upstream's `AMAZON` block uses
`abiFilters += listOf("armeabi-v7a", "arm64-v8a")`, and because of the
plugin-apply ordering described above, that union does not actually drop
`x86_64`. Amazon APKs therefore still carry an x86_64 slice. Fire TV devices are
all ARM so this is wasted size rather than a functional problem. Fixing it would
mean changing upstream behaviour, which is out of scope here — but if you want
your private Fire Stick builds slimmer, adding `abiFilters.clear()` to that block
is the same one-line fix used in the `QUEST` block.

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

Note that Horizon reports **no touchscreen**, and Plezy's `TvDetection`
(`android/app/src/main/kotlin/com/edde746/plezy/TvDetection.kt`) counts absence
of a touchscreen as a TV signal — so Plezy renders its **TV/10-foot UI** on
Quest. That is left as-is deliberately: it is a reasonable fit for a large
virtual panel, it keeps the fork's behaviour identical to upstream, and Settings
already exposes a force-TV toggle if you want to experiment. See "Known
considerations" below.

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
android/quest/build.gradle.kts             # code-free library module
android/quest/src/main/AndroidManifest.xml # the Horizon panel overlay
lib/quest/quest_platform.dart              # Quest/Horizon device detection
test/quest/quest_platform_test.dart        # tests for the above
QUEST_BUILD.md                             # this file
.questenv                                  # toolchain environment
```

## Upstream files this fork modifies

Both changes are pure insertions guarded by `System.getenv("QUEST")`, so the
default and Amazon builds are byte-identical to upstream.

- `android/settings.gradle.kts` — `include(":quest")` (+3, -0)
- `android/app/build.gradle.kts` — the `QUEST` block mirroring the existing
  `AMAZON` block, and the conditional `implementation(project(":quest"))`
  (+23, -0)

### Why not product flavors?

A `quest` product flavor would be the textbook AGP answer, but declaring any
flavor renames every Gradle variant (`assembleRelease` →
`assembleStandardRelease`) and makes `--flavor` mandatory on *every* build
command. That would break upstream's `android/fastlane/Fastfile`, the GitHub
Actions workflows, the `plezy.testBuildType` instrumentation gate, and the
`AMAZON=1 flutter build apk --release` Fire TV command. The env-var switch
mirrors the idiom upstream already uses for Amazon and leaves all of those
untouched.
