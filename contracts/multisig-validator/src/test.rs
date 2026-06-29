#![cfg(test)]
extern crate std;

use super::*;
use soroban_sdk::{
    testutils::Address as _,
    vec, Address, BytesN, Env, Vec,
};

fn key(env: &Env, b: u8) -> BytesN<32> {
    BytesN::from_array(env, &[b; 32])
}

fn signer(env: &Env, b: u8, weight: u32) -> Signer {
    Signer { key: key(env, b), weight }
}

/// Register a 3-signer account with weights {A:2, B:1, C:1} and threshold 3.
fn setup(env: &Env) -> (Address, MultisigValidatorClient<'_>) {
    let contract_id = env.register(MultisigValidator, ());
    let client = MultisigValidatorClient::new(env, &contract_id);

    let account = Address::generate(env);
    let signers: Vec<Signer> = vec![
        env,
        signer(env, 0xA1, 2),
        signer(env, 0xB2, 1),
        signer(env, 0xC3, 1),
    ];
    client.configure_account(&account, &signers, &3u32);
    (account, client)
}

#[test]
fn test_configure_and_read() {
    let env = Env::default();
    env.mock_all_auths();
    let (account, client) = setup(&env);

    assert_eq!(client.get_threshold(&account), 3u32);
    assert_eq!(client.total_weight(&account), 4u32);
    assert_eq!(client.get_config(&account).signers.len(), 3u32);
}

#[test]
fn test_meets_threshold_exactly() {
    let env = Env::default();
    env.mock_all_auths();
    let (account, client) = setup(&env);

    // A(2) + B(1) = 3 == threshold.
    let keys: Vec<BytesN<32>> = vec![&env, key(&env, 0xA1), key(&env, 0xB2)];
    assert_eq!(client.tally_weight(&account, &keys), 3u32);
    assert!(client.verify_threshold(&account, &keys));
    client.enforce_threshold(&account, &keys); // does not panic
}

#[test]
fn test_exceeds_threshold() {
    let env = Env::default();
    env.mock_all_auths();
    let (account, client) = setup(&env);

    // A(2) + B(1) + C(1) = 4 > 3.
    let keys: Vec<BytesN<32>> =
        vec![&env, key(&env, 0xA1), key(&env, 0xB2), key(&env, 0xC3)];
    assert_eq!(client.tally_weight(&account, &keys), 4u32);
    assert!(client.verify_threshold(&account, &keys));
}

#[test]
fn test_insufficient_weight_returns_false() {
    let env = Env::default();
    env.mock_all_auths();
    let (account, client) = setup(&env);

    // B(1) + C(1) = 2 < 3.
    let keys: Vec<BytesN<32>> = vec![&env, key(&env, 0xB2), key(&env, 0xC3)];
    assert_eq!(client.tally_weight(&account, &keys), 2u32);
    assert!(!client.verify_threshold(&account, &keys));
}

#[test]
fn test_enforce_threshold_rejects_insufficient() {
    let env = Env::default();
    env.mock_all_auths();
    let (account, client) = setup(&env);

    let keys: Vec<BytesN<32>> = vec![&env, key(&env, 0xC3)]; // weight 1 < 3
    let res = client.try_enforce_threshold(&account, &keys);
    assert_eq!(res, Err(Ok(ValidatorError::InsufficientWeight)));
}

#[test]
fn test_unknown_signer_rejected() {
    let env = Env::default();
    env.mock_all_auths();
    let (account, client) = setup(&env);

    let keys: Vec<BytesN<32>> = vec![&env, key(&env, 0xA1), key(&env, 0xFF)];
    let res = client.try_verify_threshold(&account, &keys);
    assert_eq!(res, Err(Ok(ValidatorError::UnknownSigner)));
}

#[test]
fn test_duplicate_presented_key_rejected() {
    let env = Env::default();
    env.mock_all_auths();
    let (account, client) = setup(&env);

    // Presenting A twice must not double-count its weight to reach 4.
    let keys: Vec<BytesN<32>> = vec![&env, key(&env, 0xA1), key(&env, 0xA1)];
    let res = client.try_tally_weight(&account, &keys);
    assert_eq!(res, Err(Ok(ValidatorError::DuplicateSigner)));
}

#[test]
fn test_threshold_above_total_weight_rejected() {
    let env = Env::default();
    env.mock_all_auths();
    let contract_id = env.register(MultisigValidator, ());
    let client = MultisigValidatorClient::new(&env, &contract_id);
    let account = Address::generate(&env);

    let signers: Vec<Signer> = vec![&env, signer(&env, 0xA1, 1), signer(&env, 0xB2, 1)];
    // threshold 3 > total weight 2.
    let res = client.try_configure_account(&account, &signers, &3u32);
    assert_eq!(res, Err(Ok(ValidatorError::InvalidThreshold)));
}

#[test]
fn test_zero_weight_signer_rejected() {
    let env = Env::default();
    env.mock_all_auths();
    let contract_id = env.register(MultisigValidator, ());
    let client = MultisigValidatorClient::new(&env, &contract_id);
    let account = Address::generate(&env);

    let signers: Vec<Signer> = vec![&env, signer(&env, 0xA1, 0)];
    let res = client.try_configure_account(&account, &signers, &1u32);
    assert_eq!(res, Err(Ok(ValidatorError::InvalidWeight)));
}

#[test]
fn test_duplicate_configured_signer_rejected() {
    let env = Env::default();
    env.mock_all_auths();
    let contract_id = env.register(MultisigValidator, ());
    let client = MultisigValidatorClient::new(&env, &contract_id);
    let account = Address::generate(&env);

    let signers: Vec<Signer> = vec![&env, signer(&env, 0xA1, 1), signer(&env, 0xA1, 2)];
    let res = client.try_configure_account(&account, &signers, &1u32);
    assert_eq!(res, Err(Ok(ValidatorError::DuplicateSigner)));
}

#[test]
fn test_unconfigured_account_errors() {
    let env = Env::default();
    env.mock_all_auths();
    let contract_id = env.register(MultisigValidator, ());
    let client = MultisigValidatorClient::new(&env, &contract_id);
    let account = Address::generate(&env);

    let res = client.try_get_threshold(&account);
    assert_eq!(res, Err(Ok(ValidatorError::AccountNotConfigured)));
}
