#[test_only]
module gachapon::item;

use sui::package;
use sui::transfer_policy::{Self as policy};
use gachapon::gachapon_rule;

public struct ITEM has drop {}

public struct Item has key, store {
    id: UID,
    index: u64,
}

fun init(otw: ITEM, ctx: &mut TxContext) {
    let pub = package::claim(otw, ctx);
    let (mut policy, policy_cap) = policy::new<Item>(&pub, ctx);
    gachapon_rule::add(&mut policy, &policy_cap);
    transfer::public_transfer(pub, ctx.sender());
    transfer::public_share_object(policy);
    transfer::public_transfer(policy_cap, ctx.sender());
}

public fun init_for_testing(ctx: &mut TxContext) {
    init(ITEM {}, ctx);
}

public fun new(index: u64, ctx: &mut TxContext): Item {
    Item { id: object::new(ctx), index }
}

public fun index(item: &Item): u64 {
    item.index
}
