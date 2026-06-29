use soroban_sdk::contracterror;

/// Errors returned by the multisig validator contract.
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum ValidatorError {
    /// No signer configuration exists for the requested account.
    AccountNotConfigured = 1,
    /// A configuration already exists for the account.
    AccountAlreadyConfigured = 2,
    /// Threshold must be > 0 and <= the total configurable signer weight.
    InvalidThreshold = 3,
    /// A signer weight of zero is not allowed.
    InvalidWeight = 4,
    /// The signer set contains a duplicate key.
    DuplicateSigner = 5,
    /// A presented signer is not part of the account's configured signer set.
    UnknownSigner = 6,
    /// The cumulative weight of the presented signers is below the threshold.
    InsufficientWeight = 7,
    /// The signer set is empty.
    NoSigners = 8,
}
