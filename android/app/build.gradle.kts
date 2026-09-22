plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.kapt")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "si.gasilko.app"
    compileSdk = 36
    defaultConfig {
        applicationId = "si.gasilko.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.0.1"
        val callbackScheme = providers.environmentVariable("ANDROID_AUTH_REDIRECT_SCHEME").orElse("si.gasilko.app").get()
        require(callbackScheme.matches(Regex("[a-z][a-z0-9+.-]*")))
        manifestPlaceholders["authRedirectScheme"] = callbackScheme
        buildConfigField("String", "AUTH_REDIRECT_SCHEME", "\"" + callbackScheme + "\"")
        val authUrl = providers.environmentVariable("ANDROID_SUPABASE_URL").orElse("").get()
        val authKey = providers.environmentVariable("ANDROID_SUPABASE_PUBLISHABLE_KEY").orElse("").get()
        require(authKey.isEmpty() || authKey.startsWith("sb_publishable_")) { "Use a publishable Supabase key only" }
        fun quoted(value: String) = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "").replace("\r", "") + "\""
        buildConfigField("String", "SUPABASE_URL", quoted(authUrl))
        buildConfigField("String", "SUPABASE_PUBLISHABLE_KEY", quoted(authKey))
        // Public demo for the foundation; configure an approved provider for deployment.
        val mapStyle = providers.environmentVariable("ANDROID_MAP_STYLE_URL")
            .orElse("https://demotiles.maplibre.org/style.json").get()
        buildConfigField("String", "MAP_STYLE_URL", quoted(mapStyle))
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    buildFeatures { compose = true; buildConfig = true }
    lint { abortOnError = true }
}
kotlin { jvmToolchain(17) }
kapt { arguments { arg("room.schemaLocation", "$projectDir/schemas") } }
dependencies {
    // OpenGL intentionally provides broad device compatibility; no Vulkan/multi-backend.
    implementation("org.maplibre.gl:android-sdk-opengl:13.6.1")
    implementation(platform("io.github.jan-tennert.supabase:bom:3.6.0"))
    implementation("io.github.jan-tennert.supabase:auth-kt")
    implementation("io.github.jan-tennert.supabase:postgrest-kt")
    implementation("io.ktor:ktor-client-okhttp:3.4.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    implementation(platform("androidx.compose:compose-bom:2025.12.01"))
    implementation("androidx.activity:activity-compose:1.12.4")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("androidx.room:room-runtime:2.8.4")
    kapt("androidx.room:room-compiler:2.8.4")
    implementation("androidx.work:work-runtime-ktx:2.11.2")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.12.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test:runner:1.7.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
