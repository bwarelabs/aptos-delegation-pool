
module bware_framework::deposits_adapter {

    use bware_framework::epoch_manager::current_epoch;

    struct DeferredDeposit has store, drop {
        current_epoch: u64,
        current_epoch_balance: u64,
        next_epoch_balance: u64,
    }

    public fun new(): DeferredDeposit {
        DeferredDeposit {
            current_epoch: current_epoch(),
            current_epoch_balance: 0,
            next_epoch_balance: 0,
        }
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
        let deposit_renewed = new();
        store_deposit(&mut deposit_renewed, deposit);
        let current_epoch_ = current_epoch();
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
