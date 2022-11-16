#[test_only]
module bwarelabs::delegation_pool_integration_tests {

    use bwarelabs::delegation_pool as dp;

    #[test_only]
    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::reconfiguration;
    use aptos_std::stake;
    use aptos_framework::account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::staking_config;
    use aptos_std::vector;
    //use aptos_std::debug::print;
    use aptos_framework::timestamp;

    #[test_only]
    const CONSENSUS_KEY_1: vector<u8> = x"8a54b92288d4ba5073d3a52e80cc00ae9fbbc1cc5b433b46089b7804c38a76f00fc64746c7685ee628fc2d0b929c2294";
    #[test_only]
    const CONSENSUS_POP_1: vector<u8> = x"a9d6c1f1270f2d1454c89a83a4099f813a56dc7db55591d46aa4e6ccae7898b234029ba7052f18755e6fa5e6b73e235f14efc4e2eb402ca2b8f56bad69f965fc11b7b25eb1c95a06f83ddfd023eac4559b6582696cfea97b227f4ce5bdfdfed0";

    #[test_only]
    const CONSENSUS_KEY_2: vector<u8> = x"a344eb437bcd8096384206e1be9c80be3893fd7fdf867acce5a048e5b1546028bdac4caf419413fd16d4d6a609e0b0a3";
    #[test_only]
    const CONSENSUS_POP_2: vector<u8> = x"909d3a378ad5c17faf89f7a2062888100027eda18215c7735f917a4843cd41328b42fa4242e36dedb04432af14608973150acbff0c5d3f325ba04b287be9747398769a91d4244689cfa9c535a5a4d67073ee22090d5ab0a88ab8d2ff680e991e";

    #[test_only]
    const EPOCH_DURATION: u64 = 60;

    #[test_only]
    const LOCKUP_CYCLE_SECONDS: u64 = 3600;

    #[test_only]
    public fun initialize_for_test(aptos_framework: &signer) {
        initialize_for_test_custom(aptos_framework, 100, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 100, 1000000);
    }

    #[test_only]
    public fun end_epoch(pool_addresses: &vector<address>) {
        reconfiguration::reconfigure_for_test_custom();
        stake::end_epoch();
        let i = 0;
        let len = vector::length(pool_addresses);
        while (i < len) {
            dp::end_epoch(*vector::borrow(pool_addresses, i));
            i = i + 1;
        };
    }

    #[test_only]
    public fun join_validator_set_for_test(
        operator: &signer,
        pool_address: address,
        should_end_epoch: bool,
    ) {
        stake::rotate_consensus_key(operator, pool_address, CONSENSUS_KEY_1, CONSENSUS_POP_1);
        stake::join_validator_set(operator, pool_address);
        if (should_end_epoch) {
            reconfiguration::reconfigure_for_test_custom();
            stake::end_epoch();
            dp::end_epoch(pool_address);
        }
    }

