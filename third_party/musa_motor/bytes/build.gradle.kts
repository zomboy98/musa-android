plugins {
    kotlin("jvm") version "2.4.10"
}

group = "org.wiss.motor"
version = "0.1.0"

// Solo stdlib de Kotlin: en la cache offline de Gradle no hay kotlin-test y las
// pruebas JUnit no son fiables sin red, asi que las pruebas son un ejecutable
// con main() y un runner propio (tarea runTests).
kotlin {
    compilerOptions {
        allWarningsAsErrors.set(true)
    }
}

val runTests = tasks.register<JavaExec>("runTests") {
    group = "verification"
    description = "Ejecuta las pruebas con el runner propio (sin JUnit)."
    classpath = sourceSets["test"].runtimeClasspath
    mainClass.set("org.wiss.motor.bytes.AllTestsKt")
}

tasks.named<Test>("test") { enabled = false }
tasks.named("check") { dependsOn(runTests) }
