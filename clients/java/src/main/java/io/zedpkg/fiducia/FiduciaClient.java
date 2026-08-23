package io.zedpkg.fiducia;
import java.net.URI;
public record FiduciaClient(URI baseUri, String bearerToken) {}
