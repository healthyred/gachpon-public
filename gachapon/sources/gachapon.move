module gachapon::gachapon;

use gachapon::big_vector::{Self as bv, BigVector};
use kiosk::personal_kiosk;
use std::{ascii::String, type_name::{Self, TypeName}};
use sui::{
    bag::{Self, Bag},
    balance::{Self, Balance},
    coin::{Self, Coin},
    dynamic_field as df,
    event::emit,
    kiosk::{Self, Kiosk, KioskOwnerCap},
    package,
    random::Random,
    sui::SUI,
    transfer_policy::{TransferPolicy, TransferRequest},
    vec_set::{Self, VecSet}
};

// Dependencies

// Constants

const SLICE_SIZE: u64 = 1_000;

public fun slice_size(): u64 { SLICE_SIZE }

// Errors

const EInvalidKeeper: u64 = 0;

fun err_invalid_keeper() { abort EInvalidKeeper }

const EInvalidKiosk: u64 = 1;

fun err_invalid_kiosk() { abort EInvalidKiosk }

const EPaymentNotEnough: u64 = 2;

fun err_payment_not_enough() { abort EPaymentNotEnough }

const EDestroyNonEmptyEgg: u64 = 3;

fun err_destroy_non_empty_egg() { abort EDestroyNonEmptyEgg }

const ERedeemEmptyEgg: u64 = 4;

fun err_redeem_empty_egg() { abort ERedeemEmptyEgg }

const EEggContentIsLocked: u64 = 5;

fun err_egg_content_is_locked() { abort EEggContentIsLocked }

const EEggContentIsUnlocked: u64 = 6;

fun err_egg_content_is_unlocked() { abort EEggContentIsUnlocked }

const ECloseNonEmptyGachapon: u64 = 7;

fun err_delete_non_empty_gachapon() { abort ECloseNonEmptyGachapon }

const EInvalidSupplier: u64 = 8;

fun err_invalid_supplier() { abort EInvalidSupplier }

const ESupplierNotExists: u64 = 9;

fun err_supplier_not_exists() { abort ESupplierNotExists }

const EEggSupplyNotEnough: u64 = 10;

fun err_egg_supply_not_enough() { abort EEggSupplyNotEnough }

const EObjTypeNotSupported: u64 = 12;

fun err_object_type_not_supported() { abort EObjTypeNotSupported }

const ENotOwner: u64 = 13;

fun err_not_owner() { abort ENotOwner }

// Objects

public struct GACHAPON has drop {}

public struct EggContent has copy, drop, store {
    obj_id: ID,
    is_locked: bool,
}

public struct Egg has key, store {
    id: UID,
    content: Option<EggContent>,
}

public struct Gachapon<phantom T> has key {
    id: UID,
    lootbox: BigVector<Egg>,
    treasury: Balance<T>,
    cost: u64,
    kiosk_cap: KioskOwnerCap,
    kiosk_id: ID,
    suppliers: VecSet<address>,
}

public struct FreeSpinsTracker has key, store {
    id: UID,
    current_epoch: u64,
    allowed_nfts: VecSet<TypeName>,
    used_nft: VecSet<ID>,
}

public struct Tracker has copy, drop, store {}

public struct SpecialTracker has copy, drop, store {
    epoch: u64,
}

public struct BagTracker has key, store {
    id: UID,
    bag: Bag,
    ids: vector<ID>,
}

public struct KeeperCap has key, store {
    id: UID,
    gachapon_id: ID,
}

public struct SecondaryCurrencyStore<phantom T> has store {
    cost: u64,
    secondary_currency: Balance<T>,
}

public struct RewardTier has copy, drop, store {
    count: u64,
    reward: u64,
}

// Constructor

fun init(otw: GACHAPON, ctx: &mut TxContext) {
    package::claim_and_keep(otw, ctx);
}

// Public Funs

