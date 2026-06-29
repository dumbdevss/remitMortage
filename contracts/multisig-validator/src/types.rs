use soroban_sdk::{contracttype, Address, BytesN, Vec};

/// A single weighted signer of a multisig account, mirroring a Stellar
/// account's `signer { key, weight }` entry. `key` is the Ed25519 public key.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub struct Signer {
    /// Ed25519 public key of the signer.
    pub key: BytesN<32>,
    /// Voting weight contributed by this signer.
    pub weight: u32,
}

/// The stored multisig configuration for an account: its weighted signer set
/// and the cumulative weight required to authorize an operation.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub struct MultisigConfig {
    /// The configured weighted signers.
    pub signers: Vec<Signer>,
    /// Required cumulative weight (the "high"/medium threshold).
    pub threshold: u32,
}

/// Storage keys.
#[contracttype]
#[derive(Clone)]
pub enum DataKey {
    /// Per-account multisig configuration, keyed by the account address.
    Config(Address),
}