    // Convenient function for setting up all required stake initializations.
    #[test_only]
    public fun initialize_for_test_custom(
        aptos_framework: &signer,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate_numerator: u64,
        rewards_rate_denominator: u64,
        voting_power_increase_limit: u64,
    ) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        reconfiguration::initialize_for_test(aptos_framework);
        stake::initialize_for_test_custom(aptos_framework, minimum_stake, maximum_stake, recurring_lockup_secs, allow_validator_set_change,
            rewards_rate_numerator, rewards_rate_denominator, voting_power_increase_limit);
        // start from aptos epoch 1
        timestamp::fast_forward_seconds(EPOCH_DURATION);
        reconfiguration::reconfigure_for_test_custom();
    }

    #[test_only]
    public fun mint_and_add_stake(validator: &signer, amount: u64) {
        stake::mint(validator, amount);
        dp::add_stake(validator, dp::get_owned_pool_address(signer::address_of(validator)), amount);
    }

    #[test_only]
    public fun initialize_test_validator(
        validator: &signer,
        amount: u64,
        should_join_validator_set: bool,
        should_end_epoch: bool,
    ) {
        let validator_address = signer::address_of(validator);
        if (!account::exists_at(signer::address_of(validator))) {
            account::create_account_for_test(validator_address);
        };

        dp::initialize_delegation_pool(validator, vector::empty<u8>());
        let validator_address = dp::get_owned_pool_address(signer::address_of(validator));
        stake::rotate_consensus_key(validator, validator_address, CONSENSUS_KEY_1, CONSENSUS_POP_1);

        if (amount > 0) {
            stake::mint(validator, amount);
            dp::add_stake(validator, validator_address, amount);
        };

        if (should_join_validator_set) {
            stake::join_validator_set(validator, validator_address);
        };
        if (should_end_epoch) {
            end_epoch(&vector::singleton(validator_address));
        };
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10007)]
    public entry fun test_inactive_validator_can_add_stake_if_exceeding_max_allowed(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 100, false, false);

        // Add more stake to exceed max. This should fail.
        stake::mint(validator, 9901);
        let pool_address = dp::get_owned_pool_address(signer::address_of(validator));

        dp::add_stake(validator, pool_address, 9901);
    }

    #[test(aptos_framework = @0x1, validator_1 = @0x123, validator_2 = @0x234)]
    #[expected_failure(abort_code = 0x10007)]
    public entry fun test_pending_active_validator_cannot_add_stake_if_exceeding_max_allowed(
        aptos_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
    ) {
        initialize_for_test_custom(aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 10, 100000);
        // Have one validator join the set to ensure the validator set is not empty when main validator joins.
        initialize_test_validator(validator_1, 100, true, true);

        // Validator 2 joins validator set but epoch has not ended so validator is in pending_active state.
        initialize_test_validator(validator_2, 100, true, false);

        // Add more stake to exceed max. This should fail.
        mint_and_add_stake(validator_2, 9901);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10007)]
    public entry fun test_active_validator_cannot_add_stake_if_exceeding_max_allowed(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        // Validator joins validator set and waits for epoch end so it's in the validator set.
        initialize_test_validator(validator, 100, true, true);

        // Add more stake to exceed max. This should fail.
        mint_and_add_stake(validator, 9901);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10007)]
    public entry fun test_active_validator_with_pending_inactive_stake_cannot_add_stake_if_exceeding_max_allowed(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        // Validator joins validator set and waits for epoch end so it's in the validator set.
        initialize_test_validator(validator, 100, true, true);

        // Request to dp::unlock 50 coins, which go to pending_inactive. Validator has 50 remaining in active.
        let pool_address = dp::get_owned_pool_address(signer::address_of(validator));
        dp::unlock(validator, pool_address, 50);
        stake::assert_validator_state(pool_address, 50, 0, 0, 50, 0);

        // Add 9901 more. Total stake is 50 (active) + 50 (pending_inactive) + 9901 > 10000 so still exceeding max.
        mint_and_add_stake(validator, 9901);
    }

    #[test(aptos_framework = @aptos_framework, validator_1 = @0x123, validator_2 = @0x234)]
    #[expected_failure(abort_code = 0x10007)]
    public entry fun test_pending_inactive_cannot_add_stake_if_exceeding_max_allowed(
        aptos_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
    ) {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator_1, 100, true, false);
        initialize_test_validator(validator_2, 100, true, true);

        // Leave validator set so validator is in pending_inactive state.
        stake::leave_validator_set(validator_1, dp::get_owned_pool_address(signer::address_of(validator_1)));

        // Add 9901 more. Total stake is 50 (active) + 50 (pending_inactive) + 9901 > 10000 so still exceeding max.
        mint_and_add_stake(validator_1, 9901);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_end_to_end(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 200, true, true);

        // Validator has a lockup now that they've joined the validator set.
        let validator_address = signer::address_of(validator);
        let pool_address = dp::get_owned_pool_address(signer::address_of(validator));
        let pools = vector::singleton(pool_address);

        assert!(stake::get_remaining_lockup_secs(pool_address) == LOCKUP_CYCLE_SECONDS, 1);

        // Validator adds more stake while already being active.
        // The added stake should go to pending_active to wait for activation when next epoch starts.
        stake::mint(validator, 800);
        dp::add_stake(validator, pool_address, 100);
        assert!(coin::balance<AptosCoin>(validator_address) == 700, 2);
        stake::assert_validator_state(pool_address, 200, 0, 100, 0, 0);

        // Pending_active stake is activated in the new epoch.
        // Rewards of 1 coin are also distributed for the existing active stake of 100 coins.
        end_epoch(&pools);
        assert!(stake::get_validator_state(pool_address) == 2, 3);
        stake::assert_validator_state(pool_address, 302, 0, 0, 0, 0);

        // Request dp::unlock of 100 coins. These 100 coins are moved to pending_inactive and will be unlocked when the
        // current lockup expires.
        dp::unlock(validator, pool_address, 100);
        stake::assert_validator_state(pool_address, 202, 0, 0, 100, 0);

        // Enough time has passed so the current lockup cycle should have ended.
        // The first epoch after the lockup cycle ended should automatically move unlocked (pending_inactive) stake
        // to inactive.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch(&pools);

        // Rewards were also minted to pending_inactive, which got all moved to inactive.
        stake::assert_validator_state(pool_address, 204, 101, 0, 0, 0);

        // Lockup is renewed and validator is still active.
        assert!(stake::get_validator_state(pool_address) == 2, 4);
        assert!(stake::get_remaining_lockup_secs(pool_address) == LOCKUP_CYCLE_SECONDS, 5);

        // Validator withdraws from inactive stake multiple times.
        dp::withdraw(validator, pool_address, 50);
        assert!(coin::balance<AptosCoin>(validator_address) == 750, 6);
        stake::assert_validator_state(pool_address, 204, 51, 0, 0, 0);
        dp::withdraw(validator, pool_address, 51);

        assert!(coin::balance<AptosCoin>(validator_address) == 800, 7);
        stake::assert_validator_state(pool_address, 204, 1, 0, 0, 0);

        // Enough time has passed again and the validator's lockup is renewed once more. Validator is still active.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch(&pools);
        assert!(stake::get_validator_state(pool_address) == 2, 8);
        assert!(stake::get_remaining_lockup_secs(pool_address) == LOCKUP_CYCLE_SECONDS, 9);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_inactive_validator_with_existing_lockup_join_validator_set(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 100, false, false);

        // Validator sets lockup before even joining the set and lets half of lockup pass by.
        dp::increase_lockup(validator);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS / 2);
        let validator_address = dp::get_owned_pool_address(signer::address_of(validator));
        let pools = vector::singleton(validator_address);
        assert!(stake::get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS / 2, 1);

        // Join the validator set with an existing lockup
        stake::join_validator_set(validator, validator_address);

        // Validator is added to the set but lockup time shouldn't have changed.
        end_epoch(&pools);
        assert!(stake::get_validator_state(validator_address) == 2, 2);
        assert!(stake::get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS / 2 - EPOCH_DURATION, 3);
        stake::assert_validator_state(validator_address, 100, 0, 0, 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10012)]
    public entry fun test_cannot_reduce_lockup(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 100, false, false);

        // Increase lockup.
        dp::increase_lockup(validator);
        // Reduce recurring lockup to 0.
        staking_config::update_recurring_lockup_duration_secs(aptos_framework, 1);
        // INcrease lockup should now fail because the new lockup < old lockup.
        dp::increase_lockup(validator);
    }

    #[test(aptos_framework = @aptos_framework, validator_1 = @0x123, validator_2 = @0x234)]
    #[expected_failure(abort_code = 0x1000D)]
    public entry fun test_inactive_validator_cannot_join_if_exceed_increase_limit(
        aptos_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
    ) {
        // Only 50% voting power increase is allowed in each epoch.
        initialize_for_test_custom(aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 10, 50);
        initialize_test_validator(validator_1, 100, false, false);
        initialize_test_validator(validator_2, 100, false, false);
        let validator_1_address = dp::get_owned_pool_address(signer::address_of(validator_1));
        let validator_2_address = dp::get_owned_pool_address(signer::address_of(validator_2));
        let pools = vector::singleton(validator_1_address);
        vector::push_back(&mut pools, validator_2_address);

        // Validator 1 needs to be in the set so validator 2's added stake counts against the limit.
        stake::join_validator_set(validator_1, validator_1_address);
        stake::end_epoch();

        end_epoch(&pools);

        // Validator 2 joins the validator set but their stake would lead to exceeding the voting power increase limit.
        // Therefore, this should fail.
        stake::join_validator_set(validator_2, validator_2_address);
    }

    #[test(aptos_framework = @aptos_framework, validator_1 = @0x123, validator_2 = @0x234)]
    public entry fun test_pending_active_validator_can_add_more_stake(
        aptos_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
    ) {
        initialize_for_test_custom(aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 10, 10000);
        // Need 1 validator to be in the active validator set so joining limit works.
        initialize_test_validator(validator_1, 100, false, true);
        initialize_test_validator(validator_2, 100, false, false);

        // Add more stake while still pending_active.
        let validator_2_address = dp::get_owned_pool_address(signer::address_of(validator_2));
        stake::join_validator_set(validator_2, validator_2_address);
        assert!(stake::get_validator_state(validator_2_address) == 1, 0);
        mint_and_add_stake(validator_2, 100);
        stake::assert_validator_state(validator_2_address, 200, 0, 0, 0, 0);
    }

    #[test(aptos_framework = @aptos_framework, validator_1 = @0x123, validator_2 = @0x234)]
    #[expected_failure(abort_code = 0x1000D)]
    public entry fun test_pending_active_validator_cannot_add_more_stake_than_limit(
        aptos_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
    ) {
        // 100% voting power increase is allowed in each epoch.
        initialize_for_test_custom(aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 10, 100);
        // Need 1 validator to be in the active validator set so joining limit works.
        initialize_test_validator(validator_1, 100, true, true);

        // Validator 2 joins the validator set but epoch has not ended so they're still pending_active.
        // Current voting power increase is already 100%. This is not failing yet.
        initialize_test_validator(validator_2, 100, true, false);

        // Add more stake, which now exceeds the 100% limit. This should fail.
        mint_and_add_stake(validator_2, 1);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_pending_active_validator_leaves_validator_set(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        // Validator joins but epoch hasn't ended, so the validator is still pending_active.
        initialize_test_validator(validator, 100, true, false);
        let validator_address = dp::get_owned_pool_address(signer::address_of(validator));
        assert!(stake::get_validator_state(validator_address) == 1, 0);

        // Leave the validator set immediately.
        stake::leave_validator_set(validator, validator_address);
        assert!(stake::get_validator_state(validator_address) == 4, 1);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000D)]
    public entry fun test_active_validator_cannot_add_more_stake_than_limit_in_multiple_epochs(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        // Only 50% voting power increase is allowed in each epoch.
        initialize_for_test_custom(aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 10, 50);
        // Add initial stake and join the validator set.
        initialize_test_validator(validator, 100, true, true);

        let validator_address = dp::get_owned_pool_address(signer::address_of(validator));
        let pools = vector::singleton(validator_address);
        stake::assert_validator_state(validator_address, 100, 0, 0, 0, 0);

        end_epoch(&pools);
        stake::assert_validator_state(validator_address, 110, 0, 0, 0, 0);

        end_epoch(&pools);
        stake::assert_validator_state(validator_address, 121, 0, 0, 0, 0);
        // Add more than 50% limit. The following line should fail.
        mint_and_add_stake(validator, 99);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000D)]
    public entry fun test_active_validator_cannot_add_more_stake_than_limit(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        // Only 50% voting power increase is allowed in each epoch.
        initialize_for_test_custom(aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 10, 50);
        initialize_test_validator(validator, 100, true, true);

        // Add more than 50% limit. This should fail.
        mint_and_add_stake(validator, 51);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_active_validator_unlock_partial_stake(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        // Reward rate = 10%.
        initialize_for_test_custom(aptos_framework, 50, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 10, 100);
        initialize_test_validator(validator, 100, true, true);

        // Unlock half of the coins.
        let validator_address = dp::get_owned_pool_address(signer::address_of(validator));
        let pools = vector::singleton(validator_address);

        assert!(stake::get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 1);
        dp::unlock(validator, validator_address, 50);
        stake::assert_validator_state(validator_address, 50, 0, 0, 50, 0);

        // Enough time has passed so the current lockup cycle should have ended.
        // 50 coins should have unlocked while the remaining 51 (50 + rewards) should stay locked for another cycle.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch(&pools);
        assert!(stake::get_validator_state(validator_address) == 2, 2);
        // Validator received rewards in both active and pending inactive.
        stake::assert_validator_state(validator_address, 55, 55, 0, 0, 0);
        assert!(stake::get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 3);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_active_validator_can_withdraw_all_stake_and_rewards_at_once(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 1000, true, true);
        let validator_address = dp::get_owned_pool_address(signer::address_of(validator));
        let pools = vector::singleton(validator_address);
        assert!(stake::get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 0);

        // One more epoch passes to generate rewards.
        end_epoch(&pools);

        assert!(stake::get_validator_state(validator_address) == 2, 1);
        stake::assert_validator_state(validator_address, 1010, 0, 0, 0, 0);

        // Unlock all coins while still having a lockup.
        assert!(stake::get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS - EPOCH_DURATION, 2);
        dp::unlock(validator, validator_address, 1010);
        stake::assert_validator_state(validator_address, 1, 0, 0, 1009, 0);

        // One more epoch passes while the current lockup cycle (3600 secs) has not ended.
        timestamp::fast_forward_seconds(1000);
        end_epoch(&pools);
        // Validator should not be removed from the validator set since their 100 coins in pending_inactive state should
        // still count toward voting power.
        assert!(stake::get_validator_state(validator_address) == 2, 3);
        stake::assert_validator_state(validator_address, 1, 0, 0, 1019, 0);

        // Enough time has passed so the current lockup cycle should have ended. Funds are now fully unlocked.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch(&pools);
        stake::assert_validator_state(validator_address, 1, 1029, 0, 0, 0);
        // Validator ahs been kicked out of the validator set as their stake is 0 now.
        assert!(stake::get_validator_state(validator_address) == 4, 4);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_active_validator_unlocking_more_than_available_stake_should_cap(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 100, false, false);

        // Validator unlocks more stake than they have active. This should limit the dp::unlock to 100.
        let validator_address = dp::get_owned_pool_address(signer::address_of(validator));
        dp::unlock(validator, validator_address, 200);
        stake::assert_validator_state(validator_address, 0, 0, 0, 100, 0);
    }


    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000A)]
    public entry fun test_validator_cannot_join_post_genesis(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test_custom(aptos_framework, 100, 10000, LOCKUP_CYCLE_SECONDS, false, 1, 100, 100);

        // Joining the validator set should fail as post genesis validator set change is not allowed.
        initialize_test_validator(validator, 100, true, true);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000E)]
    public entry fun test_invalid_pool_address(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 100,
            true, true);
        stake::join_validator_set(validator, @0x234);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000A)]
    public entry fun test_validator_cannot_leave_post_genesis(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test_custom(aptos_framework, 100, 10000, LOCKUP_CYCLE_SECONDS, false, 1, 100, 100);
        initialize_test_validator(validator, 100, false, false);

        // Bypass the check to join. This is the same function called during Genesis.
        let validator_address = dp::get_owned_pool_address(signer::address_of(validator));
        let pools = vector::singleton(validator_address);
        stake::join_validator_set(validator, validator_address);
        end_epoch(&pools);

        // Leaving the validator set should fail as post genesis validator set change is not allowed.
        stake::leave_validator_set(validator, validator_address);
    }
}