#[allow(lint(share_owned))]
public fun create<T>(cost: u64, init_supplier: address, ctx: &mut TxContext): KeeperCap {
    let (kiosk, kiosk_cap) = kiosk::new(ctx);
    let kiosk_id = object::id(&kiosk);
    let gachapon = Gachapon<T> {
        id: object::new(ctx),
        lootbox: bv::new(slice_size(), ctx),
        treasury: balance::zero(),
        cost,
        kiosk_cap,
        kiosk_id,
        suppliers: vec_set::singleton(init_supplier),
    };
    let gachapon_id = object::id(&gachapon);
    let keeper_cap = KeeperCap {
        id: object::new(ctx),
        gachapon_id,
    };
    emit(NewGachapon {
        coin_type: type_name::get<T>().into_string(),
        gachapon_id,
        cap_id: object::id(&keeper_cap),
        kiosk_id,
    });
    transfer::share_object(gachapon);
    transfer::public_share_object(kiosk);
    keeper_cap
}

public fun close<T>(
    gachapon: Gachapon<T>,
    cap: KeeperCap,
    kiosk: Kiosk,
    ctx: &mut TxContext,
): (Coin<T>, Coin<SUI>) {
    gachapon.assert_valid_keeper(&cap);
    gachapon.assert_valid_kiosk(&kiosk);
    emit(CloseGachapon {
        coin_type: type_name::get<T>().into_string(),
        gachapon_id: object::id(&gachapon),
        cap_id: object::id(&cap),
        kiosk_id: object::id(&kiosk),
    });
    let KeeperCap { id, gachapon_id: _ } = cap;
    id.delete();
    let Gachapon<T> {
        id,
        lootbox,
        treasury,
        cost: _,
        kiosk_cap,
        kiosk_id: _,
        suppliers: _,
    } = gachapon;
    id.delete();

    if (!lootbox.is_empty()) {
        err_delete_non_empty_gachapon();
    };
    lootbox.destroy_empty();

    (coin::from_balance(treasury, ctx), kiosk.close_and_withdraw(kiosk_cap, ctx))
}

// Keeper Funs

public fun place<T, Obj: key + store>(
    gachapon: &mut Gachapon<T>,
    kiosk: &mut Kiosk,
    obj: Obj,
    ctx: &mut TxContext,
) {
    gachapon.assert_valid_supplier(ctx);
    gachapon.assert_valid_kiosk(kiosk);
    let is_locked = false;
    let (egg, obj_id) = new_egg(&obj, is_locked, ctx);
    let egg_id = object::id(&egg);
    gachapon.lootbox.push_back(egg);
    kiosk.place(&gachapon.kiosk_cap, obj);
    emit(ObjectIn<Obj> {
        gachapon_id: object::id(gachapon),
        kiosk_id: object::id(kiosk),
        obj_id,
        egg_id,
        is_locked,
    });
}

public fun lock<T, Obj: key + store>(
    gachapon: &mut Gachapon<T>,
    kiosk: &mut Kiosk,
    transfer_policy: &TransferPolicy<Obj>,
    obj: Obj,
    ctx: &mut TxContext,
) {
    gachapon.assert_valid_supplier(ctx);
    gachapon.assert_valid_kiosk(kiosk);
    let is_locked = true;
    let (egg, obj_id) = new_egg(&obj, is_locked, ctx);
    let egg_id = object::id(&egg);
    gachapon.lootbox.push_back(egg);
    kiosk.lock(&gachapon.kiosk_cap, transfer_policy, obj);
    emit(ObjectIn<Obj> {
        gachapon_id: object::id(gachapon),
        kiosk_id: object::id(kiosk),
        obj_id,
        egg_id,
        is_locked,
    });
}

public fun take<T>(
    gachapon: &mut Gachapon<T>,
    kiosk: &mut Kiosk,
    cap: &KeeperCap,
    index: u64,
): Egg {
    gachapon.assert_valid_keeper(cap);
    gachapon.assert_valid_kiosk(kiosk);
    let egg = gachapon.lootbox.swap_remove(index);
    emit(EggOut {
        gachapon_id: object::id(gachapon),
        egg_id: object::id(&egg),
        egg_idx: option::none(),
    });
    egg
}

