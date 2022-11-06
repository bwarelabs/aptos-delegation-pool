module bware_framework::epoch_manager {
    use std::error;
    use std::signer;
    
    use aptos_framework::account;
    use aptos_framework::event;
    use aptos_framework::reconfiguration::current_epoch as current_global_epoch;

    friend bware_framework::bware_dao_staking;

    struct NewInnerEpochEvent has drop, store {
        inner_epoch: u64,
        global_epoch: u64,
    }

    struct Configuration has key {
        inner_epoch: u64,
        global_epoch: u64,
        events: event::EventHandle<NewInnerEpochEvent>,
    }

    /// No global epoch has passed within current inner one
    const ENO_GLOBAL_EPOCH_PASSED: u64 = 1;

    public(friend) fun initialize(bware_framework: &signer) {
        move_to(bware_framework,
            Configuration {
                inner_epoch: 1, // would look to previous epoch and overflow
                global_epoch: current_global_epoch(),
                events: account::new_event_handle<NewInnerEpochEvent>(bware_framework),
            }
        );
        assert!(signer::address_of(bware_framework) == @bware_framework, 1);
    }

    public(friend) fun go_to_next_epoch() acquires Configuration {
        let config_ref = borrow_global_mut<Configuration>(@bware_framework);
        let global_epoch = current_global_epoch();

        assert!(global_epoch > config_ref.global_epoch, error::invalid_state(ENO_GLOBAL_EPOCH_PASSED));

        spec {
            assume config_ref.inner_epoch + 1 <= MAX_U64;
        };
        config_ref.global_epoch = global_epoch;
        config_ref.inner_epoch = config_ref.inner_epoch + 1;
        
        event::emit_event<NewInnerEpochEvent>(
            &mut config_ref.events,
            NewInnerEpochEvent {
                inner_epoch: config_ref.inner_epoch,
                global_epoch
            },
        );
    }

    public fun current_epoch(): u64 acquires Configuration {
        borrow_global<Configuration>(@bware_framework).inner_epoch
    }
}