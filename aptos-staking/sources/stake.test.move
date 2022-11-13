#[test_only]
module bwarelabs::delegation_pool_tests {
    use std::signer;
    use std::vector;

    use aptos_framework::coin;
    use aptos_framework::staking_config;
    use aptos_framework::stake;
    use aptos_framework::account;
    use aptos_framework::reconfiguration;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_std::debug::print;

    use aptos_framework::timestamp;
    use bwarelabs::delegation_pool;


    const CONSENSUS_KEY_1: vector<u8> = x"8a54b92288d4ba5073d3a52e80cc00ae9fbbc1cc5b433b46089b7804c38a76f00fc64746c7685ee628fc2d0b929c2294";
    const CONSENSUS_POP_1: vector<u8> = x"a9d6c1f1270f2d1454c89a83a4099f813a56dc7db55591d46aa4e6ccae7898b234029ba7052f18755e6fa5e6b73e235f14efc4e2eb402ca2b8f56bad69f965fc11b7b25eb1c95a06f83ddfd023eac4559b6582696cfea97b227f4ce5bdfdfed0";


    // Minimum stake is 100, Max stake is 10,000,000
    public fun initialize_test_state(aptos_framework: &signer, validator: &signer, reward_numerator: u64, reward_denominator: u64) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(validator));

        reconfiguration::initialize_for_test(aptos_framework);

        coin::register<AptosCoin>(validator);

        // min stake, max stake, lockup duration secs, allow validator set change
        // reward rate numerator, reward rate denominator, voting power increase limit
        stake::initialize_for_test_custom(aptos_framework, 100, 10000000, 3600, true, reward_numerator, reward_denominator, 10000);

        delegation_pool::initialize_delegation_pool(validator, vector::empty<u8>());

        // ValidatorConfig is created when stake::initialize_stake_owner is called
        // However, the consensus_pubkey, network_addresses, and fullnode_addresses
        // are empty when this happens. In order to join the validator set, we need
        // at minimum a valid consensus_pubkey, which we add here. For some reason
        // stake::join_validator_set never checks for the other two addresses.
        let pool_address = delegation_pool::get_owned_pool_address(signer::address_of(validator));
        stake::rotate_consensus_key(validator, pool_address, CONSENSUS_KEY_1, CONSENSUS_POP_1);
    }

    public fun initialize_user(aptos_framework: &signer, user: &signer, initial_coin: u64) {
        let addr = signer::address_of(user);
        account::create_account_for_test(addr);
        coin::register<AptosCoin>(user);
        aptos_coin::mint(aptos_framework, addr, initial_coin);
    }

    public fun new_epoch() {
        stake::end_epoch();
        // increments reconfiguration::Configuration.epoch
        reconfiguration::reconfigure_for_test_custom();
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    public entry fun test_end_to_end(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        // reward rate is 1% per epoch, or 1 / 100
        initialize_test_state(aptos_framework, validator, 1, 100);
        initialize_user(aptos_framework, user, 1000);

        staking_config::update_recurring_lockup_duration_secs(aptos_framework, 10000);

        let pool_address: address = delegation_pool::get_owned_pool_address(validator_addr);
        print<address>(&validator_addr);
        print<address>(&pool_address);
        delegation_pool::add_stake(user, pool_address, 100);
        stake::join_validator_set(validator, pool_address);

        new_epoch();
        new_epoch();
        delegation_pool::restake(user, pool_address);
        delegation_pool::unlock(user, pool_address, 1000);
        timestamp::fast_forward_seconds(10000);
        new_epoch();
        delegation_pool::end_epoch(pool_address);
        delegation_pool::withdraw(user, pool_address, 1000);

        print<u64>(&coin::balance<AptosCoin>(user_addr));

        delegation_pool::set_operator(validator, signer::address_of(validator));


        timestamp::fast_forward_seconds(100);
        delegation_pool::end_epoch(pool_address);
    }
}