public fun stuff<T>(gachapon: &mut Gachapon<T>, cap: &KeeperCap, count: u64, ctx: &mut TxContext) {
    gachapon.assert_valid_keeper(cap);
    std::u64::do!(count, |_| {
        let egg = new_empty_egg(ctx);
        gachapon.lootbox.push_back(egg);
    });
    emit(StuffGachapon {
        gachapon_id: object::id(gachapon),
        count,
    });
}

public fun claim<T>(gachapon: &mut Gachapon<T>, cap: &KeeperCap, ctx: &mut TxContext): Coin<T> {
    gachapon.assert_valid_keeper(cap);
    coin::from_balance(gachapon.treasury.withdraw_all(), ctx)
}

public fun update_cost<T>(gachapon: &mut Gachapon<T>, cap: &KeeperCap, new_cost: u64) {
    gachapon.assert_valid_keeper(cap);
    gachapon.cost = new_cost;
}

public fun add_supplier<T>(gachapon: &mut Gachapon<T>, cap: &KeeperCap, supplier: address) {
    gachapon.assert_valid_keeper(cap);
    gachapon.suppliers.insert(supplier);
}

public fun remove_supplier<T>(gachapon: &mut Gachapon<T>, cap: &KeeperCap, supplier: address) {
    gachapon.assert_valid_keeper(cap);
    if (!gachapon.suppliers.contains(&supplier)) {
        err_supplier_not_exists();
    };
    gachapon.suppliers.remove(&supplier);
}

#[allow(unused)]
public fun add_secondary_currency<T>(gachapon: &mut Gachapon<T>, cap: &KeeperCap, cost: u64) {
    abort 0
}

public fun add_secondary_currency_fixed<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    cost: u64,
) {
    gachapon.assert_valid_keeper(cap);
    df::add<u64, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        0,
        SecondaryCurrencyStore<SecondaryCurrency> {
            secondary_currency: balance::zero(),
            cost,
        },
    );
}

#[allow(unused)]
public fun remove_secondary_currency<T>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    ctx: &mut TxContext,
): Coin<T> {
    abort 0
}

public fun remove_secondary_currency_fixed<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    ctx: &mut TxContext,
): Coin<SecondaryCurrency> {
    gachapon.assert_valid_keeper(cap);
    let vault = df::remove<u64, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        0,
    );

    let SecondaryCurrencyStore<SecondaryCurrency> { secondary_currency, .. } = vault;
    secondary_currency.into_coin(ctx)
}

#[allow(unused)]
public fun withdraw_secondary_currency<T>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    ctx: &mut TxContext,
): Coin<T> {
    abort 0
}

public fun withdraw_secondary_currency_fixed<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    ctx: &mut TxContext,
): Coin<SecondaryCurrency> {
    gachapon.assert_valid_keeper(cap);
    let vault = df::borrow_mut<u64, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        0,
    );

    let value = vault.secondary_currency.value();

    vault.secondary_currency.split(value).into_coin(ctx)
}

public fun set_secondary_currency_cost<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    cost: u64,
) {
    gachapon.assert_valid_keeper(cap);
    df::borrow_mut<u64, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        0,
    ).cost = cost;
}

public fun add_reward_for_count<T>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    count: u64,
    reward: u64,
) {
    gachapon.assert_valid_keeper(cap);

    if (!df::exists_<u64>(&gachapon.id, 1)) {
        df::add<u64, VecSet<RewardTier>>(
            &mut gachapon.id,
            1,
            vec_set::empty<RewardTier>(),
        );
    };

    let vec_set = df::borrow_mut<u64, VecSet<RewardTier>>(&mut gachapon.id, 1);

    vec_set.insert(RewardTier {
        count,
        reward,
    });
}

public fun remove_reward_for_count<T>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    count: u64,
    reward: u64,
) {
    gachapon.assert_valid_keeper(cap);

    let vec_set = df::borrow_mut<u64, VecSet<RewardTier>>(&mut gachapon.id, 1);

    vec_set.remove(
        &RewardTier {
            count,
            reward,
        },
    );
}

// Secondary Currency Funs

