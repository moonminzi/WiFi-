plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.nago.vpn"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.nago.vpn"
        // IkeTunnelConnectionParams로 IKEv2 프로필을 만들려면 Android 13(API 33) 이상이 필요하다.
        minSdk = 33
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

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
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
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
}
