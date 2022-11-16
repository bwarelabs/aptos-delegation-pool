module bwarelabs::epoch_manager {
    use std::signer;

    use aptos_std::table::{Self, Table};

    use aptos_framework::account;
    use aptos_framework::event;
    use aptos_framework::reconfiguration::{current_epoch as last_aptos_epoch, last_reconfiguration_time};
    use aptos_framework::stake::get_lockup_secs;

    friend bwarelabs::delegation_pool;

    struct NewRewardEpochEvent has drop, store {
        reward_epoch: u64,
        last_aptos_epoch: u64,
    }

    struct NewLockupEpochEvent has drop, store {
        lockup_epoch: u64,
        last_locked_until_secs: u64,
    }

    struct EpochsJournal has key {
        reward_epoch: u64,
        lockup_epoch: u64,
        lockup_to_reward_epoch: Table<u64, u64>,
        last_aptos_epoch: u64,
        last_locked_until_secs: u64,
        new_reward_epoch_events: event::EventHandle<NewRewardEpochEvent>,
        new_lockup_epoch_events: event::EventHandle<NewLockupEpochEvent>,
    }

    /// Conversion factor between seconds and microseconds
    const MICRO_CONVERSION_FACTOR: u64 = 1000000;

    public(friend) fun initialize_epoch_manager(stake_pool_signer: &signer) {
        move_to<EpochsJournal>(
            stake_pool_signer,
            EpochsJournal {
                reward_epoch: 1,
                lockup_epoch: 1,
                lockup_to_reward_epoch: table::new<u64, u64>(),
                last_aptos_epoch: last_aptos_epoch(),
                // address of stake pool == owner of stake pool (not delegation pool) == `stake_pool_signer` address
                last_locked_until_secs: get_lockup_secs(signer::address_of(stake_pool_signer)),
                new_reward_epoch_events: account::new_event_handle<NewRewardEpochEvent>(stake_pool_signer),
                new_lockup_epoch_events: account::new_event_handle<NewLockupEpochEvent>(stake_pool_signer),
            }
        );
    }

    public(friend) fun advance_epoch(pool_address: address): bool acquires EpochsJournal {
        let journal = borrow_global_mut<EpochsJournal>(pool_address);
        let last_aptos_epoch = last_aptos_epoch();
        if (last_aptos_epoch <= journal.last_aptos_epoch) {
            return false
        };

        spec {
            assume journal.reward_epoch + 1 <= MAX_U64;
        };
        journal.reward_epoch = journal.reward_epoch + 1;
        journal.last_aptos_epoch = last_aptos_epoch;

        event::emit_event<NewRewardEpochEvent>(
            &mut journal.new_reward_epoch_events,
            NewRewardEpochEvent {
                reward_epoch: journal.reward_epoch,
                last_aptos_epoch,
            },
        );

        if (last_reconfiguration_time() / MICRO_CONVERSION_FACTOR >= journal.last_locked_until_secs) {
            spec {
                assume journal.lockup_epoch + 1 <= MAX_U64;
            };
            journal.lockup_epoch = journal.lockup_epoch + 1;
            journal.last_locked_until_secs = get_lockup_secs(pool_address);
            table::add(&mut journal.lockup_to_reward_epoch, journal.lockup_epoch, journal.reward_epoch);

            event::emit_event<NewLockupEpochEvent>(
                &mut journal.new_lockup_epoch_events,
                NewLockupEpochEvent {
                    lockup_epoch: journal.lockup_epoch,
                    last_locked_until_secs: journal.last_locked_until_secs,
                },
            );
        };
        true
    }

    public fun lockup_to_reward_epoch(pool_address: address, lockup_epoch: u64): (u64, bool) acquires EpochsJournal {
        let lockup_to_reward_epoch = &borrow_global<EpochsJournal>(pool_address).lockup_to_reward_epoch;
        if (table::contains(lockup_to_reward_epoch, lockup_epoch)) {
            (*table::borrow(lockup_to_reward_epoch, lockup_epoch), true)
        } else {
            // requested unlock epoch for pool never passed
            (0, false)
        }
    }

    public fun current_epoch(pool_address: address): u64 acquires EpochsJournal {
        borrow_global<EpochsJournal>(pool_address).reward_epoch
    }

    public fun current_lockup_epoch(pool_address: address): u64 acquires EpochsJournal {
        borrow_global<EpochsJournal>(pool_address).lockup_epoch
    }

    public(friend) fun after_increase_lockup(pool_address: address) acquires EpochsJournal {
        let last_locked_until_secs = &mut borrow_global_mut<EpochsJournal>(pool_address).last_locked_until_secs;
        // last lockup end-time may not apply anymore for current `lockup_epoch` as it has just been extended
        // if it already got to inactivate stake (an aptos epoch exceeded it), use it as-is for current `lockup_epoch`
        if (last_reconfiguration_time() / MICRO_CONVERSION_FACTOR < *last_locked_until_secs) {
            *last_locked_until_secs = get_lockup_secs(pool_address);
        }
    }
}
