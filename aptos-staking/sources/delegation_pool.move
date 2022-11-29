module bwarelabs::delegation_pool {
    use std::signer;
    use std::error;
    use std::fixed_point32 as fp32;

    use aptos_std::math64::min;
    use aptos_std::table::{Self, Table};

    use bwarelabs::epoch_manager::{Self, current_epoch, lockup_to_reward_epoch};
    use bwarelabs::deposits_adapter::{
    Self,
    get_deposit,
    get_renewed_deposit,
    increase_balance,
    increase_next_epoch_balance,
    decrease_balance,
    decrease_next_epoch_balance,
    };

    use aptos_framework::account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::stake;

    /// Delegation pool does not exist at the provided pool address.
    const EDELEGATION_POOL_DOES_NOT_EXIST: u64 = 1;

    /// Delegation pool owner capability does not exist at the provided account.
    const EOWNER_CAP_NOT_FOUND: u64 = 2;

    /// Account is already owning a delegation pool.
    const EOWNER_CAP_ALREADY_EXISTS: u64 = 3;

    /// Provided epochs do not form a valid interval.
    const EINVALID_EPOCH_INTERVAL: u64 = 4;

    /// Capability that represents ownership over not-shared operations of underlying stake pool.
    struct DelegationPoolOwnership has key, store {
        /// equal to address of the resource account owning the stake pool
        pool_address: address,
    }

    struct Delegation has store {
        /// `current_epoch_balance` == `active` and `next_epoch_balance` == `active + pending_active`
        active: deposits_adapter::DeferredDeposit,
        /// `current_epoch_balance` == `inactive` and `next_epoch_balance` == `inactive` + `pending_inactive`
        inactive: deposits_adapter::DeferredDeposit,
    }

    struct DelegationsOwned has key {
        /// set of delegations made by an account, indexed by host stake pool
        delegations: Table<address, Delegation>,
    }

    struct DelegationPool has key {
        /// current observable balance of delegation pool (excluding coins received externally - rewards)
        observable_pool_balance: u64,
        cumulative_rewards: Table<u64, fp32::FixedPoint32>,
        acc_delegation: Delegation,
        stake_pool_signer_cap: account::SignerCapability,
    }

    fun new_delegation(pool_address: address): Delegation {
        Delegation {
            // renews on next reward epoch
            active: deposits_adapter::new(pool_address, false),
            // renews on next lockup epoch
            inactive: deposits_adapter::new(pool_address, true),
        }
    }

    public entry fun initialize_delegation_pool(owner: &signer, seed: vector<u8>) {
        let owner_address = signer::address_of(owner);
        assert!(!owner_cap_exists(owner_address), error::already_exists(EOWNER_CAP_ALREADY_EXISTS));

        let (stake_pool_signer, stake_pool_signer_cap) = account::create_resource_account(owner, seed);
        coin::register<AptosCoin>(&stake_pool_signer);

        // stake_pool_signer is owner account of stake pool and has `OwnerCapability`
        let pool_address = signer::address_of(&stake_pool_signer);
        stake::initialize_stake_owner(&stake_pool_signer, 0, owner_address, owner_address);

        epoch_manager::initialize_epoch_manager(&stake_pool_signer);

        let cumulative_rewards = table::new<u64, fp32::FixedPoint32>();
        table::add(&mut cumulative_rewards, 1, fp32::create_from_raw_value(0));

        move_to(&stake_pool_signer, DelegationPool {
            observable_pool_balance: 0,
            cumulative_rewards,
            acc_delegation: new_delegation(pool_address),
            stake_pool_signer_cap,
        });

        // save resource-account address (inner pool address) + outer pool ownership on `owner`
        move_to(owner, DelegationPoolOwnership { pool_address });
    }

    fun get_stake_pool_signer(pool_address: address): signer acquires DelegationPool {
        account::create_signer_with_capability(&borrow_global<DelegationPool>(pool_address).stake_pool_signer_cap)
    }

    public fun owner_cap_exists(addr: address): bool {
        exists<DelegationPoolOwnership>(addr)
    }

    fun assert_owner_cap_exists(owner: address) {
        assert!(owner_cap_exists(owner), error::not_found(EOWNER_CAP_NOT_FOUND));
    }

    /// there are stake pools proxied by no delegation pool
    fun assert_delegation_pool_exists(pool_address: address) {
        assert!(exists<DelegationPool>(pool_address), error::invalid_argument(EDELEGATION_POOL_DOES_NOT_EXIST));
    }

    public fun get_owned_pool_address(owner: address): address acquires DelegationPoolOwnership {
        assert_owner_cap_exists(owner);
        borrow_global<DelegationPoolOwnership>(owner).pool_address
    }

    fun initialize_delegation(delegator: &signer, pool_address: address) acquires DelegationsOwned {
        // implicitly ensure `EpochsJournal` exists to query current epoch
        assert_delegation_pool_exists(pool_address);

        let delegator_address = signer::address_of(delegator);
        if (!exists<DelegationsOwned>(delegator_address)) {
            move_to(delegator, DelegationsOwned { delegations: table::new<address, Delegation>() });
        };
        let delegations = &mut borrow_global_mut<DelegationsOwned>(delegator_address).delegations;
        if (!table::contains(delegations, pool_address)) {
            table::add(delegations, pool_address, new_delegation(pool_address))
        }
    }

    public entry fun set_operator(owner: &signer, new_operator: address) acquires DelegationPoolOwnership, DelegationPool {
        stake::set_operator(
            &get_stake_pool_signer(get_owned_pool_address(signer::address_of(owner))),
            new_operator
        );
    }

    public entry fun set_delegated_voter(owner: &signer, new_voter: address) acquires DelegationPoolOwnership, DelegationPool {
        stake::set_delegated_voter(
            &get_stake_pool_signer(get_owned_pool_address(signer::address_of(owner))),
            new_voter
        );
    }

    public entry fun increase_lockup(owner: &signer) acquires DelegationPoolOwnership, DelegationPool {
        let pool_address = get_owned_pool_address(signer::address_of(owner));
        stake::increase_lockup(&get_stake_pool_signer(pool_address));

        // extend tracked `locked_until_secs` time for stake-pool if not already applied
        epoch_manager::after_increase_lockup(pool_address);
    }

    public entry fun add_stake(delegator: &signer, pool_address: address, amount: u64) acquires DelegationPool, DelegationsOwned {
        initialize_delegation(delegator, pool_address);
        restake(delegator, pool_address);

        let stake_pool_signer = get_stake_pool_signer(pool_address);
        let pool = borrow_global_mut<DelegationPool>(pool_address);
        pool.observable_pool_balance = pool.observable_pool_balance + amount;

        let acc_delegation = &mut pool.acc_delegation;
        let delegation = table::borrow_mut(
            &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations,
            pool_address
        );

        coin::transfer<AptosCoin>(delegator, signer::address_of(&stake_pool_signer), amount);
        stake::add_stake(&stake_pool_signer, amount);

        if (stake::is_current_epoch_validator(pool_address)) {
            increase_next_epoch_balance(&mut delegation.active, &mut acc_delegation.active, amount);
        } else {
            increase_balance(&mut delegation.active, &mut acc_delegation.active, amount);
        }
    }

    public entry fun unlock(delegator: &signer, pool_address: address, amount: u64) acquires DelegationPool, DelegationsOwned {
        restake(delegator, pool_address);

        let stake_pool_signer = get_stake_pool_signer(pool_address);
        let acc_delegation = &mut borrow_global_mut<DelegationPool>(pool_address).acc_delegation;
        let delegation = table::borrow_mut(
            &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations,
            pool_address
        );

        let (_, active, _) = get_renewed_deposit(&delegation.active);
        amount = min(amount, active);
        stake::unlock(&stake_pool_signer, amount);

        decrease_balance(&mut delegation.active, &mut acc_delegation.active, amount);
        increase_next_epoch_balance(&mut delegation.inactive, &mut acc_delegation.inactive, amount);
    }

    public entry fun reactivate_stake(delegator: &signer, pool_address: address, amount: u64) acquires DelegationPool, DelegationsOwned {
        restake(delegator, pool_address);

        let stake_pool_signer = get_stake_pool_signer(pool_address);
        let acc_delegation = &mut borrow_global_mut<DelegationPool>(pool_address).acc_delegation;
        let delegation = table::borrow_mut(
            &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations,
            pool_address
        );

        let (_, inactive, inactive_and_pending_inactive) = get_renewed_deposit(&delegation.inactive);
        // invariant: `inactive` next == `inactive` current + pending_inactive
        amount = min(amount, inactive_and_pending_inactive - inactive);
        stake::reactivate_stake(&stake_pool_signer, amount);

        decrease_next_epoch_balance(&mut delegation.inactive, &mut acc_delegation.inactive, amount);
        increase_balance(&mut delegation.active, &mut acc_delegation.active, amount);
    }

    public entry fun withdraw(delegator: &signer, pool_address: address, amount: u64) acquires DelegationPool, DelegationsOwned {
        restake(delegator, pool_address);

        let stake_pool_signer = get_stake_pool_signer(pool_address);
        let pool = borrow_global_mut<DelegationPool>(pool_address);

        let acc_delegation = &mut pool.acc_delegation;
        let delegation = table::borrow_mut(
            &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations,
            pool_address
        );

        let (_, inactive, _) = get_renewed_deposit(&delegation.inactive);
        amount = min(amount, inactive);
        stake::withdraw(&stake_pool_signer, amount);
        pool.observable_pool_balance = pool.observable_pool_balance - amount;

        decrease_balance(&mut delegation.inactive, &mut acc_delegation.inactive, amount);
        coin::transfer<AptosCoin>(&stake_pool_signer, signer::address_of(delegator), amount);
    }

    fun compute_reward_over_interval(
        pool_address: address,
        balance_over_interval: u64,
        begin_epoch: u64,
        end_epoch: u64
    ): u64 acquires DelegationPool {
        // skip computation when no rewards produced
        if (balance_over_interval == 0 || begin_epoch == end_epoch) {
            return 0
        };
        assert!(begin_epoch < end_epoch, error::invalid_state(EINVALID_EPOCH_INTERVAL));

        let cumulative_rewards = &borrow_global<DelegationPool>(pool_address).cumulative_rewards;
        fp32::multiply_u64(balance_over_interval,
            fp32::create_from_raw_value(
                fp32::get_raw_value(*table::borrow(cumulative_rewards, end_epoch)) -
                fp32::get_raw_value(*table::borrow(cumulative_rewards, begin_epoch))
            )
        )
    }

    /**
     * Restake all rewards produced by a delegator from its `active` and `pending-inactive` stake
     * since the last restake and up to the previous delegation-pool epoch.
     * The underlying rewards on the stake-pool are automatically restaked by aptos staking module, 
     * but not individually collected for each user of the delegation-pool.
     * INVARIANT:`restake` MUST be called before any stake-changing operation on a delegation in order
     * to capture rewards produced under old balances which are about to change.
     */
    public entry fun restake(delegator: &signer, pool_address: address) acquires DelegationPool, DelegationsOwned {
        // prior to all stake-changing ops, try moving to a new epoch in order to ensure that
        // at least one aptos epoch will have passed by the time these deferred ops will be applied ~ 
        // stake state should change on stake-pool before on delegation-pool
        end_epoch(pool_address);
        let current_epoch = current_epoch(pool_address);
        let delegation = table::borrow_mut(
            &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations,
            pool_address
        );

        let (last_restake_epoch, active, active_and_pending_active) = get_deposit(&delegation.active);
        // inductively, last epoch when delegation changed == last restake epoch (collected rewards up to previous)
        if (last_restake_epoch == current_epoch) {
            return
        };

        let rewards_active = compute_reward_over_interval(
            // earned in last_restake_epoch - only active stake is earning
            pool_address,
            active,
            last_restake_epoch,
            last_restake_epoch + 1
        ) + compute_reward_over_interval(
            // earned in [last_restake_epoch + 1, current_epoch) - pending stake activated and remained constant
            pool_address,
            active_and_pending_active,
            last_restake_epoch + 1,
            current_epoch
        );

        let (last_unlock_epoch, inactive, inactive_and_pending_inactive) = get_deposit(&delegation.inactive);
        let (unlock_epoch, unlocked) = lockup_to_reward_epoch(pool_address, last_unlock_epoch + 1);
        // as both active and inactive stakes of a delegation are always updated together:
        // `unlock_epoch` <= `last_restake_epoch` <= next unlocking epoch to `last_unlock_epoch`

        let rewards_pending_inactive = compute_reward_over_interval(
            // earned in [last_restake_epoch, current_epoch/unlock_epoch) - pending stake could have been inactivated
            pool_address,
            inactive_and_pending_inactive - inactive,
            last_restake_epoch,
            // not `unlocked` means pending inactive stake not inactivated by current epoch
            if (unlocked) unlock_epoch else current_epoch
        );

        // also sync accumulator delegation as new coins have been added
        let acc_delegation = &mut borrow_global_mut<DelegationPool>(pool_address).acc_delegation;
        increase_balance(&mut delegation.active, &mut acc_delegation.active, rewards_active);
        // pending-inactive rewards get unlocked along with the stake producing them
        if (unlocked && unlock_epoch <= current_epoch) {
            increase_balance(&mut delegation.inactive, &mut acc_delegation.inactive, rewards_pending_inactive);
        } else {
            increase_next_epoch_balance(&mut delegation.inactive, &mut acc_delegation.inactive, rewards_pending_inactive);
        }
    }

    fun get_pool_balance(pool_address: address): u64 {
        let (active, inactive, pending_active, pending_inactive) = stake::get_stake(pool_address);
        active + inactive + pending_active + pending_inactive
    }

    fun capture_previous_epoch_rewards(pool_address: address, earning_stake: u64): fp32::FixedPoint32 acquires DelegationPool {
        let total_balance = get_pool_balance(pool_address);
        let observable_balance = &mut borrow_global_mut<DelegationPool>(pool_address).observable_pool_balance;
        let epoch_rewards = total_balance - *observable_balance;

        if (earning_stake != 0) {
            *observable_balance = total_balance;
            fp32::create_from_rational(epoch_rewards, earning_stake)
        } else {
            // leave excess balance to current epoch if zero earning stake on pool at previous one
            fp32::create_from_raw_value(0)
        }
    }

    public entry fun end_epoch(pool_address: address) acquires DelegationPool {
        assert_delegation_pool_exists(pool_address);

        let acc_delegation = &borrow_global<DelegationPool>(pool_address).acc_delegation;
        let (_, active, _) = get_renewed_deposit(&acc_delegation.active);
        let (_, inactive, inactive_and_pending_inactive) = get_renewed_deposit(&acc_delegation.inactive);
        active = active + inactive_and_pending_inactive - inactive;

        if (!epoch_manager::advance_epoch(pool_address)) {
            return
        };
        let current_epoch = current_epoch(pool_address);
        let normalized_rwd = capture_previous_epoch_rewards(pool_address, active);

        // persist the cumulative reward produced by the delegation pool until this new epoch
        let cumulative_rewards = &mut borrow_global_mut<DelegationPool>(pool_address).cumulative_rewards;
        normalized_rwd = fp32::create_from_raw_value(
            fp32::get_raw_value(normalized_rwd) +
            fp32::get_raw_value(*table::borrow(cumulative_rewards, current_epoch - 1))
        );
        table::add(cumulative_rewards, current_epoch, normalized_rwd);
    }

    // #[test_only]
    // use aptos_std::debug::print;
    #[test_only]
    use aptos_std::vector;
    #[test_only]
    use aptos_framework::reconfiguration;
    #[test_only]
    use aptos_framework::timestamp;

    #[test_only]
    const CONSENSUS_KEY_1: vector<u8> = x"8a54b92288d4ba5073d3a52e80cc00ae9fbbc1cc5b433b46089b7804c38a76f00fc64746c7685ee628fc2d0b929c2294";
    #[test_only]
    const CONSENSUS_POP_1: vector<u8> = x"a9d6c1f1270f2d1454c89a83a4099f813a56dc7db55591d46aa4e6ccae7898b234029ba7052f18755e6fa5e6b73e235f14efc4e2eb402ca2b8f56bad69f965fc11b7b25eb1c95a06f83ddfd023eac4559b6582696cfea97b227f4ce5bdfdfed0";

    #[test_only]
    const EPOCH_DURATION: u64 = 60;
    #[test_only]
    const LOCKUP_CYCLE_SECONDS: u64 = 3600;

    #[test_only]
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    #[test_only]
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    #[test_only]
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    #[test_only]
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    #[test_only]
    public fun end_aptos_epoch() {
        stake::end_epoch(); // also fast-forwards EPOCH_DURATION seconds
        reconfiguration::reconfigure_for_test_custom();
    }

    #[test_only]
    public fun end_epoch_synced(pool_address: address) acquires DelegationPool {
        end_aptos_epoch(); // change aptos anchor epoch
        end_epoch(pool_address); // successfully change epoch on delegation-pool
    }

    #[test_only]
    public fun initialize_for_test(aptos_framework: &signer) {
        initialize_for_test_custom(aptos_framework, 100, 10000, LOCKUP_CYCLE_SECONDS, true, 1, 100, 1000000);
    }

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
        stake::initialize_for_test_custom(
            aptos_framework,
            minimum_stake,
            maximum_stake,
            recurring_lockup_secs,
            allow_validator_set_change,
            rewards_rate_numerator,
            rewards_rate_denominator,
            voting_power_increase_limit,
        );
        reconfiguration::initialize_for_test(aptos_framework);
        end_aptos_epoch(); // start from non-zero aptos epoch
    }

    #[test_only]
    public fun initialize_test_validator(
        validator: &signer,
        amount: u64,
        should_join_validator_set: bool,
        should_end_epoch: bool,
    ) acquires DelegationPool, DelegationsOwned, DelegationPoolOwnership {
        let validator_address = signer::address_of(validator);
        if (!account::exists_at(validator_address)) {
            account::create_account_for_test(validator_address);
        };

        initialize_delegation_pool(validator, vector::empty<u8>());
        validator_address = get_owned_pool_address(validator_address);
        // validator is initially stake pool's operator and voter
        stake::rotate_consensus_key(validator, validator_address, CONSENSUS_KEY_1, CONSENSUS_POP_1);

        if (amount > 0) {
            stake::mint(validator, amount);
            add_stake(validator, validator_address, amount);
        };

        if (should_join_validator_set) {
            stake::join_validator_set(validator, validator_address);
        };
        if (should_end_epoch) {
            end_epoch_synced(validator_address);
        };
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_set_operator_and_delegated_voter(
        aptos_framework: &signer,
        validator: &signer,
    ) acquires DelegationPool, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);

        let validator_address = signer::address_of(validator);
        initialize_delegation_pool(validator, vector::empty<u8>());
        let pool_address = get_owned_pool_address(validator_address);

        assert!(stake::get_operator(pool_address) == validator_address, 1);
        set_operator(validator, @0x111);
        assert!(stake::get_operator(pool_address) == @0x111, 2);

        assert!(stake::get_delegated_voter(pool_address) == validator_address, 1);
        set_delegated_voter(validator, @0x112);
        assert!(stake::get_delegated_voter(pool_address) == @0x112, 2);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x60002)]
    public entry fun test_cannot_set_operator(
        aptos_framework: &signer,
        validator: &signer,
    ) acquires DelegationPool, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        // account does not own any delegation pool
        set_operator(validator, @0x111);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x60002)]
    public entry fun test_cannot_set_delegated_voter(
        aptos_framework: &signer,
        validator: &signer,
    ) acquires DelegationPool, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        // account does not own any delegation pool
        set_delegated_voter(validator, @0x112);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x80003)]
    public entry fun test_already_owns_delegation_pool(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        initialize_for_test(aptos_framework);
        initialize_delegation_pool(validator, x"00");
        initialize_delegation_pool(validator, x"01");
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_initialize_delegation_pool(
        aptos_framework: &signer,
        validator: &signer,
    ) acquires DelegationPool, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);

        let validator_address = signer::address_of(validator);
        initialize_delegation_pool(validator, vector::empty<u8>());
        let pool_address = get_owned_pool_address(validator_address);

        assert!(stake::stake_pool_exists(pool_address), 1);
        assert!(stake::get_operator(pool_address) == validator_address, 2);
        assert!(stake::get_delegated_voter(pool_address) == validator_address, 3);

        assert!(borrow_global<DelegationPoolOwnership>(validator_address).pool_address == pool_address, 4);

        let delegation_pool = borrow_global<DelegationPool>(pool_address);
        assert!(account::get_signer_capability_address(&delegation_pool.stake_pool_signer_cap) == pool_address, 5);
        assert!(delegation_pool.observable_pool_balance == 0, 6);

        let (consensus_pubkey, network_addresses, fullnode_addresses) = stake::get_validator_config(pool_address);
        assert!(consensus_pubkey == vector::empty<u8>(), 7);
        assert!(network_addresses == vector::empty<u8>(), 8);
        assert!(fullnode_addresses == vector::empty<u8>(), 9);

        assert!(current_epoch(pool_address) == 1, 10);
        assert!(epoch_manager::current_lockup_epoch(pool_address) == 1, 11);
        // check cumulative reward has been set for pool's genesis epoch
        assert!(
            table::contains(&delegation_pool.cumulative_rewards, 1) &&
            fp32::get_raw_value(*table::borrow(&delegation_pool.cumulative_rewards, 1)) == 0, 12);
        assert_delegation_pool(pool_address, 0, 0, 0, 0, false);
        assert!(get_pool_balance(pool_address) == 0, 13);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_add_stake_single(
        aptos_framework: &signer,
        validator: &signer,
    ) acquires DelegationPool, DelegationsOwned, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 100, false, false);

        let validator_address = signer::address_of(validator);
        let pool_address = get_owned_pool_address(validator_address);
        // stake pool is pending active => all stake is activated by default
        assert_delegation(validator_address, pool_address, 100, 0, 0, 0, true);

        stake::mint(validator, 300);
        add_stake(validator, pool_address, 100);
        assert_delegation(validator_address, pool_address, 200, 0, 0, 0, true);
        assert_delegation_pool(pool_address, 200, 0, 0, 0, true);

        stake::join_validator_set(validator, pool_address);
        end_epoch_synced(pool_address);

        // add 100 coins which will be pending active until next epoch
        add_stake(validator, pool_address, 100);
        assert_delegation(validator_address, pool_address, 200, 0, 100, 0, true);
        assert_delegation_pool(pool_address, 200, 0, 100, 0, true);

        // add more stake in the same epoch
        add_stake(validator, pool_address, 50);
        assert_delegation(validator_address, pool_address, 200, 0, 150, 0, true);
        assert_delegation_pool(pool_address, 200, 0, 150, 0, true);

        end_epoch_synced(pool_address);
        assert_delegation(validator_address, pool_address, 350, 0, 0, 0, true);
        assert_delegation_pool(pool_address, 350, 0, 0, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123, delegator = @0x010)]
    public entry fun test_add_stake_many(
        aptos_framework: &signer,
        validator: &signer,
        delegator: &signer,
    ) acquires DelegationPool, DelegationsOwned, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 100, true, true);
        let validator_address = signer::address_of(validator);
        let pool_address = get_owned_pool_address(validator_address);

        let delegator_address = signer::address_of(delegator);
        account::create_account_for_test(delegator_address);

        stake::mint(delegator, 300);
        add_stake(delegator, pool_address, 200);
        assert_delegation(delegator_address, pool_address, 0, 0, 200, 0, true);
        assert_delegation_pool(pool_address, 100, 0, 200, 0, true);

        end_epoch_synced(pool_address);

        stake::mint(validator, 250);
        add_stake(validator, pool_address, 250);
        // 100 active stake of validator produced 100 * 10% - 1 fp32 imprecision
        assert_delegation(validator_address, pool_address, 100, 0, 250, 0, true);
        assert_delegation(delegator_address, pool_address, 200, 0, 0, 0, true);
        assert_delegation_pool(pool_address, 300, 0, 250, 0, true);

        add_stake(delegator, pool_address, 100);
        assert_delegation(validator_address, pool_address, 100, 0, 250, 0, true);
        assert_delegation(delegator_address, pool_address, 200, 0, 100, 0, true);
        assert_delegation_pool(pool_address, 300, 0, 350, 0, true);

        end_epoch_synced(pool_address);
        // no restake has been triggered => tracked stakes remain the same
        assert_delegation(validator_address, pool_address, 350, 0, 0, 0, true);
        assert_delegation(delegator_address, pool_address, 300, 0, 0, 0, true);
        assert_delegation_pool(pool_address, 650, 0, 0, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123, delegator = @0x010)]
    public entry fun test_unlock_single(
        aptos_framework: &signer,
        validator: &signer,
        delegator: &signer,
    ) acquires DelegationPool, DelegationsOwned, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 100, true, true);

        let validator_address = signer::address_of(validator);
        let pool_address = get_owned_pool_address(validator_address);

        stake::mint(validator, 200);
        // add 200 coins as pending active stake
        add_stake(validator, pool_address, 200);
        assert_delegation(validator_address, pool_address, 100, 0, 200, 0, true);

        // cannot unlock pending active stake
        unlock(validator, pool_address, 200);
        assert_delegation(validator_address, pool_address, 0, 0, 200, 100, true);
        assert_delegation_pool(pool_address, 0, 0, 200, 100, true);
        reactivate_stake(validator, pool_address, 100);
        assert_delegation(validator_address, pool_address, 100, 0, 200, 0, true);

        end_epoch_synced(pool_address);
        assert_delegation(validator_address, pool_address, 300, 0, 0, 0, true);

        // once stake becomes active can unlock some of it
        unlock(validator, pool_address, 50);
        assert_delegation(validator_address, pool_address, 250, 0, 0, 50, true);
        assert_delegation_pool(pool_address, 250, 0, 0, 50, true);

        assert!(stake::get_remaining_lockup_secs(pool_address) == LOCKUP_CYCLE_SECONDS - EPOCH_DURATION, 1);
        end_epoch_synced(pool_address);

        // pending inactive stake should not be inactivated yet
        assert_delegation(validator_address, pool_address, 250, 0, 0, 50, true);

        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS - 2 * EPOCH_DURATION);
        end_epoch_synced(pool_address); // forwards another EPOCH_DURATION and unlocks stake

        assert_delegation(validator_address, pool_address, 250, 50, 0, 0, true);

        let delegator_address = signer::address_of(delegator);
        account::create_account_for_test(delegator_address);
        stake::mint(delegator, 10);
        add_stake(delegator, pool_address, 10);

        // try to withdraw stake unlocked by others
        withdraw(delegator, pool_address, 50);
        assert!(coin::balance<AptosCoin>(delegator_address) == 0, 1);

        // withdraw own unlocked stake
        withdraw(validator, pool_address, 50);
        assert!(coin::balance<AptosCoin>(validator_address) == 50, 2);
        // withdraw triggered a restake: 250 active * 10% + 50 pending inactive * 10% - 1 fp32 imprecision
        assert_delegation(validator_address, pool_address, 252, 0, 0, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_reactivate_stake_single(
        aptos_framework: &signer,
        validator: &signer,
    ) acquires DelegationPool, DelegationsOwned, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 200, true, true);

        let validator_address = signer::address_of(validator);
        let pool_address = get_owned_pool_address(validator_address);

        unlock(validator, pool_address, 100);
        assert_delegation(validator_address, pool_address, 100, 0, 0, 100, true);
        assert_delegation_pool(pool_address, 100, 0, 0, 100, true);

        stake::mint(validator, 150);
        add_stake(validator, pool_address, 150);
        assert_delegation(validator_address, pool_address, 100, 0, 150, 100, true);
        assert_delegation_pool(pool_address, 100, 0, 150, 100, true);

        // cannot reactivate pending active
        reactivate_stake(validator, pool_address, 150);
        assert_delegation(validator_address, pool_address, 200, 0, 150, 0, true);

        end_epoch_synced(pool_address);
        assert_delegation(validator_address, pool_address, 350, 0, 0, 0, true);

        // a restake is triggered here and produces 200 * 10% - 1 active rewards
        unlock(validator, pool_address, 150);
        assert_delegation(validator_address, pool_address, 201, 0, 0, 150, true);

        // inactivate 150 coins
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS - 2 * EPOCH_DURATION);
        end_epoch_synced(pool_address);
        assert_delegation(validator_address, pool_address, 201, 150, 0, 0, true);

        // inner restake produces: 201 * 10% - 1 active and 150 * 10% pending inactive rewards
        unlock(validator, pool_address, 100);
        assert_delegation(validator_address, pool_address, 102, 151, 0, 100, true);

        // cannot reactivate inactive stake
        reactivate_stake(validator, pool_address, 251);
        assert_delegation(validator_address, pool_address, 202, 151, 0, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123, delegator = @0x010)]
    public entry fun test_increase_lockup(
        aptos_framework: &signer,
        validator: &signer,
        delegator: &signer,
    ) acquires DelegationPool, DelegationsOwned, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 300, true, true);
        let validator_address = signer::address_of(validator);
        let pool_address = get_owned_pool_address(validator_address);

        let delegator_address = signer::address_of(delegator);
        account::create_account_for_test(delegator_address);

        unlock(validator, pool_address, 100);
        assert_delegation(validator_address, pool_address, 200, 0, 0, 100, true);
        assert!(stake::get_remaining_lockup_secs(pool_address) == LOCKUP_CYCLE_SECONDS, 1);

        end_epoch_synced(pool_address);
        assert!(stake::get_remaining_lockup_secs(pool_address) == LOCKUP_CYCLE_SECONDS - EPOCH_DURATION, 2);

        // will extend stake-pool lockup with EPOCH_DURATION and apply to delegation-pool as well
        increase_lockup(validator);
        assert!(stake::get_remaining_lockup_secs(pool_address) == LOCKUP_CYCLE_SECONDS, 3);

        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS - 2 * EPOCH_DURATION);
        end_epoch_synced(pool_address); // remaining lockup will be EPOCH_DURATION

        withdraw(validator, pool_address, 100); // pending inactive stake has not been unlocked yet
        assert_delegation(validator_address, pool_address, 202, 0, 0, 101, true);
        assert!(coin::balance<AptosCoin>(validator_address) == 0, 1);

        // advance EPOCH_DURATION to unlock stake
        end_epoch_synced(pool_address);
        assert_delegation(validator_address, pool_address, 202, 101, 0, 0, true);

        withdraw(validator, pool_address, 200); // pending inactive stake is unlocked
        assert!(coin::balance<AptosCoin>(validator_address) == 101, 2);

        // schedule some coins for unlocking
        unlock(validator, pool_address, 100);

        // trigger a refresh of the stake-pool lockup only
        assert!(stake::get_remaining_lockup_secs(pool_address) == LOCKUP_CYCLE_SECONDS, 4);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS - EPOCH_DURATION);
        end_aptos_epoch();
        // increase_lockup: new lockup time should be > old lockup
        timestamp::fast_forward_seconds(1);
        // the unlock epoch passed on stake-pool, but saved lockup on delegation-pool should not be changed
        increase_lockup(validator);

        // check that current unlock time for stake-pool is in the future
        assert!(stake::get_remaining_lockup_secs(pool_address) == LOCKUP_CYCLE_SECONDS, 5);

        // however, delegation-pool can advance the unlock epoch as previous lockup time has not been updated
        let current_lockup_epoch = epoch_manager::current_lockup_epoch(pool_address);
        end_epoch(pool_address);
        assert!(current_lockup_epoch + 1 == epoch_manager::current_lockup_epoch(pool_address), 1);

        // stake also unlocked under the previous lockup which was finished on the stake-pool indeed
        withdraw(validator, pool_address, 100);
        assert!(coin::balance<AptosCoin>(signer::address_of(validator)) == 201, 3);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_active_stake_rewards(
        aptos_framework: &signer,
        validator: &signer,
    ) acquires DelegationPool, DelegationsOwned, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 1000, true, true);
        let validator_address = signer::address_of(validator);
        let pool_address = get_owned_pool_address(validator_address);

        end_epoch_synced(pool_address);
        assert_delegation(validator_address, pool_address, 1000, 0, 0, 0, true);

        // 1000 active stake * 10% - 1 from fp32 imprecision
        restake(validator, pool_address);
        assert_delegation(validator_address, pool_address, 1009, 0, 0, 0, true);

        stake::mint(validator, 200);
        add_stake(validator, pool_address, 200);
        end_epoch_synced(pool_address);

        restake(validator, pool_address);
        // 1009 active stake * 10% - 1 from fp32 imprecision
        // 200 pending active stake produced 0 rewards
        assert_delegation(validator_address, pool_address, 1218, 0, 0, 0, true);

        end_epoch_synced(pool_address);

        restake(validator, pool_address);
        // 1218 active stake * 10% - 1 from fp32 imprecision
        assert_delegation(validator_address, pool_address, 1229, 0, 0, 0, true);

        // advance 4 aptos epochs
        end_aptos_epoch();
        end_aptos_epoch();
        end_aptos_epoch();
        end_aptos_epoch();
        end_epoch(pool_address);

        // 1229 active stake * 10% * 4 epochs - 1
        restake(validator, pool_address);
        assert_delegation(validator_address, pool_address, 1276, 0, 0, 0, true);

        // schedule some coins for unlocking
        unlock(validator, pool_address, 200);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch_synced(pool_address);

        // 1076 active stake * 10% and 200 pending inactive * 10%
        restake(validator, pool_address);
        assert_delegation(validator_address, pool_address, 1086, 201, 0, 0, true);

        end_epoch_synced(pool_address);

        // 1086 active stake * 10% - 1 and 0 from inactive stake
        restake(validator, pool_address);
        assert_delegation(validator_address, pool_address, 1095, 201, 0, 0, true);

        stake::mint(validator, 1000);
        add_stake(validator, pool_address, 1000);

        end_epoch_synced(pool_address);

        // 1095 active stake * 10%
        restake(validator, pool_address);
        assert_delegation(validator_address, pool_address, 2105, 201, 0, 0, true);

        end_epoch_synced(pool_address);

        // 2105 active stake * 10% - 1
        restake(validator, pool_address);
        assert_delegation(validator_address, pool_address, 2125, 201, 0, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123, delegator = @0x010)]
    public entry fun test_active_stake_rewards_multiple(
        aptos_framework: &signer,
        validator: &signer,
        delegator: &signer,
    ) acquires DelegationPool, DelegationsOwned, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 200, true, true);
        let validator_address = signer::address_of(validator);
        let pool_address = get_owned_pool_address(validator_address);

        let delegator_address = signer::address_of(delegator);
        account::create_account_for_test(delegator_address);

        // will produce rewards from next epoch
        stake::mint(delegator, 300);
        add_stake(delegator, pool_address, 300);
        assert_delegation(delegator_address, pool_address, 0, 0, 300, 0, true);
        assert_delegation_pool(pool_address, 200, 0, 300, 0, true);

        // advance 4 aptos epochs
        end_aptos_epoch();
        end_aptos_epoch();
        end_aptos_epoch();
        end_aptos_epoch();
        // automatically advances delegation-pool epoch
        restake(validator, pool_address);
        restake(delegator, pool_address);
        // no rewards produced by pending active stake (as tracked by delegation-pool)
        assert_delegation(delegator_address, pool_address, 300, 0, 0, 0, true);
        // 200 validator's active * 10% * 4 epochs + 300 delegator's active * 3 epochs - 1 from fp32 imprecision
        assert_delegation(validator_address, pool_address, 216, 0, 0, 0, true);
        assert_delegation_pool(pool_address, 516, 0, 0, 0, true);

        // advance 2 aptos epochs
        end_aptos_epoch();
        end_aptos_epoch();
        // automatically advances delegation-pool epoch
        restake(validator, pool_address);
        restake(delegator, pool_address);
        // 300 delegator's active * 2 epochs - 1 from fp32 imprecision
        assert_delegation(delegator_address, pool_address, 305, 0, 0, 0, true);
        // 200 validator's active * 2 epochs
        assert_delegation(validator_address, pool_address, 220, 0, 0, 0, true);
        assert_delegation_pool(pool_address, 525, 0, 0, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_pending_inactive_stake_rewards(
        aptos_framework: &signer,
        validator: &signer,
    ) acquires DelegationPool, DelegationsOwned, DelegationPoolOwnership {
        initialize_for_test(aptos_framework);
        initialize_test_validator(validator, 1000, true, true);
        let validator_address = signer::address_of(validator);
        let pool_address = get_owned_pool_address(validator_address);

        end_epoch_synced(pool_address);

        // automatically restakes rewards: 1000 validator's active * 10% - 1
        unlock(validator, pool_address, 200);
        assert_delegation(validator_address, pool_address, 809, 0, 0, 200, true);

        end_epoch_synced(pool_address); // 8 active 2 pending inactive
        end_epoch_synced(pool_address); // 8 active 2 pending inactive

        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch_synced(pool_address); // 8 active 2 pending inactive
        end_epoch_synced(pool_address); // 8 active 0 pending inactive (inactivated)

        // no restake happened, individual stakes remain untouched
        assert_delegation(validator_address, pool_address, 809, 200, 0, 0, true);
        restake(validator, pool_address);
        assert_delegation(validator_address, pool_address, 841, 205, 0, 0, true);

        // rewards already restaked up to current epoch
        unlock(validator, pool_address, 200);
        assert_delegation(validator_address, pool_address, 641, 205, 0, 200, true);

        end_epoch_synced(pool_address); // 6 active 2 pending inactive
        end_epoch_synced(pool_address); // 6 active 2 pending inactive
        end_epoch_synced(pool_address); // 6 active 2 pending inactive
        end_epoch_synced(pool_address); // 6 active 2 pending inactive
        // the lockup cycle is not ended, pending inactive are still earning
        restake(validator, pool_address);
        assert_delegation(validator_address, pool_address, 665, 205, 0, 207, true);
    }

    #[test_only]
    public fun assert_delegation(
        delegator_address: address,
        pool_address: address,
        active_stake: u64,
        inactive_stake: u64,
        pending_active_stake: u64,
        pending_inactive_stake: u64,
        check_renewed: bool,
    ) acquires DelegationsOwned {
        let delegations = &borrow_global<DelegationsOwned>(delegator_address).delegations;
        let delegation = table::borrow(delegations, pool_address);
        let (_, actual_active, actual_active_and_pending_active) = read_deposit(&delegation.active, check_renewed);
        let (_, actual_inactive, actual_inactive_and_pending_inactive) = read_deposit(&delegation.inactive, check_renewed);

        assert!(actual_active == active_stake, actual_active);
        let actual_pending_active = actual_active_and_pending_active - actual_active;
        assert!(actual_pending_active == pending_active_stake, actual_pending_active);
        assert!(actual_inactive == inactive_stake, actual_inactive);
        let actual_pending_inactive = actual_inactive_and_pending_inactive - actual_inactive;
        assert!(actual_pending_inactive == pending_inactive_stake, actual_pending_inactive);
    }

    #[test_only]
    public fun assert_delegation_pool(
        pool_address: address,
        active_stake: u64,
        inactive_stake: u64,
        pending_active_stake: u64,
        pending_inactive_stake: u64,
        check_renewed: bool,
    ) acquires DelegationPool {
        let acc_delegation = &borrow_global<DelegationPool>(pool_address).acc_delegation;
        let (_, actual_active, actual_active_and_pending_active) = read_deposit(&acc_delegation.active, check_renewed);
        let (_, actual_inactive, actual_inactive_and_pending_inactive) = read_deposit(&acc_delegation.inactive, check_renewed);
        assert!(actual_active == active_stake, actual_active);
        let actual_pending_active = actual_active_and_pending_active - actual_active;
        assert!(actual_pending_active == pending_active_stake, actual_pending_active);
        assert!(actual_inactive == inactive_stake, actual_inactive);
        let actual_pending_inactive = actual_inactive_and_pending_inactive - actual_inactive;
        assert!(actual_pending_inactive == pending_inactive_stake, actual_pending_inactive);
    }

    #[test_only]
    fun read_deposit(deposit: &deposits_adapter::DeferredDeposit, check_renewed: bool): (u64, u64, u64) {
        if (check_renewed) {
            get_renewed_deposit(deposit)
        } else {
            get_deposit(deposit)
        }
    }
}
