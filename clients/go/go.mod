module github.com/fiducia-cloud/fiducia-clients/clients/go

go 1.21

// Shared, generated payload contract. `replace`d to the local interfaces repo
// until it is published.
require github.com/fiducia-cloud/fiducia-interfaces/generated/go v0.0.0

replace github.com/fiducia-cloud/fiducia-interfaces/generated/go => ../../../fiducia-interfaces/generated/go
