// Gradle build for the Kotlin Fiducia client.
plugins {
    kotlin("jvm") version "1.9.24"
    kotlin("plugin.serialization") version "1.9.24"
    `maven-publish`
    signing
}

group = "cloud.fiducia"
version = "0.1.0"

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
}

kotlin {
    jvmToolchain(11)
}

java {
    withSourcesJar()
    withJavadocJar()
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])
            artifactId = "fiducia-client"
            pom {
                name.set("fiducia-client")
                description.set("Fiducia HTTP client for JVM/Kotlin applications.")
                url.set("https://github.com/fiducia-cloud/fiducia-clients")
                licenses {
                    license {
                        name.set("UNLICENSED")
                        url.set("https://github.com/fiducia-cloud/fiducia-clients/blob/main/clients/kotlin/LICENSE.txt")
                        distribution.set("repo")
                    }
                }
                developers {
                    developer {
                        name.set("fiducia.cloud")
                    }
                }
                scm {
                    connection.set("scm:git:https://github.com/fiducia-cloud/fiducia-clients.git")
                    developerConnection.set("scm:git:https://github.com/fiducia-cloud/fiducia-clients.git")
                    url.set("https://github.com/fiducia-cloud/fiducia-clients/tree/main/clients/kotlin")
                }
            }
        }
    }
    repositories {
        maven {
            name = "central"
            // Maven Central via the Sonatype Central staging API (mirrors the Java sibling).
            val releasesUrl = uri("https://ossrh-staging-api.central.sonatype.com/service/local/staging/deploy/maven2/")
            val snapshotsUrl = uri("https://central.sonatype.com/repository/maven-snapshots/")
            url = if (version.toString().endsWith("SNAPSHOT")) snapshotsUrl else releasesUrl
            credentials {
                username = System.getenv("SONATYPE_USERNAME") ?: System.getenv("OSSRH_USERNAME")
                password = System.getenv("SONATYPE_PASSWORD") ?: System.getenv("OSSRH_PASSWORD")
            }
        }
    }
}

signing {
    // Sign only when a key is supplied (release); local builds/compile need no key.
    val signingKey = System.getenv("GPG_SIGNING_KEY") ?: System.getenv("SIGNING_KEY")
    val signingPassword = System.getenv("GPG_SIGNING_PASSWORD") ?: System.getenv("SIGNING_PASSWORD")
    if (!signingKey.isNullOrBlank()) {
        useInMemoryPgpKeys(signingKey, signingPassword)
        sign(publishing.publications["maven"])
    }
}
