// Sideload self-update manifest overlay.
//
// Code-free, like :quest. It contributes the one permission an APK needs to
// install another APK, and exists as a separate module because BOTH the Quest
// and the Fire TV builds need it while the default (Play Store) build must not
// have it — Play policy forbids self-updating.
//
// On the classpath only when QUEST=1 or AMAZON=1 (see app/build.gradle.kts).
plugins {
  id("com.android.library")
}

android {
  namespace = "com.edde746.plezy.selfupdate"
  compileSdk = 36

  defaultConfig {
    minSdk = 25
  }
}
