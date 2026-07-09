(ns build
  "Build + publish tasks for the Fiducia Clojure client.

     clojure -T:build jar      ; build target/<artifact>-<version>.jar
     clojure -T:build deploy   ; deploy to Clojars (CLOJARS_USERNAME / CLOJARS_PASSWORD)"
  (:require [clojure.tools.build.api :as b]
            [deps-deploy.deps-deploy :as dd]))

(def lib 'cloud.fiducia/fiducia-client)
(def version "0.1.0")
(def class-dir "target/classes")
(def basis (b/create-basis {:project "deps.edn"}))
(def jar-file (format "target/%s-%s.jar" (name lib) version))

(defn clean [_]
  (b/delete {:path "target"}))

(defn jar
  "Write pom + assemble the jar under target/."
  [_]
  (b/delete {:path "target"})
  (b/write-pom
   {:class-dir class-dir
    :lib lib
    :version version
    :basis basis
    :src-dirs ["src"]
    :pom-data
    [[:description
      "Thin HTTP client for fiducia.cloud: distributed locks, semaphores, reader-writer locks, idempotency, config KV, rate limiting, cron scheduling, leader election, and service discovery."]
     [:url "https://github.com/fiducia-cloud/fiducia-clients"]
     [:licenses
      [:license
       [:name "UNLICENSED"]
       [:comments
        "No open-source license has been granted for this package yet. All rights are reserved unless fiducia.cloud grants a separate license."]]]
     [:developers
      [:developer
       [:name "fiducia.cloud"]]]
     [:scm
      [:url "https://github.com/fiducia-cloud/fiducia-clients"]
      [:connection "scm:git:https://github.com/fiducia-cloud/fiducia-clients.git"]
      [:developerConnection "scm:git:ssh://git@github.com/fiducia-cloud/fiducia-clients.git"]
      [:tag "main"]]]})
  (b/copy-dir {:src-dirs ["src"] :target-dir class-dir})
  (b/jar {:class-dir class-dir :jar-file jar-file})
  jar-file)

(defn deploy
  "Build the jar and push it to Clojars via deps-deploy."
  [_]
  (jar nil)
  (dd/deploy {:installer :remote
              :sign-releases? false
              :artifact (b/resolve-path jar-file)
              :pom-file (b/pom-path {:lib lib :class-dir class-dir})}))
