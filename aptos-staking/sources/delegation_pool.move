module bwarelabs::delegation_pool {
    use std::signer;
    use std::error;
    use std::fixed_point32 as fp32;

    use aptos_std::math64::min;

    use bwarelabs::deposits_adapter::{
    Self,
    get_deposit,
    get_renewed_deposit,
    increase_balance,
    increase_next_epoch_balance,
    decrease_balance,
    decrease_next_epoch_balance,
    };
    use bwarelabs::epoch_manager::{Self, current_epoch, lockup_to_reward_epoch};

    use aptos_framework::coin::{Self};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_std::table::{Self, Table};
    use aptos_framework::account;
    use aptos_framework::stake::{Self};

    const APTOS_DENOMINATION: u128 = 100000000;

    /// Provided epochs do not form a valid interval.
    const EINVALID_EPOCH_INTERVAL: u64 = 1;

    /// Delegation pool owner capability does not exist at the provided account.
    const EOWNER_CAP_NOT_FOUND: u64 = 2;

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
        let (stake_pool_signer, stake_pool_signer_cap) = account::create_resource_account(owner, seed);
        coin::register<AptosCoin>(&stake_pool_signer);

        // stake_pool_signer is owner account of stake pool and has `OwnerCapability`
        let owner_address = signer::address_of(owner);
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
        account::create_signer_with_capability(&borrow_global_mut<DelegationPool>(pool_address).stake_pool_signer_cap)
    }

    fun assert_owner_cap_exists(owner: address) {
        assert!(exists<DelegationPoolOwnership>(owner), error::not_found(EOWNER_CAP_NOT_FOUND));
    }

    public fun get_owned_pool_address(owner: address): address acquires DelegationPoolOwnership {
        assert_owner_cap_exists(owner);
        borrow_global<DelegationPoolOwnership>(owner).pool_address
    }

    fun initialize_delegation(delegator: &signer, pool_address: address) acquires DelegationsOwned {
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
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global_mut<DelegationPoolOwnership>(owner_address);
        stake::set_operator(&get_stake_pool_signer(ownership_cap.pool_address), new_operator);
    }

    public entry fun set_delegated_voter(owner: &signer, new_voter: address) acquires DelegationPoolOwnership, DelegationPool {
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global_mut<DelegationPoolOwnership>(owner_address);
        stake::set_delegated_voter(&get_stake_pool_signer(ownership_cap.pool_address), new_voter);
    }

    public entry fun increase_lockup(owner: &signer) acquires DelegationPoolOwnership, DelegationPool {
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global_mut<DelegationPoolOwnership>(owner_address);
        stake::increase_lockup(&get_stake_pool_signer(ownership_cap.pool_address));

        epoch_manager::after_increase_lockup(ownership_cap.pool_address);
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
        // prior to stake-changing ops, try moving to a new epoch in order to ensure that
        // one aptos epoch passes and any deferred op applies after it already did at stake-pool level
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
}