public fun add_secondary_currency_explicit<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    cost: u64,
) {
    gachapon.assert_valid_keeper(cap);

    df::add<TypeName, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        type_name::get<SecondaryCurrency>(),
        SecondaryCurrencyStore<SecondaryCurrency> {
            secondary_currency: balance::zero(),
            cost,
        },
    )
}

public fun remove_secondary_currency_explicit<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    ctx: &mut TxContext,
): Coin<SecondaryCurrency> {
    gachapon.assert_valid_keeper(cap);

    let store = df::remove<TypeName, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        type_name::get<SecondaryCurrency>(),
    );

    let SecondaryCurrencyStore<SecondaryCurrency> { secondary_currency, .. } = store;

    secondary_currency.into_coin(ctx)
}

public fun withdraw_secondary_currency_explicit<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    ctx: &mut TxContext,
): Coin<SecondaryCurrency> {
    gachapon.assert_valid_keeper(cap);

    let store = df::borrow_mut<TypeName, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        type_name::get<SecondaryCurrency>(),
    );

    let value = store.secondary_currency.value();

    store.secondary_currency.split(value).into_coin(ctx)
}

public fun set_secondary_currency_cost_explicit<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    cap: &KeeperCap,
    cost: u64,
) {
    gachapon.assert_valid_keeper(cap);

    df::borrow_mut<TypeName, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        type_name::get<SecondaryCurrency>(),
    ).cost = cost;
}

// Public Funs

entry fun draw<T>(
    gachapon: &mut Gachapon<T>,
    r: &Random,
    count: u64,
    payment: Coin<T>,
    recipient: address,
    ctx: &mut TxContext,
) {
    let cost = count * gachapon.cost();

    if (gachapon.cost() == 0) {
        abort 69_420
    };

    if (payment.value() < cost) {
        err_payment_not_enough();
    };

    if (count > gachapon.egg_supply()) {
        err_egg_supply_not_enough();
    };

    gachapon.treasury.join(payment.into_balance());

    let reward = get_reward_for_count(gachapon, count);

    let mut generator = r.new_generator(ctx);

    std::u64::do!(count + reward, |_| {
        let random_num = generator.generate_u256();
        let egg_supply = gachapon.egg_supply() as u256;
        let index = (random_num % egg_supply) as u64;
        let egg = gachapon.lootbox.swap_remove(index);
        emit(EggOutV2 {
            gachapon_id: object::id(gachapon),
            egg_id: object::id(&egg),
            egg_idx: option::some(index),
            payment_coin_type: type_name::get<T>(),
            cost: cost,
        });
        transfer::transfer(egg, recipient);
    });
}

entry fun draw_via_secondary_currency<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    r: &Random,
    count: u64,
    payment: Coin<SecondaryCurrency>,
    recipient: address,
    ctx: &mut TxContext,
) {
    let egg_supply = gachapon.egg_supply();

    let vault = df::borrow_mut<u64, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        0,
    );

    let cost = count * vault.cost;

    if (vault.cost == 0) {
        abort 69_420
    };

    if (payment.value() < cost) {
        err_payment_not_enough();
    };

    if (count > egg_supply) {
        err_egg_supply_not_enough();
    };

    vault.secondary_currency.join(payment.into_balance());

    let mut generator = r.new_generator(ctx);
    std::u64::do!(count, |_| {
        let random_num = generator.generate_u256();
        let egg_supply = gachapon.egg_supply() as u256;
        let index = (random_num % egg_supply) as u64;
        let egg = gachapon.lootbox.swap_remove(index);
        emit(EggOutV2 {
            gachapon_id: object::id(gachapon),
            egg_id: object::id(&egg),
            egg_idx: option::some(index),
            payment_coin_type: type_name::get<SecondaryCurrency>(),
            cost: cost,
        });
        transfer::transfer(egg, recipient);
    });
}

