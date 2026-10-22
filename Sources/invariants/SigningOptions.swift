import ArgumentParser

struct SigningOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "Custom SSH private key path for signing (overrides INVARIANTS_KEY and default Secure Enclave key)."
  )
  var key: String?
}
