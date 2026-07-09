ThisBuild / organization := "cloud.fiducia"
ThisBuild / organizationName := "fiducia.cloud"
ThisBuild / organizationHomepage := Some(url("https://fiducia.cloud"))
ThisBuild / version := "0.1.0"
ThisBuild / versionScheme := Some("early-semver")

ThisBuild / scalaVersion := "2.13.14"
ThisBuild / crossScalaVersions := Seq("2.13.14", "3.3.3")

lazy val root = (project in file("."))
  .settings(
    name := "fiducia-client",
    description := "Fiducia HTTP client for Scala / JVM applications.",

    // Only dependency: stdlib java.net.http for transport, ujson for JSON.
    libraryDependencies += "com.lihaoyi" %% "ujson" % "3.3.1",

    // Keep warnings non-fatal so the cross-build (2.13 + 3.x) stays green.
    Compile / scalacOptions += "-deprecation",

    // --- POM metadata (Maven Central requirements) -------------------------
    homepage := Some(url("https://github.com/fiducia-cloud/fiducia-clients")),
    licenses := Seq(
      "UNLICENSED" -> url(
        "https://github.com/fiducia-cloud/fiducia-clients/blob/main/clients/scala/LICENSE.txt"
      )
    ),
    scmInfo := Some(
      ScmInfo(
        url("https://github.com/fiducia-cloud/fiducia-clients"),
        "scm:git:https://github.com/fiducia-cloud/fiducia-clients.git"
      )
    ),
    developers := List(
      Developer(
        id = "fiducia",
        name = "fiducia.cloud",
        email = "support@fiducia.cloud",
        url = url("https://github.com/fiducia-cloud")
      )
    ),

    // --- Publish to Maven Central via Sonatype -----------------------------
    // `sbt +publish` cross-publishes for every entry in crossScalaVersions.
    // Signing + Sonatype credentials are supplied by the release environment.
    publishMavenStyle := true,
    Test / publishArtifact := false,
    pomIncludeRepository := { _ => false },
    publishTo := {
      if (isSnapshot.value)
        Some("central-snapshots" at "https://central.sonatype.com/repository/maven-snapshots/")
      else
        Some(
          "central-staging" at
            "https://ossrh-staging-api.central.sonatype.com/service/local/staging/deploy/maven2/"
        )
    }
  )