entry fun draw_via_secondary_currency_explicit<T, SecondaryCurrency>(
    gachapon: &mut Gachapon<T>,
    r: &Random,
    count: u64,
    payment: Coin<SecondaryCurrency>,
    recipient: address,
    ctx: &mut TxContext,
) {
    let egg_supply = gachapon.egg_supply();

    let store = df::borrow_mut<TypeName, SecondaryCurrencyStore<SecondaryCurrency>>(
        &mut gachapon.id,
        type_name::get<SecondaryCurrency>(),
    );

    let cost = count * store.cost;

    if (store.cost == 0) {
        abort 69_420
    };

    if (payment.value() < cost) {
        err_payment_not_enough();
    };

    if (count > egg_supply) {
        err_egg_supply_not_enough();
    };

    store.secondary_currency.join(payment.into_balance());

    let mut generator = r.new_generator(ctx);
    std::u64::do!(count, |_| {
        let random_num = generator.generate_u256();
        let egg_supply = gachapon.egg_supply() as u256;
        let index = (random_num % egg_supply) as u64;
        let egg = gachapon.lootbox.swap_remove(index);
        emit(EggOutV2 {
            gachapon_id: object::id(gachapon),
            egg_id: object::id(&egg),
            egg_idx: option::some(index),
            payment_coin_type: type_name::get<SecondaryCurrency>(),
            cost: cost,
        });
        transfer::transfer(egg, recipient);
    });
}

public fun destroy_empty(egg: Egg) {
    let Egg { id, content } = egg;
    if (content.is_some()) {
        err_destroy_non_empty_egg();
    };
    id.delete();
    content.destroy_none();
}

public fun redeem_unlocked<T, Obj: key + store>(
    gachapon: &Gachapon<T>,
    kiosk: &mut Kiosk,
    egg: Egg,
): Obj {
    gachapon.assert_valid_kiosk(kiosk);
    let Egg { id, content } = egg;
    id.delete();
    if (content.is_none()) {
        err_redeem_empty_egg();
    };
    let EggContent {
        obj_id,
        is_locked,
    } = content.destroy_some();
    if (is_locked) {
        err_egg_content_is_locked();
    };
    let obj_type = type_name::get<Obj>();
    emit(EggRedeemedV2 {
        gachapon_id: object::id(gachapon),
        kiosk_id: object::id(kiosk),
        obj_id,
        type_name: obj_type,
        balance_value: 0,
    });
    kiosk.take(&gachapon.kiosk_cap, obj_id)
}

/// CoinType can be SUI here as default if the OBJ is a nft
public fun redeem_unlocked_v2<T, Obj: key + store, CoinType>(
    gachapon: &Gachapon<T>,
    kiosk: &mut Kiosk,
    egg: Egg,
): Obj {
    gachapon.assert_valid_kiosk(kiosk);
    let Egg { id, content } = egg;
    id.delete();
    if (content.is_none()) {
        err_redeem_empty_egg();
    };
    let EggContent {
        obj_id,
        is_locked,
    } = content.destroy_some();
    if (is_locked) {
        err_egg_content_is_locked();
    };

    let obj_type = type_name::get<Obj>();

    let balance_value = if (obj_type == type_name::get<Coin<CoinType>>()) {
        kiosk.borrow<Coin<CoinType>>(&gachapon.kiosk_cap, obj_id).value()
    } else {
        0
    };

    emit(EggRedeemedV2 {
        gachapon_id: object::id(gachapon),
        kiosk_id: object::id(kiosk),
        obj_id,
        type_name: obj_type,
        balance_value,
    });

    kiosk.take(&gachapon.kiosk_cap, obj_id)
}

public fun redeem_locked<T, Obj: key + store>(
    gachapon: &mut Gachapon<T>,
    kiosk: &mut Kiosk,
    payment: Coin<SUI>,
    egg: Egg,
): (Obj, TransferRequest<Obj>) {
    gachapon.assert_valid_kiosk(kiosk);
    let Egg { id, content } = egg;
    id.delete();
    if (content.is_none()) {
        err_redeem_empty_egg();
    };
    let EggContent {
        obj_id,
        is_locked,
    } = content.destroy_some();
    if (!is_locked) {
        err_egg_content_is_unlocked();
    };
    kiosk.list<Obj>(&gachapon.kiosk_cap, obj_id, payment.value());
    let obj_type = type_name::get<Obj>();
    emit(EggRedeemedV2 {
        gachapon_id: object::id(gachapon),
        kiosk_id: object::id(kiosk),
        obj_id,
        type_name: obj_type,
        balance_value: 0,
    });
    kiosk.purchase(obj_id, payment)
}

