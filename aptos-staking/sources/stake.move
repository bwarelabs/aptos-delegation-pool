module bware_framework::bware_dao_staking {
    use std::signer;
    use std::vector;
    use aptos_std::math64::min;

    use bware_framework::deposits_adapter::{
        Self,
        get_deposit, 
        get_renewed_deposit,
        get_actual_balance,
        increase_balance,
        increase_next_epoch_balance,
        decrease_balance,
        decrease_next_epoch_balance,
    };
    use bware_framework::epoch_manager::{Self, current_epoch};

    use aptos_framework::coin::{Self};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_std::table::{Self, Table};
    use aptos_framework::account;
    use aptos_framework::resource_account;
    use aptos_framework::stake::{Self};


    const APTOS_DENOMINATION: u128 = 100000000;
    
    const EINVALID_EPOCH_INTERVAL: u64 = 1;

    struct Delegation has key, store {
        /// currentEpochBalance is `active` while `nextEpochBalance` pending_active` stake
        active: deposits_adapter::DeferredDeposit,
        /// currentEpochBalance is `inactive` while `nextEpochBalance` pending_inactive` stake
        inactive: deposits_adapter::DeferredDeposit,
    }

    struct EpochStore has store {
        cumulative_reward: u128,
        coins_at_epoch_start: u64,
        coins_deposited: u64,
        coins_withdrawn: u64,
    }

    struct StakingStore has key, store {
        resource_signer_cap: account::SignerCapability,
        epochs: Table<u64, EpochStore>,
    }

    fun init_module(account: &signer, consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>) {
        let resource_signer_cap = resource_account::retrieve_resource_account_cap(account, @source_addr);
        let resource_signer = account::create_signer_with_capability(&resource_signer_cap);
        coin::register<AptosCoin>(&resource_signer);

        epoch_manager::initialize(account);

        stake::initialize_validator(&resource_signer,
        consensus_pubkey, proof_of_possession, vector::empty(), vector::empty());
        
        let epochs = table::new<u64, EpochStore>();
        table::add(&mut epochs, 1, EpochStore{
            cumulative_reward:0, coins_at_epoch_start:0, coins_deposited:0, coins_withdrawn:0
        });
        move_to(account, StakingStore {
            resource_signer_cap,
            epochs: epochs,
        });

        move_to(account, Delegation {
                active: deposits_adapter::new(),
                inactive: deposits_adapter::new(),
        });
    }
 
    public fun delegation_exists(addr: address): bool {
        exists<Delegation>(addr)
    }

    fun get_resource_signer(): signer acquires StakingStore {
        account::create_signer_with_capability(&borrow_global_mut<StakingStore>(@bware_framework).resource_signer_cap)
    }

    public fun add_stake(staker: &signer, amount: u64) acquires StakingStore, Delegation {
        let staker_address = signer::address_of(staker);
        let module_data = borrow_global_mut<StakingStore>(@bware_framework);
        
        let resource_signer = account::create_signer_with_capability(&module_data.resource_signer_cap);
        
        coin::transfer<AptosCoin>(staker, signer::address_of(&resource_signer), amount);
        
        stake::add_stake(&resource_signer, amount);
        
        if (!delegation_exists(staker_address)) {
            move_to(staker, Delegation {
                active: deposits_adapter::new(),
                inactive: deposits_adapter::new(),
            });
        };
        
        let alone_delegation = borrow_global_mut<Delegation>(staker_address);
        increase_next_epoch_balance(&mut alone_delegation.active, amount);
        
        alone_delegation = borrow_global_mut<Delegation>(@bware_framework);
        increase_next_epoch_balance(&mut alone_delegation.active, amount);
    }

    public fun reactivate_stake(staker: &signer, amount: u64) acquires StakingStore, Delegation {
        let dao_archive = borrow_global_mut<StakingStore>(@bware_framework);
        let staker_address = signer::address_of(staker);

        let resource_signer = account::create_signer_with_capability(&dao_archive.resource_signer_cap);

        stake::reactivate_stake(&resource_signer, amount);

        let delegation = borrow_global_mut<Delegation>(staker_address);
        amount = min(amount, get_actual_balance(&delegation.inactive));

        decrease_next_epoch_balance(&mut delegation.inactive, amount);
        increase_next_epoch_balance(&mut delegation.active, amount);
    }

    public fun unlock(staker: &signer, amount: u64) acquires StakingStore, Delegation {
        let dao_archive = borrow_global_mut<StakingStore>(@bware_framework);
        let staker_address = signer::address_of(staker);

        let resource_signer = account::create_signer_with_capability(&dao_archive.resource_signer_cap);

        stake::unlock(&resource_signer, amount);

        let delegation = borrow_global_mut<Delegation>(staker_address);
        //amount = min(amount, get_actual_balance(&delegation.active));

        decrease_next_epoch_balance(&mut delegation.active, amount);
        increase_next_epoch_balance(&mut delegation.inactive, amount);
    }

    fun compute_delegator_reward_over_interval(
        balance_over_interval: u64, 
        begin_epoch: u64,
        end_epoch: u64
    ): u64 acquires StakingStore {
        // skip computation when no rewards produced
        if (balance_over_interval == 0 || begin_epoch == end_epoch) {
            return 0
        };

        assert!(begin_epoch < end_epoch, EINVALID_EPOCH_INTERVAL);

        let staking_store = borrow_global<StakingStore>(@bware_framework);

        (((table::borrow(&staking_store.epochs, end_epoch).cumulative_reward - 
        table::borrow(&staking_store.epochs, begin_epoch).cumulative_reward) 
        * (balance_over_interval as u128) / APTOS_DENOMINATION) as u64)
    }

    public fun restake(staker: &signer) acquires StakingStore, Delegation {
        let delegation = borrow_global_mut<Delegation>(signer::address_of(staker));
        let (current_epoch, current_epoch_balance, next_epoch_balance) = get_deposit(&delegation.active);
        let pending_rewards = 
        compute_delegator_reward_over_interval(current_epoch_balance, current_epoch, current_epoch + 1) +
        compute_delegator_reward_over_interval(next_epoch_balance, current_epoch + 1, current_epoch());

        increase_balance(&mut delegation.active, pending_rewards);
    }

    public fun withdraw(staker: &signer, amount: u64) acquires StakingStore, Delegation {
                        let dao_archive = borrow_global_mut<StakingStore>(@bware_framework);
        let staker_address = signer::address_of(staker);

        let resource_signer = account::create_signer_with_capability(&dao_archive.resource_signer_cap);

        stake::withdraw(&resource_signer, amount);
        

        let delegation = borrow_global_mut<Delegation>(staker_address);
        amount = min(amount, get_actual_balance(&delegation.active));

        let dao_archive = borrow_global_mut<StakingStore>(@bware_framework);
        let epoch = table::borrow_mut(&mut dao_archive.epochs, current_epoch());
        epoch.coins_withdrawn = epoch.coins_withdrawn + amount;

        decrease_balance(&mut delegation.inactive, amount);

        coin::transfer<AptosCoin>(&resource_signer, staker_address, amount);
    }

    fun get_pool_balance(): u64 {
        let (active, inactive, pending_active, pending_inactive) = stake::get_stake(@bware_framework);
        active + inactive + pending_active + pending_inactive
    }

    fun get_previous_epoch_rewards(epoch: &EpochStore): u64 {
        get_pool_balance() - (epoch.coins_at_epoch_start + epoch.coins_deposited - epoch.coins_withdrawn)
    }

    public fun end_epoch() acquires StakingStore, Delegation {
        let staking_store = borrow_global_mut<StakingStore>(@bware_framework);
        let joint_delegation = borrow_global<Delegation>(@bware_framework);

        let (_, prev_active_balance, _) = get_renewed_deposit(&joint_delegation.active);
        let prev_epoch = table::borrow(&mut staking_store.epochs, current_epoch());

        epoch_manager::go_to_next_epoch();

        let current_cumulative_reward = if (prev_active_balance == 0) {
            0
        } else {
            (get_previous_epoch_rewards(prev_epoch) as u128) * APTOS_DENOMINATION / (prev_active_balance as u128)
        };
        table::add(&mut staking_store.epochs, current_epoch(), 
        EpochStore {
            cumulative_reward: prev_epoch.cumulative_reward + current_cumulative_reward,
            coins_at_epoch_start: get_pool_balance(),
            coins_deposited: 0,
            coins_withdrawn: 0,
        });

    }

    #[test_only]
    use aptos_framework::reconfiguration;

    #[test_only]
    use aptos_framework::timestamp;

    #[test_only]
    const CONSENSUS_KEY_1: vector<u8> = x"8a54b92288d4ba5073d3a52e80cc00ae9fbbc1cc5b433b46089b7804c38a76f00fc64746c7685ee628fc2d0b929c2294";
    #[test_only]
    const CONSENSUS_POP_1: vector<u8> = x"a9d6c1f1270f2d1454c89a83a4099f813a56dc7db55591d46aa4e6ccae7898b234029ba7052f18755e6fa5e6b73e235f14efc4e2eb402ca2b8f56bad69f965fc11b7b25eb1c95a06f83ddfd023eac4559b6582696cfea97b227f4ce5bdfdfed0";


    #[test_only]
    public fun set_up_test(origin_account: &signer, resource_account: &signer) {
        use std::vector;
        
        if (!account::exists_at(signer::address_of(origin_account))) {
            account::create_account_for_test(signer::address_of(origin_account));
        };
        
        // create a resource account from the origin account, mocking the module publishing process
        resource_account::create_resource_account(origin_account, vector::empty<u8>(), vector::empty<u8>());
        
        init_module(resource_account, CONSENSUS_KEY_1, CONSENSUS_POP_1);
    }
    


    #[test(
    origin_account = @0xcafe, 
    bware_framework = @0xc3bb8488ab1a5815a9d543d7e41b0e0df46a7396f89b22821f07a4362f75ddc5, 
    framework = @aptos_framework, 
    account1 = @0x111
    )]
    fun test_setup(origin_account: &signer, bware_framework: &signer, framework: &signer, account1: &signer) acquires Delegation, StakingStore  {
        stake::initialize_for_test(framework);
        account::create_account_for_test(@aptos_framework);
        reconfiguration::initialize_for_test(framework);

        stake::initialize_test_validator(origin_account, 1000, true, true);
        set_up_test(origin_account, bware_framework);

        let coins = stake::mint_coins(1000);
        account::create_account_for_test(signer::address_of(account1));
        coin::register<AptosCoin>(account1);
        coin::deposit<AptosCoin>(signer::address_of(account1), coins);
        add_stake(account1, 1000);
        unlock(account1,1000);
        //unlock(account1,1000);

        timestamp::fast_forward_seconds(100);
        reconfiguration::reconfigure_for_test_custom();
        end_epoch();
    }
    
}
