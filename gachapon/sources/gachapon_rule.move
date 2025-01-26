/// allow suppliers to directly put items in Gachapon
/// without requirements of other rules (like royalty, min price, etc)
module gachapon::gachapon_rule;

// Dependencies

use sui::kiosk::{Kiosk};
use sui::transfer_policy::{
    Self as policy,
    TransferPolicy,
    TransferPolicyCap,
    TransferRequest,
};
use sui::package::{Publisher};
use gachapon::gachapon::{Gachapon};

// Errors

const EInvalidTransfer: u64 = 0;

// Witness

public struct Rule has drop {}

public struct Config has store, drop {}

// Public Funs

public fun add<Obj: key + store>(
    policy: &mut TransferPolicy<Obj>,
    cap: &TransferPolicyCap<Obj>,
) {
    policy::add_rule(Rule {}, policy, cap, Config {});
}

public fun prove<T, Obj: key + store>(
    request: &mut TransferRequest<Obj>,
    gachapon: &Gachapon<T>,
    kiosk: &Kiosk,
) {
    gachapon.assert_valid_kiosk(kiosk);
    // check if the item is transfered from or to gachapon's kiosk
    assert!(
        request.from() == gachapon.kiosk_id() || // check from
        kiosk.has_item(request.item()), // check to
        EInvalidTransfer,
    );
    policy::add_receipt(Rule {}, request);
}


// Entry Funs

#[allow(lint(share_owned))]
entry fun default<Obj: key + store>(pub: &Publisher, ctx: &mut TxContext) {
    let (mut policy, cap) = policy::new<Obj>(pub, ctx);
    add(&mut policy, &cap);
    transfer::public_share_object(policy);
    transfer::public_transfer(cap, ctx.sender());
}
