// Quest / Horizon OS manifest overlay.
//
// This module ships NO code and NO resources. It exists purely so the Quest
// build can contribute a handful of manifest attributes to the app without
// editing `app/src/main/AndroidManifest.xml`, which upstream Plezy edits often.
// Keeping that file byte-identical to upstream is what makes rebasing cheap.
//
// It is only on the classpath when QUEST=1 is set (see app/build.gradle.kts),
// so default and Amazon/Fire TV builds are unaffected.
plugins {
  id("com.android.library")
}

android {
  namespace = "com.edde746.plezy.quest"
  // Matches :libass. Deliberately not `flutter.compileSdkVersion`: the Flutter
  // Gradle plugin's extension is only applied to the app module.
  compileSdk = 36

  defaultConfig {
    // Must not exceed the app's minSdk (25) or the merger rejects the library.
    minSdk = 25
  }
}
