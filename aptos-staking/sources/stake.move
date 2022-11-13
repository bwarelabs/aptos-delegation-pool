module bwarelabs::delegation_pool {
    use std::signer;
    use std::error;

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
        cumulative_rewards: Table<u64, u128>,
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

        let cumulative_rewards = table::new<u64, u128>();
        table::add(&mut cumulative_rewards, 1, 0);

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
        let stake_pool_signer = get_stake_pool_signer(pool_address);
        coin::transfer<AptosCoin>(delegator, signer::address_of(&stake_pool_signer), amount);
        stake::add_stake(&stake_pool_signer, amount);

        initialize_delegation(delegator, pool_address);

        restake(delegator, pool_address);

        let pool = borrow_global_mut<DelegationPool>(pool_address);
        pool.observable_pool_balance = pool.observable_pool_balance + amount;


        let acc_delegation = &mut pool.acc_delegation;
        let delegation = table::borrow_mut(
            &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations,
            pool_address
        );

        if (stake::is_current_epoch_validator(pool_address)) {
            increase_next_epoch_balance(&mut delegation.active, amount);
            increase_next_epoch_balance(&mut acc_delegation.active, amount);
        } else {
            increase_balance(&mut delegation.active, amount);
            increase_balance(&mut acc_delegation.active, amount);
        }
    }
    
    public entry fun unlock(delegator: &signer, pool_address: address, amount: u64) acquires DelegationPool, DelegationsOwned {
        let stake_pool_signer = get_stake_pool_signer(pool_address);
        stake::unlock(&stake_pool_signer, amount);

        restake(delegator, pool_address);
        let acc_delegation = &mut borrow_global_mut<DelegationPool>(pool_address).acc_delegation;
        let delegation = table::borrow_mut(
            &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations,
            pool_address
        );

        decrease_balance(&mut delegation.active, amount);
        decrease_balance(&mut acc_delegation.active, amount);
        increase_next_epoch_balance(&mut delegation.inactive, amount);
        increase_next_epoch_balance(&mut acc_delegation.inactive, amount);
    }

    public entry fun reactivate_stake(delegator: &signer, pool_address: address, amount: u64) acquires DelegationPool, DelegationsOwned {
        let stake_pool_signer = get_stake_pool_signer(pool_address);
        stake::reactivate_stake(&stake_pool_signer, amount);

        restake(delegator, pool_address);
        let acc_delegation = &mut borrow_global_mut<DelegationPool>(pool_address).acc_delegation;
        let delegation = table::borrow_mut(
            &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations,
            pool_address
        );

        let (_, inactive, inactive_and_pending_inactive) = get_renewed_deposit(&delegation.inactive);
        assert!(amount <= inactive_and_pending_inactive - inactive, 1);

        decrease_next_epoch_balance(&mut delegation.inactive, amount);
        decrease_next_epoch_balance(&mut acc_delegation.inactive, amount);
        increase_balance(&mut delegation.active, amount);
        increase_balance(&mut acc_delegation.active, amount);
    }

    public entry fun withdraw(delegator: &signer, pool_address: address, amount: u64) acquires DelegationPool, DelegationsOwned {
        let stake_pool_signer = get_stake_pool_signer(pool_address);

        // if withdraw succeeds then amount is not producing rewards on global contract starting this epoch
        stake::withdraw(&stake_pool_signer, amount);

        let module_data = borrow_global_mut<DelegationPool>(pool_address);
        module_data.observable_pool_balance = module_data.observable_pool_balance - amount;

        restake(delegator, pool_address);
        let acc_delegation = &mut borrow_global_mut<DelegationPool>(pool_address).acc_delegation;
        let delegation = table::borrow_mut(
            &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations,
            pool_address
        );

        decrease_balance(&mut delegation.inactive, amount);
        decrease_balance(&mut acc_delegation.inactive, amount);
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

        assert!(begin_epoch < end_epoch, EINVALID_EPOCH_INTERVAL);

        let staking_store = borrow_global<DelegationPool>(pool_address);

        (((*table::borrow(&staking_store.cumulative_rewards, end_epoch) -
           *table::borrow(&staking_store.cumulative_rewards, begin_epoch)) * (balance_over_interval as u128) / APTOS_DENOMINATION) as u64)
    }

    public entry fun restake(delegator: &signer, pool_address: address) acquires DelegationPool, DelegationsOwned {
        end_epoch(pool_address);

        let delegations = &mut borrow_global_mut<DelegationsOwned>(signer::address_of(delegator)).delegations;
        let delegation = table::borrow_mut(delegations, pool_address);

        let (current_epoch, current_epoch_balance, next_epoch_balance) = get_deposit(&delegation.active);
        if (current_epoch == current_epoch(pool_address)) {
            return
        };
        let (current_unlock_epoch, inactive, inactive_and_pending_inactive) = get_deposit(&delegation.inactive);

        let inactivating_epoch = lockup_to_reward_epoch(pool_address, current_unlock_epoch + 1);
        let pending_rewards =
            compute_reward_over_interval(pool_address, current_epoch_balance, current_epoch, current_epoch + 1) +
            compute_reward_over_interval(pool_address, next_epoch_balance, current_epoch + 1, current_epoch(pool_address)) +
            compute_reward_over_interval(
                pool_address,
                inactive_and_pending_inactive - inactive, current_epoch,
                min(inactivating_epoch, current_epoch(pool_address)));


        increase_balance(&mut delegation.active, pending_rewards);
        increase_balance(&mut delegation.inactive, 0);
    }

    fun get_pool_balance(pool_address: address): u64 {
        let (active, inactive, pending_active, pending_inactive) = stake::get_stake(pool_address);
        active + inactive + pending_active + pending_inactive
    }

    fun get_pool_epoch_rewards(pool_address: address): u128 acquires DelegationPool {
        let pool = borrow_global<DelegationPool>(pool_address);
        ((get_pool_balance(pool_address) - pool.observable_pool_balance) as u128)
    }

    public entry fun end_epoch(pool_address: address) acquires DelegationPool {
        let acc_delegation = &borrow_global<DelegationPool>(pool_address).acc_delegation;
        let (_, active, _) = get_renewed_deposit(&acc_delegation.active);
        let (_, inactive, inactive_and_pending_inactive) = get_renewed_deposit(&acc_delegation.inactive);
        active = active + inactive_and_pending_inactive - inactive;

        if (!epoch_manager::attempt_advance_epoch(pool_address)) {
            return
        };

        let ratio_rewards_coins = if (active == 0) { 0 } else {
            (get_pool_epoch_rewards(pool_address) as u128) * APTOS_DENOMINATION / (active as u128)
        };

        let pool = borrow_global_mut<DelegationPool>(pool_address);
        let cumulative_rewards = *table::borrow(&pool.cumulative_rewards, current_epoch(pool_address) - 1);
        table::add(
            &mut pool.cumulative_rewards,
            current_epoch(pool_address),
            cumulative_rewards + ratio_rewards_coins
        );
        pool.observable_pool_balance = get_pool_balance(pool_address);
    }
}
