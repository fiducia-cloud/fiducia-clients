module github.com/fiducia-cloud/fiducia-clients/clients/go

go 1.21

// Shared, generated payload contract pinned to the exact reviewed interfaces
// commit. The nested module has no release tag yet, so Go resolves its
// immutable pseudo-version directly from the public repository.
require github.com/fiducia-cloud/fiducia-interfaces/generated/go v0.0.0-20260729201853-bd718cd72d72
