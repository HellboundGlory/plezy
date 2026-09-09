// Quest / Horizon OS "3D Theater" side-mode. PLAN_3D.md Phase 1.
//
// Mirrors android/_kgp_probe's shape, which the Phase 1.1 KGP-toolchain
// probe proved out: a plain `com.android.library` module with NO
// `org.jetbrains.kotlin.android` plugin and NO `com.meta.spatial.plugin`.
// AGP 9.3.1's built-in Kotlin support compiles the .kt files below without
// either -- `com.meta.spatial.plugin` is what pulled in Kotlin Gradle
// Plugin build-report-metrics classes binary-incompatible with this repo's
// pinned Kotlin 2.4.10 (see PLAN_3D.md's Phase 0 changelog entry). The
// plugin is authoring-time-only Spatial Editor tooling (scene-export/
// hot-reload/shader-compile) this module never uses: it registers panels
// and reads a raw Surface entirely in code.
//
// This module is Flutter-free on purpose, matching every other native
// player integration in this repo: MethodChannel/EventChannel glue lives
// in android/app (only for THEATER_MODE=1 builds -- see
// android/app/src/theater3d/), and this module exposes only plain
// Kotlin/Android/Spatial SDK types across that boundary (Theater3DBridge).
plugins {
  id("com.android.library")
}

val metaSpatialSdkVersion = "0.13.2"

android {
  namespace = "com.edde746.plezy.theater3d"
  compileSdk = 36

  defaultConfig {
    // Horizon OS only; no floor to share with the app's minSdk 25 the way
    // :quest/:selfupdate do, since this module is never on the classpath
    // for a non-THEATER_MODE build.
    minSdk = 29
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
}

kotlin {
  compilerOptions {
    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
  }
}

dependencies {
  implementation("com.meta.spatial:meta-spatial-sdk:$metaSpatialSdkVersion")
  implementation("com.meta.spatial:meta-spatial-sdk-toolkit:$metaSpatialSdkVersion")
  implementation("com.meta.spatial:meta-spatial-sdk-vr:$metaSpatialSdkVersion")

  // SystemDAG's topological sort reflects on registered system classes
  // (FollowableSystem, InputSystem, ...) via kotlin-reflect; without it on
  // the runtime classpath every lookup returns the stub "(Kotlin reflection
  // is not available)" and the sort fails as if those systems were never
  // registered at all, even though VRFeature did register them.
  implementation("org.jetbrains.kotlin:kotlin-reflect:2.4.10")

  testImplementation("junit:junit:4.13.2")
}
