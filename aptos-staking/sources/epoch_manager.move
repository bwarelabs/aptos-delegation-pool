module bware_framework::epoch_manager {
    use std::error;
    use std::signer;

    use aptos_std::table;

    use aptos_framework::account;
    use aptos_framework::event;
    use aptos_framework::reconfiguration::{current_epoch as current_global_epoch, last_reconfiguration_time};
    use aptos_framework::stake::get_lockup_secs;

    friend bware_framework::bware_dao_staking;

    struct NewEpochEvent has drop, store {
        reward_epoch: u64,
        global_epoch: u64,
        lockup_epoch: u64,
        locked_until_secs: u64,
    }

    struct Configuration has key {
        reward_epoch: u64,
        global_epoch: u64,
        lockup_epoch: u64,
        locked_until_secs: u64,
        lockup_to_reward_epoch: table::Table<u64, u64>,
        events: event::EventHandle<NewEpochEvent>,
    }

    /// No global epoch has passed within current inner one
    const ENO_GLOBAL_EPOCH_PASSED: u64 = 1;

    public(friend) fun initialize(bware_framework: &signer) {
        move_to(bware_framework,
            Configuration {
                reward_epoch: 1, // would look to previous epoch and overflow
                lockup_epoch: 1,
                global_epoch: current_global_epoch(),
                lockup_to_reward_epoch: table::new<u64, u64>(),
                events: account::new_event_handle<NewEpochEvent>(bware_framework),
                locked_until_secs: 0,
            }
        );
        assert!(signer::address_of(bware_framework) == @bware_framework, 1);
    }

    public(friend) fun go_to_next_epoch() acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@bware_framework);
        let global_epoch = current_global_epoch();

        assert!(global_epoch > config_ref.global_epoch, error::invalid_state(ENO_GLOBAL_EPOCH_PASSED));

        spec {
            assume config_ref.reward_epoch + 1 <= MAX_U64;
        };
        config_ref.global_epoch = global_epoch;
        config_ref.reward_epoch = config_ref.reward_epoch + 1;

        if (last_reconfiguration_time() >= config_ref.locked_until_secs) {
            config_ref.lockup_epoch = config_ref.lockup_epoch + 1;
            config_ref.locked_until_secs = get_lockup_secs(@bware_framework);
            table::add(&mut config_ref.lockup_to_reward_epoch, config_ref.lockup_epoch, config_ref.reward_epoch);
        };

        event::emit_event<NewEpochEvent>(
            &mut config_ref.events,
            NewEpochEvent {
                reward_epoch: config_ref.reward_epoch,
                global_epoch,
                lockup_epoch: config_ref.lockup_epoch,
                locked_until_secs: config_ref.locked_until_secs,
            },
        );
    }

    public(friend) fun increase_lockup() acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@bware_framework);
        if (last_reconfiguration_time() < config_ref.locked_until_secs) {
            config_ref.locked_until_secs = get_lockup_secs(@bware_framework);
        }
    }

    public fun lockup_to_reward_epoch(lockup_epoch: u64): u64 acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@bware_framework);
        if (table::contains(&config_ref.lockup_to_reward_epoch, lockup_epoch)) {
            *table::borrow(&config_ref.lockup_to_reward_epoch, lockup_epoch)
        } else {
            0
        }    
    }

    public fun current_epoch(epoch_type: bool): u64 acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@bware_framework);
        if (epoch_type) {config_ref.reward_epoch} else {config_ref.lockup_epoch}
    }
}