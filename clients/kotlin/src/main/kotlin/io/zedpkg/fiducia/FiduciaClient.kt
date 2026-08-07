package io.zedpkg.fiducia
import java.net.URI
data class FiduciaClient(val baseUri: URI, val bearerToken: String? = null)