// Free Spins Tracker

// The free spinner tracker allows you to use it per gachapon
public fun create_free_spinner<T>(
    gachapon: &mut Gachapon<T>,
    _cap: &KeeperCap,
    ctx: &mut TxContext,
) {
    let free_spin_tracker = FreeSpinsTracker {
        id: object::new(ctx),
        current_epoch: ctx.epoch(),
        allowed_nfts: vec_set::empty(),
        used_nft: vec_set::empty(),
    };
    df::add(&mut gachapon.id, Tracker {}, free_spin_tracker);
}

public fun add_nft_type<T, Obj>(gachapon: &mut Gachapon<T>, _cap: &KeeperCap) {
    let obj_type = type_name::get<Obj>();
    let spinner = gachapon.borrow_spinner_mut();
    spinner.allowed_nfts.insert(obj_type);
}

public fun remove_nft_type<T, Obj>(gachapon: &mut Gachapon<T>, _cap: &KeeperCap) {
    let obj_type = type_name::get<Obj>();
    let spinner = gachapon.borrow_spinner_mut();
    spinner.allowed_nfts.remove(&obj_type);
}

fun borrow_spinner_mut<T>(gachapon: &mut Gachapon<T>): &mut FreeSpinsTracker {
    df::borrow_mut(&mut gachapon.id, Tracker {})
}

entry fun draw_free_spin_with_personal_kiosk<T, Obj: key + store>(
    gachapon: &mut Gachapon<T>,
    kiosk: &Kiosk,
    mut items: vector<ID>,
    r: &Random,
    recipient: address,
    ctx: &mut TxContext,
) {
    if (personal_kiosk::owner(kiosk) != ctx.sender()) {
        err_not_owner();
    };

    items.map!(|e| kiosk.has_item_with_type<Obj>(e));

    // validation of this
    let obj_type = type_name::get<Obj>();
    let spinner = gachapon.borrow_spinner_mut();

    if (!spinner.allowed_nfts.contains(&obj_type)) {
        err_object_type_not_supported();
    };

    gachapon.add_ids_to_bag_tracker(&items, ctx);

    while (items.length() > 0) {
        let _id = items.pop_back();

        // We only draw once per nft
        if (gachapon.egg_supply() < 1) {
            err_egg_supply_not_enough();
        };
        let mut generator = r.new_generator(ctx);
        let random_num = generator.generate_u256();
        let egg_supply = gachapon.egg_supply() as u256;
        let index = (random_num % egg_supply) as u64;
        let egg = gachapon.lootbox.swap_remove(index);
        emit(EggOutV2 {
            gachapon_id: object::id(gachapon),
            egg_id: object::id(&egg),
            egg_idx: option::some(index),
            payment_coin_type: type_name::get<SUI>(),
            cost: 0,
        });
        transfer::transfer(egg, recipient);
    };
}

entry fun draw_free_spin_with_kiosk<T, Obj: key + store>(
    gachapon: &mut Gachapon<T>,
    kiosk: &mut Kiosk,
    kiosk_owner_cap: &KioskOwnerCap,
    mut items: vector<ID>,
    r: &Random,
    recipient: address,
    ctx: &mut TxContext,
) {
    if (!kiosk.has_access(kiosk_owner_cap)) {
        err_not_owner();
    };

    items.map!(|e| kiosk.has_item_with_type<Obj>(e));

    // validation of this
    let obj_type = type_name::get<Obj>();
    let spinner = gachapon.borrow_spinner_mut();

    if (!spinner.allowed_nfts.contains(&obj_type)) {
        err_object_type_not_supported();
    };

    gachapon.add_ids_to_bag_tracker(&items, ctx);

    while (items.length() > 0) {
        let _id = items.pop_back();

        // We only draw once per nft
        if (gachapon.egg_supply() < 1) {
            err_egg_supply_not_enough();
        };

        let mut generator = r.new_generator(ctx);
        let random_num = generator.generate_u256();
        let egg_supply = gachapon.egg_supply() as u256;
        let index = (random_num % egg_supply) as u64;
        let egg = gachapon.lootbox.swap_remove(index);

        emit(EggOutV2 {
            gachapon_id: object::id(gachapon),
            egg_id: object::id(&egg),
            egg_idx: option::some(index),
            payment_coin_type: type_name::get<SUI>(),
            cost: 0,
        });

        transfer::transfer(egg, recipient);
    };
}

