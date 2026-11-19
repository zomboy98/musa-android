plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val copiarNucleo = tasks.register<Copy>("copiarNucleo") {
    from("../../musa-motor-limpio-bytes/src/main/kotlin")
    into(layout.buildDirectory.dir("generated/nucleo"))
    filter { linea ->
        linea.replace(
            "Thread.ofPlatform().daemon().name(\"transferencia-bytes\").start { ejecutar() }",
            "Thread({ ejecutar() }, \"transferencia-bytes\").also { it.isDaemon = true }.start()",
        )
    }
}

android {
    namespace = "org.wiss.motor.prueba"
    compileSdk = 37

    defaultConfig {
        applicationId = "org.wiss.motor.prueba"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // El nucleo se incluye por codigo fuente (el original NO se modifica): se copia a build/ con
    // un unico parche mecanico, porque Thread.ofPlatform() es API de JDK 21 y no existe en android.jar.
    sourceSets.getByName("main") {
        java.srcDir(file("build/generated/nucleo"))
    }
}

tasks.configureEach {
    if (name.startsWith("compile") && name.endsWith("Kotlin")) dependsOn(copiarNucleo)
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.media3:media3-exoplayer:1.9.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("junit:junit:4.13.2")
}
