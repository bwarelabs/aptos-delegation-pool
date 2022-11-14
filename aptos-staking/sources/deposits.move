module bwarelabs::deposits_adapter {
    use std::error;

    use bwarelabs::epoch_manager;

    /// Assert codes for unexpected subtraction overflow on decreasing a deposit's balances
    const ENOT_ENOUGH_BALANCE: u64 = 1;
    const ENOT_ENOUGH_NEXT_BALANCE: u64 = 2;

    struct DeferredDeposit has store, copy {
        current_epoch: u64,
        current_epoch_balance: u64,
        next_epoch_balance: u64,
        renewed_on_lockup_epoch: bool,
        pool_address: address,
    }

    public fun new(pool_address: address, renewed_on_lockup_epoch: bool): DeferredDeposit {
        DeferredDeposit {
            current_epoch: current_epoch(pool_address, renewed_on_lockup_epoch),
            current_epoch_balance: 0,
            next_epoch_balance: 0,
            renewed_on_lockup_epoch,
            pool_address,
        }
    }

    fun current_epoch(pool_address: address, renewed_on_lockup_epoch: bool): u64 {
        if (renewed_on_lockup_epoch)
            epoch_manager::current_lockup_epoch(pool_address)
        else
            epoch_manager::current_epoch(pool_address)
    }

    public fun get_deposit(deposit: &DeferredDeposit): (u64, u64, u64) {
        (deposit.current_epoch, deposit.current_epoch_balance, deposit.next_epoch_balance)
    }

    public fun get_renewed_deposit(deposit: &DeferredDeposit): (u64, u64, u64) {
        let deposit = *deposit;
        renew_deposit(&mut deposit);
        let DeferredDeposit {
            current_epoch, current_epoch_balance, next_epoch_balance,
            renewed_on_lockup_epoch: _, pool_address: _,
        } = deposit;
        (current_epoch, current_epoch_balance, next_epoch_balance)
    }

    fun renew_deposit(deposit: &mut DeferredDeposit) {
        let current_epoch = current_epoch(deposit.pool_address, deposit.renewed_on_lockup_epoch);
        if (current_epoch > deposit.current_epoch) {
            deposit.current_epoch_balance = deposit.next_epoch_balance;
            deposit.current_epoch = current_epoch;
        };
    }

    fun increase_balance_single(deposit: &mut DeferredDeposit, amount: u64) {
        renew_deposit(deposit);
        spec {
            assume deposit.current_epoch_balance + amount <= MAX_U64;
            assume deposit.next_epoch_balance + amount <= MAX_U64;
        };
        deposit.current_epoch_balance = deposit.current_epoch_balance + amount;
        deposit.next_epoch_balance = deposit.next_epoch_balance + amount;
    }

    fun decrease_balance_single(deposit: &mut DeferredDeposit, amount: u64) {
        renew_deposit(deposit);
        spec {
            assume deposit.current_epoch_balance >= amount;
            assume deposit.next_epoch_balance >= amount;
        };
        assert!(deposit.current_epoch_balance >= amount, error::invalid_state(ENOT_ENOUGH_BALANCE));
        assert!(deposit.next_epoch_balance >= amount, error::invalid_state(ENOT_ENOUGH_NEXT_BALANCE));
        deposit.current_epoch_balance = deposit.current_epoch_balance - amount;
        deposit.next_epoch_balance = deposit.next_epoch_balance - amount;
    }

    fun increase_next_epoch_balance_single(deposit: &mut DeferredDeposit, amount: u64) {
        renew_deposit(deposit);
        spec {
            assume deposit.next_epoch_balance + amount <= MAX_U64;
        };
        deposit.next_epoch_balance = deposit.next_epoch_balance + amount;
    }

    fun decrease_next_epoch_balance_single(deposit: &mut DeferredDeposit, amount: u64) {
        renew_deposit(deposit);
        spec {
            assume deposit.next_epoch_balance >= amount;
        };
        assert!(deposit.next_epoch_balance >= amount, error::invalid_state(ENOT_ENOUGH_NEXT_BALANCE));
        deposit.next_epoch_balance = deposit.next_epoch_balance - amount;
    }

    public fun increase_balance(deposit: &mut DeferredDeposit, acc_deposit: &mut DeferredDeposit, amount: u64) {
        increase_balance_single(deposit, amount);
        increase_balance_single(acc_deposit, amount);
    }

    public fun decrease_balance(deposit: &mut DeferredDeposit, acc_deposit: &mut DeferredDeposit, amount: u64) {
        decrease_balance_single(deposit, amount);
        decrease_balance_single(acc_deposit, amount);
    }

    public fun increase_next_epoch_balance(deposit: &mut DeferredDeposit, acc_deposit: &mut DeferredDeposit, amount: u64) {
        increase_next_epoch_balance_single(deposit, amount);
        increase_next_epoch_balance_single(acc_deposit, amount);
    }

    public fun decrease_next_epoch_balance(deposit: &mut DeferredDeposit, acc_deposit: &mut DeferredDeposit, amount: u64) {
        decrease_next_epoch_balance_single(deposit, amount);
        decrease_next_epoch_balance_single(acc_deposit, amount);
    }
}
