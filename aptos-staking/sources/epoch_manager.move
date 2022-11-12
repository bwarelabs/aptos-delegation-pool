module bwarelabs::epoch_manager {
    use aptos_std::table;
    use aptos_std::signer;

    use aptos_framework::account;
    use aptos_framework::event;
    use aptos_framework::reconfiguration::{current_epoch as current_aptos_epoch, last_reconfiguration_time};
    use aptos_framework::stake::get_lockup_secs;

    friend bwarelabs::delegation_pool;

    struct NewEpochEvent has drop, store {
        pool_address: address,
        reward_epoch: u64,
        lockup_epoch: u64,
        saved_aptos_epoch: u64,
        saved_locked_until_secs: u64,
    }

    struct EpochsJournal has key, store {
        reward_epoch: u64,
        lockup_epoch: u64,
        saved_aptos_epoch: u64,
        saved_locked_until_secs: u64,
        lockup_to_reward_epoch: table::Table<u64, u64>,
        events: event::EventHandle<NewEpochEvent>,
    }

    /// Conversion factor between seconds and microseconds
    const MICRO_CONVERSION_FACTOR: u64 = 1000000;

    /// Starting index for the rewards and unlock epochs
    const POOL_GENESIS_EPOCH: u64 = 1;

    public(friend) fun initialize_epoch_manager(stake_pool_owner: &signer) {
        move_to<EpochsJournal>(
            stake_pool_owner,
            EpochsJournal {
                reward_epoch: POOL_GENESIS_EPOCH,
                lockup_epoch: POOL_GENESIS_EPOCH,
                saved_aptos_epoch: current_aptos_epoch(),
                // stake pool address == address of owner of stake pool (not delegation one)
                saved_locked_until_secs: get_lockup_secs(signer::address_of(stake_pool_owner)),
                lockup_to_reward_epoch: table::new<u64, u64>(),
                events: account::new_event_handle<NewEpochEvent>(stake_pool_owner),
            }
        );
    }

    public(friend) fun attempt_advance_epoch(pool_address: address): bool acquires EpochsJournal {
        let journal = borrow_global_mut<EpochsJournal>(pool_address);
        let saved_aptos_epoch = current_aptos_epoch();
        if (saved_aptos_epoch <= journal.saved_aptos_epoch) {
            return false
        };

        spec {
            assume journal.reward_epoch + 1 <= MAX_U64;
        };
        journal.reward_epoch = journal.reward_epoch + 1;
        journal.saved_aptos_epoch = saved_aptos_epoch;

        if (last_reconfiguration_time() / MICRO_CONVERSION_FACTOR >= journal.saved_locked_until_secs) {
            spec {
                assume journal.lockup_epoch + 1 <= MAX_U64;
            };
            journal.lockup_epoch = journal.lockup_epoch + 1;
            journal.saved_locked_until_secs = get_lockup_secs(pool_address);
            table::add(&mut journal.lockup_to_reward_epoch, journal.lockup_epoch, journal.reward_epoch);
        };

        event::emit_event<NewEpochEvent>(
            &mut journal.events,
            NewEpochEvent {
                pool_address,
                reward_epoch: journal.reward_epoch,
                lockup_epoch: journal.lockup_epoch,
                saved_aptos_epoch,
                saved_locked_until_secs: journal.saved_locked_until_secs,
            },
        );
        true
    }

    public fun lockup_to_reward_epoch(pool_address: address, lockup_epoch: u64): u64 acquires EpochsJournal {
        let journal = borrow_global<EpochsJournal>(pool_address);
        if (table::contains(&journal.lockup_to_reward_epoch, lockup_epoch)) {
            *table::borrow(&journal.lockup_to_reward_epoch, lockup_epoch)
        } else {
            0
        }
    }

    public fun current_epoch(pool_address: address): u64 acquires EpochsJournal {
        borrow_global<EpochsJournal>(pool_address).reward_epoch
    }

    public fun current_lockup_epoch(pool_address: address): u64 acquires EpochsJournal {
        borrow_global<EpochsJournal>(pool_address).lockup_epoch
    }

    public(friend) fun after_increase_lockup(pool_address: address) acquires EpochsJournal {
        let journal = borrow_global_mut<EpochsJournal>(pool_address);
        // saved lockup time may not apply anymore for current `lockup` epoch as it has been extended
        // if already got to inactivate tokens, use it unchanged when advancing `lockup` epoch
        if (last_reconfiguration_time() / MICRO_CONVERSION_FACTOR < journal.saved_locked_until_secs) {
            journal.saved_locked_until_secs = get_lockup_secs(pool_address);
        }
    }
}