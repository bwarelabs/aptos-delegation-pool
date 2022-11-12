
module bwarelabs::deposits_adapter {

    use bwarelabs::epoch_manager;

    struct DeferredDeposit has store, drop {
        current_epoch: u64,
        current_epoch_balance: u64,
        next_epoch_balance: u64,
        renewed_on_lockup_epoch: bool,
        pool_address: address,
    }

    public fun new(pool_address: address, renewed_on_lockup_epoch: bool): DeferredDeposit {
        DeferredDeposit {
            renewed_on_lockup_epoch,
            current_epoch: current_epoch(pool_address, renewed_on_lockup_epoch),
            current_epoch_balance: 0,
            next_epoch_balance: 0,
            pool_address,
        }
    }

    fun current_epoch(pool_address: address, renewed_on_lockup_epoch: bool): u64 {
        if (renewed_on_lockup_epoch) epoch_manager::current_lockup_epoch(pool_address) else epoch_manager::current_epoch(pool_address)
    }

    public fun get_deposit(deposit: &DeferredDeposit): (u64, u64, u64) {
        (deposit.current_epoch, deposit.current_epoch_balance, deposit.next_epoch_balance)
    }

    public fun get_renewed_deposit(deposit: &DeferredDeposit): (u64, u64, u64) {
        get_deposit(&load_deposit(deposit))
    }

    public fun get_actual_balance(deposit: &DeferredDeposit): u64 {
        deposit.next_epoch_balance
    }

    fun load_deposit(deposit: &DeferredDeposit): DeferredDeposit  {
        let deposit_renewed = new(deposit.pool_address, deposit.renewed_on_lockup_epoch);
        store_deposit(&mut deposit_renewed, deposit);
        let current_epoch_ = current_epoch(deposit.pool_address, deposit.renewed_on_lockup_epoch);
        if (current_epoch_ > deposit.current_epoch) {
            deposit_renewed.current_epoch_balance = deposit.next_epoch_balance;
            deposit_renewed.current_epoch = current_epoch_;
        };
        deposit_renewed
    }

    fun store_deposit(depositTo: &mut DeferredDeposit, depositFrom: &DeferredDeposit) {
        depositTo.current_epoch = depositFrom.current_epoch;
        depositTo.current_epoch_balance = depositFrom.current_epoch_balance;
        depositTo.next_epoch_balance = depositFrom.next_epoch_balance;
    }

    public fun increase_balance(deposit: &mut DeferredDeposit, amount: u64) {
        let deposit_renewed = load_deposit(deposit);
        spec {
            assume deposit_renewed.current_epoch_balance + amount <= MAX_U64;
            assume deposit_renewed.next_epoch_balance + amount <= MAX_U64;
        };
        deposit_renewed.current_epoch_balance = deposit_renewed.current_epoch_balance + amount;
        deposit_renewed.next_epoch_balance = deposit_renewed.next_epoch_balance + amount;
        store_deposit(deposit, &deposit_renewed);
    }

    public fun decrease_balance(deposit: &mut DeferredDeposit, amount: u64) {
        let deposit_renewed = load_deposit(deposit);
        spec {
            assume deposit_renewed.current_epoch_balance >= amount;
            assume deposit_renewed.next_epoch_balance >= amount;
        };
        assert!(deposit_renewed.current_epoch_balance >= amount, 1);
        deposit_renewed.current_epoch_balance = deposit_renewed.current_epoch_balance - amount;
        deposit_renewed.next_epoch_balance = deposit_renewed.next_epoch_balance - amount;
        store_deposit(deposit, &deposit_renewed);
    }

    public fun increase_next_epoch_balance(deposit: &mut DeferredDeposit, amount: u64) {
        let deposit_renewed = load_deposit(deposit);
        spec {
            assume deposit_renewed.next_epoch_balance + amount <= MAX_U64;
        };
        deposit_renewed.next_epoch_balance = deposit_renewed.next_epoch_balance + amount;
        store_deposit(deposit, &deposit_renewed);
    }

    public fun decrease_next_epoch_balance(deposit: &mut DeferredDeposit, amount: u64) {
        let deposit_renewed = load_deposit(deposit);
        spec {
            assume deposit_renewed.next_epoch_balance >= amount;
        };
        assert!(deposit_renewed.next_epoch_balance >= amount, 1);
        deposit_renewed.next_epoch_balance = deposit_renewed.next_epoch_balance - amount;
        store_deposit(deposit, &deposit_renewed);
    }
}
