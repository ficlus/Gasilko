# Android foundation

Open this directory in Android Studio. JDK 17, SDK 36, build-tools 35.0.0 and Gradle 8.13 are required. The committed wrapper downloads Gradle. Set ANDROID_HOME or untracked local.properties. Minimum device API is 26.

Run `./gradlew lintDebug testDebugUnitTest assembleDebug`. On Windows use `gradlew.bat`. Run `./gradlew connectedDebugAndroidTest` with an API 26+ emulator/device to check a real launch.

M0 has no domain logic and intentionally no JVM unit cases. The unit-test task must execute successfully but NO-SOURCE does not mean behavioral coverage. LaunchTest is a real instrumentation test. Check both Slovenian and German device/app locales.

core and feature directories are explicit future module boundaries, mirrored by packages in :app. Split into Gradle modules as implementations arrive. No repositories, Room tables or sync workers are fabricated in M0; required Room/WorkManager/coroutines runtimes are declared, but no business work runs. Room compiler/KSP waits until entities exist. UI domain reads must later flow through ViewModel → Repository → Room.