/// Call the draw free spin with passing in an object
entry fun draw_free_spin<T, Obj: key + store>(
    gachapon: &mut Gachapon<T>,
    obj: &Obj,
    r: &Random,
    recipient: address,
    ctx: &mut TxContext,
) {
    // Check that the nft hasn't already been used this epoch
    let obj_type = type_name::get<Obj>();
    let spinner = gachapon.borrow_spinner_mut();

    if (!spinner.allowed_nfts.contains(&obj_type)) {
        err_object_type_not_supported();
    };

    gachapon.add_id_to_bag_tracker(object::id(obj), ctx);

    // We only draw once per nft
    if (gachapon.egg_supply() < 1) {
        err_egg_supply_not_enough();
    };

    let mut generator = r.new_generator(ctx);
    let random_num = generator.generate_u256();
    let egg_supply = gachapon.egg_supply() as u256;
    let index = (random_num % egg_supply) as u64;
    let egg = gachapon.lootbox.swap_remove(index);

    emit(EggOutV2 {
        gachapon_id: object::id(gachapon),
        egg_id: object::id(&egg),
        egg_idx: option::some(index),
        payment_coin_type: type_name::get<SUI>(),
        cost: 0,
    });

    transfer::transfer(egg, recipient);
}

// Getter Funs

public fun cost<T>(gachapon: &Gachapon<T>): u64 {
    gachapon.cost
}

public fun lootbox<T>(gachapon: &Gachapon<T>): &BigVector<Egg> {
    &gachapon.lootbox
}

public fun lootbox_length<T>(gachapon: &Gachapon<T>): u64 {
    gachapon.lootbox.length()
}

public fun kiosk_id<T>(gachapon: &Gachapon<T>): ID {
    gachapon.kiosk_id
}

public fun egg_supply<T>(gachapon: &Gachapon<T>): u64 {
    gachapon.lootbox().length()
}

public fun is_empty<T>(gachapon: &Gachapon<T>): bool {
    gachapon.egg_supply() == 0
}

public fun suppliers<T>(gachapon: &Gachapon<T>): &VecSet<address> {
    &gachapon.suppliers
}

public fun content_id(egg: &Egg): Option<ID> {
    egg.content.map!(|c| c.obj_id)
}

public fun is_locked(egg: &Egg): bool {
    egg.content.is_some() && egg.content.borrow().is_locked
}

public fun gachapon_id(cap: &KeeperCap): ID {
    cap.gachapon_id
}

public fun assert_valid_keeper<T>(gachapon: &Gachapon<T>, cap: &KeeperCap) {
    if (object::id(gachapon) != cap.gachapon_id()) {
        err_invalid_keeper();
    };
}

public fun assert_valid_kiosk<T>(gachapon: &Gachapon<T>, kiosk: &Kiosk) {
    if (gachapon.kiosk_id() != object::id(kiosk)) {
        err_invalid_kiosk();
    };
}

public fun assert_valid_supplier<T>(gachapon: &Gachapon<T>, ctx: &TxContext) {
    if (!gachapon.suppliers.contains(&ctx.sender())) {
        err_invalid_supplier();
    };
}

// Internal Funs

fun new_egg<Obj: key + store>(obj: &Obj, is_locked: bool, ctx: &mut TxContext): (Egg, ID) {
    let obj_id = object::id(obj);
    let egg = Egg {
        id: object::new(ctx),
        content: option::some(EggContent {
            obj_id,
            is_locked,
        }),
    };
    (egg, obj_id)
}

