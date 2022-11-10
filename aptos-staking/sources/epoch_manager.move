module bware_framework::epoch_manager {
    use std::error;
    use std::signer;

    use aptos_std::table;

    use aptos_framework::account;
    use aptos_framework::event;
    use aptos_framework::reconfiguration::{current_epoch as current_aptos_epoch, last_reconfiguration_time};
    use aptos_framework::stake::get_lockup_secs;

    friend bware_framework::bware_dao_staking;

    struct NewEpochEvent has drop, store {
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
    const GENESIS_STAKING_EPOCH: u64 = 1;

    /// invalid module address at initialization
    const EINVALID_MODULE_RESOURCE_ACCOUNT: u64 = 1;
    /// No `aptos` epoch has passed within current `reward` epoch
    const ENO_APTOS_EPOCH_PASSED: u64 = 2;

    public(friend) fun initialize(bware_framework: &signer) {
        move_to<EpochsJournal>(
            bware_framework,
            EpochsJournal {
                reward_epoch: GENESIS_STAKING_EPOCH,
                lockup_epoch: GENESIS_STAKING_EPOCH,
                saved_aptos_epoch: current_aptos_epoch(),
                saved_locked_until_secs: 0,
                lockup_to_reward_epoch: table::new<u64, u64>(),
                events: account::new_event_handle<NewEpochEvent>(bware_framework),
            }
        );
        assert!(signer::address_of(bware_framework) == @bware_framework, 
        error::invalid_state(EINVALID_MODULE_RESOURCE_ACCOUNT));
    }

    public(friend) fun advance_epoch() acquires EpochsJournal {
        assert!(try_advance_epoch(), error::invalid_state(ENO_APTOS_EPOCH_PASSED));
    }

    public(friend) fun try_advance_epoch(): bool acquires EpochsJournal {
        let journal = borrow_global_mut<EpochsJournal>(@bware_framework);
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
            journal.saved_locked_until_secs = get_lockup_secs(@bware_framework);
            table::add(&mut journal.lockup_to_reward_epoch, journal.lockup_epoch, journal.reward_epoch);
        };

        event::emit_event<NewEpochEvent>(
            &mut journal.events,
            NewEpochEvent {
                reward_epoch: journal.reward_epoch,
                lockup_epoch: journal.lockup_epoch,
                saved_aptos_epoch,
                saved_locked_until_secs: journal.saved_locked_until_secs,
            },
        );
        true
    }

    public fun saved_locked_until_secs(): u64 acquires EpochsJournal {
        borrow_global<EpochsJournal>(@bware_framework).saved_locked_until_secs
    }

    public fun lockup_to_reward_epoch(lockup_epoch: u64): u64 acquires EpochsJournal {
        let journal = borrow_global<EpochsJournal>(@bware_framework);
        if (table::contains(&journal.lockup_to_reward_epoch, lockup_epoch)) {
            *table::borrow(&journal.lockup_to_reward_epoch, lockup_epoch)
        } else {
            0
        }
    }

    public fun current_epoch(epoch_type: bool): u64 acquires EpochsJournal {
        let journal = borrow_global<EpochsJournal>(@bware_framework);
        if (epoch_type) {journal.reward_epoch} else {journal.lockup_epoch}
    }

    public(friend) fun after_increase_lockup() acquires EpochsJournal {
        let journal = borrow_global_mut<EpochsJournal>(@bware_framework);
        // saved lockup time may not apply anymore for current `lockup` epoch as it has been extended
        // if already got to inactivate tokens, use it unchanged when advancing `lockup` epoch
        if (last_reconfiguration_time() / MICRO_CONVERSION_FACTOR < journal.saved_locked_until_secs) {
            journal.saved_locked_until_secs = get_lockup_secs(@bware_framework);
        }
    }
}