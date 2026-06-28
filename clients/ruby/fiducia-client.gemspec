Gem::Specification.new do |spec|
  spec.name = "fiducia-client"
  spec.version = "0.1.0"
  spec.summary = "Fiducia HTTP client for fiducia.cloud."
  spec.description = "A dependency-light Ruby client for the fiducia.cloud HTTP API."
  spec.authors = ["fiducia.cloud"]
  spec.homepage = "https://github.com/fiducia-cloud/fiducia-clients"
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 2.7"
  spec.files = ["fiducia.rb"]
  spec.require_paths = ["."]
  spec.metadata = {
    "source_code_uri" => "https://github.com/fiducia-cloud/fiducia-clients/tree/main/clients/ruby"
  }
end