fun new_empty_egg(ctx: &mut TxContext): Egg {
    Egg {
        id: object::new(ctx),
        content: option::none(),
    }
}

fun get_reward_for_count<T>(gachapon: &Gachapon<T>, count: u64): u64 {
    if (!df::exists_<u64>(&gachapon.id, 1)) {
        return 0
    };

    let vec_set = df::borrow<u64, VecSet<RewardTier>>(&gachapon.id, 1);

    let mut reward = 0;

    vec_set.keys().do_ref!(|tier: &RewardTier| {
        if (count >= tier.count) {
            reward = tier.reward;
        };
    });

    reward
}

// Events

public struct NewGachapon has copy, drop {
    coin_type: String,
    gachapon_id: ID,
    cap_id: ID,
    kiosk_id: ID,
}

public struct CloseGachapon has copy, drop {
    coin_type: String,
    gachapon_id: ID,
    cap_id: ID,
    kiosk_id: ID,
}

public struct StuffGachapon has copy, drop {
    gachapon_id: ID,
    count: u64,
}

public struct ObjectIn<phantom Obj> has copy, drop {
    gachapon_id: ID,
    kiosk_id: ID,
    obj_id: ID,
    egg_id: ID,
    is_locked: bool,
}

public struct EggOut has copy, drop {
    gachapon_id: ID,
    egg_id: ID,
    egg_idx: Option<u64>,
}

public struct EggOutV2 has copy, drop {
    gachapon_id: ID,
    egg_id: ID,
    egg_idx: Option<u64>,
    payment_coin_type: TypeName,
    cost: u64,
}

#[allow(unused_field)]
public struct EggRedeemed<phantom Obj> has copy, drop {
    gachapon_id: ID,
    kiosk_id: ID,
    obj_id: ID,
}

#[allow(unused_field)]
public struct EggRedeemedV2 has copy, drop {
    gachapon_id: ID,
    kiosk_id: ID,
    obj_id: ID,
    type_name: TypeName,
    balance_value: u64,
}

// Test-only Funs

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(GACHAPON {}, ctx);
}

// === Special Tracker Funs ===

fun add_bag_tracker<T>(gachapon: &mut Gachapon<T>, ctx: &mut TxContext) {
    if (
        df::exists_<SpecialTracker>(
            &gachapon.id,
            SpecialTracker {
                epoch: ctx.epoch(),
            },
        )
    ) {
        return
    };

    let tracker = BagTracker {
        id: object::new(ctx),
        bag: bag::new(ctx),
        ids: vector::empty(),
    };

    df::add(
        &mut gachapon.id,
        SpecialTracker {
            epoch: ctx.epoch(),
        },
        tracker,
    );
}

fun add_id_to_bag_tracker<T>(gachapon: &mut Gachapon<T>, id: ID, ctx: &mut TxContext) {
    gachapon.add_bag_tracker(ctx);
    let tracker = df::borrow_mut<SpecialTracker, BagTracker>(
        &mut gachapon.id,
        SpecialTracker { epoch: ctx.epoch() },
    );

    tracker.bag.add(id, true);
    tracker.ids.push_back(id);
}

fun add_ids_to_bag_tracker<T>(gachapon: &mut Gachapon<T>, items: &vector<ID>, ctx: &mut TxContext) {
    gachapon.add_bag_tracker(ctx);

    let tracker = df::borrow_mut<SpecialTracker, BagTracker>(
        &mut gachapon.id,
        SpecialTracker {
            epoch: ctx.epoch(),
        },
    );

    items.do_ref!(|id| {
        tracker.bag.add(*id, true);
        tracker.ids.push_back(*id);
    });
}

// === Special Tracker Public Funs ===

public fun get_ids_of_current_epoch<T>(gachapon: &Gachapon<T>, ctx: &TxContext): vector<ID> {
    let tracker = df::borrow<SpecialTracker, BagTracker>(
        &gachapon.id,
        SpecialTracker {
            epoch: ctx.epoch(),
        },
    );

    tracker.ids
}
