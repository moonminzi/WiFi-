plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// NepTUN(NordVPN의 Rust WireGuard 엔진)을 안드로이드용 libnago_tun.so로 빌드한다(Rust + Android NDK 필요).
// NDK는 ANDROID_NDK_HOME 또는 <SDK>/ndk/<버전>에서 찾는다.
val nagoTunDir = rootProject.file("../NagoTun")
val nagoTunJni = layout.buildDirectory.dir("nagotun/jniLibs")
val buildNagoTun by tasks.registering(Exec::class) {
    inputs.dir(nagoTunDir.resolve("src"))
    inputs.files(nagoTunDir.resolve("Cargo.toml"), nagoTunDir.resolve("Cargo.lock"), nagoTunDir.resolve("build-android.sh"))
    outputs.dir(nagoTunJni)
    workingDir = nagoTunDir
    commandLine("sh", "build-android.sh", nagoTunJni.get().asFile.absolutePath, "arm64-v8a", "armeabi-v7a")
}
tasks.named("preBuild") { dependsOn(buildNagoTun) }

android {
    namespace = "com.nago.vpn"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.nago.vpn"
        // IkeTunnelConnectionParams로 IKEv2 프로필을 만들려면 Android 13(API 33) 이상이 필요하다.
        minSdk = 33
        targetSdk = 35
        versionCode = 6
        versionName = "1.4"
        // 친구 폰은 다 ARM이라 WireGuard 엔진(libwg-go, libnago_tun)은 ARM용만 넣는다(APK 크기 절반 이하)
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }

    // NepTUN 엔진(../NagoTun, Rust)을 빌드한 .so
    sourceSets["main"].jniLibs.srcDir(nagoTunJni.get().asFile)

    // 전달용 서명: 환경변수로 키스토어를 주면 release를 서명한다(키스토어는 레포에 두지 않음).
    signingConfigs {
        create("nago") {
            val ks = System.getenv("NAGO_KEYSTORE")
            if (ks != null) {
                storeFile = file(ks)
                storePassword = System.getenv("NAGO_KEYSTORE_PASS")
                keyAlias = System.getenv("NAGO_KEY_ALIAS") ?: "nago"
                keyPassword = System.getenv("NAGO_KEYSTORE_PASS")
            }
        }
    }

    buildTypes {
        // CI 디버그 APK는 서명 키가 달라서 같은 패키지면 서로 덮어 깔리지 않는다 → 이름을 따로 둔다.
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (System.getenv("NAGO_KEYSTORE") != null) {
                signingConfig = signingConfigs.getByName("nago")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    // WireGuard 터널 엔진(GoBackend, Apache-2.0)
    implementation("com.wireguard.android:tunnel:1.0.20230706")
}
