#[test_only]
module gachapon::gachapon_tests;

use sui::address;
use sui::random::{Self, Random};
use sui::kiosk::{Kiosk};
use sui::coin;
use sui::test_scenario::{Self as ts};
use sui::transfer_policy::{TransferPolicy};
use gachapon::gachapon::{Self as gcp, Gachapon, KeeperCap, Egg};
use gachapon::gachapon_rule;
use gachapon::item::{Self, Item};

public fun keeper(): address { @0x1ee9e }

public fun cost(): u64 { 1_000_000_000 }

public fun users(count: u64): vector<address> {
    vector::tabulate!(
        count, |idx| address::from_u256((idx + 100) as u256)
    )
}

#[test]
fun test_gachapon() {
    use sui::sui::SUI;
    let users = users(2);
    let player = users[0];
    let supplier = users[1];
    let item_count = 5;
    let stuff_count = 90;

    let mut scenario = ts::begin(@0x0);
    let s = &mut scenario;
    random::create_for_testing(s.ctx());

    s.next_tx(keeper());
    item::init_for_testing(s.ctx());
    let cap = gcp::create<SUI>(cost(), keeper(), s.ctx());
    transfer::public_transfer(cap, keeper());

    s.next_tx(keeper());
    let mut gachapon = s.take_shared<Gachapon<SUI>>();
    let mut kiosk = s.take_shared<Kiosk>();
    let cap = s.take_from_sender<KeeperCap>();
    assert!(gachapon.cost() == cost());
    assert!(cap.gachapon_id() == object::id(&gachapon));
    assert!(gachapon.kiosk_id() == object::id(&kiosk));
    std::u64::do!(item_count, |idx| {
        gachapon.place(&mut kiosk, item::new(idx, s.ctx()), s.ctx())
    });
    gachapon.lootbox().borrow_slice(1).do_ref!(
        |egg| assert!(!egg.is_locked())
    );
    assert!(gachapon.egg_supply() == item_count);
    gachapon.add_supplier(&cap, supplier);
    assert!(gachapon.suppliers().contains(&supplier));
    assert!(gachapon.suppliers().size() == 2);
    ts::return_shared(gachapon);
    ts::return_shared(kiosk);
    s.return_to_sender(cap);

    s.next_tx(supplier);
    let mut gachapon = s.take_shared<Gachapon<SUI>>();
    let mut kiosk = s.take_shared<Kiosk>();
    let policy = s.take_shared<TransferPolicy<Item>>();
    std::u64::do!(item_count, |idx| {
        let item = item::new(idx + item_count, s.ctx());
        gachapon.lock(&mut kiosk, &policy, item, s.ctx())
    });
    assert!(gachapon.egg_supply() == 2 * item_count);
    ts::return_shared(gachapon);
    ts::return_shared(kiosk);
    ts::return_shared(policy);

    s.next_tx(keeper());
    let mut gachapon = s.take_shared<Gachapon<SUI>>();
    let cap = s.take_from_sender<KeeperCap>();
    gachapon.stuff(&cap, stuff_count, s.ctx());
    assert!(gachapon.egg_supply() == 2 * item_count + stuff_count);
    ts::return_shared(gachapon);
    s.return_to_sender(cap);

    s.next_tx(player);
    let draw_count = 2 * item_count + stuff_count;
    let mut gachapon = s.take_shared<Gachapon<SUI>>();
    let random = s.take_shared<Random>();
    let total_cost = draw_count * cost();
    let payment = coin::mint_for_testing<SUI>(total_cost, s.ctx());
    gachapon.draw(&random, draw_count, payment, player, s.ctx());
    ts::return_shared(gachapon);
    ts::return_shared(random);

    s.next_tx(player);
    let mut gachapon = s.take_shared<Gachapon<SUI>>();
    let mut kiosk = s.take_shared<Kiosk>();
    let policy = s.take_shared<TransferPolicy<Item>>();
    let egg_ids = s.ids_for_sender<Egg>();
    egg_ids.do!(|egg_id| {
        let egg = s.take_from_sender_by_id<Egg>(egg_id);
        if (egg.content_id().is_none()) {
            egg.destroy_empty();
        } else {
            if (egg.is_locked()) {
                let payment = coin::mint_for_testing<SUI>(0, s.ctx());
                let (
                    item,
                    mut req,
                ) = gachapon.redeem_locked<SUI, Item>(&mut kiosk, payment, egg);
                gachapon_rule::prove(&mut req, &gachapon, &kiosk);
                let (item_id, paid_amount, kiosk_id) = policy.confirm_request(req);
                assert!(item_id == object::id(&item));
                assert!(paid_amount == 0);
                assert!(kiosk_id == object::id(&kiosk));
                transfer::public_transfer(item, player);
            } else {
                let item = gachapon.redeem_unlocked<SUI, Item>(&mut kiosk, egg);
                transfer::public_transfer(item, player);
            }
        };
    });
    ts::return_shared(gachapon);
    ts::return_shared(kiosk);
    ts::return_shared(policy);

    s.next_tx(player);
    let item_ids = s.ids_for_sender<Item>();
    item_ids.do!(|item_id| {
        let item = s.take_from_sender_by_id<Item>(item_id);
        // std::debug::print(&item.index());
        s.return_to_sender(item);
    });

    s.next_tx(keeper());
    let gachapon = s.take_shared<Gachapon<SUI>>();
    let kiosk = s.take_shared<Kiosk>();
    let cap = s.take_from_sender<KeeperCap>();
    let (
        gachapon_fund,
        kiosk_fund,
    ) = gachapon.close(cap, kiosk, s.ctx());
    assert!(gachapon_fund.value() == cost() * draw_count);
    assert!(kiosk_fund.value() == 0);
    gachapon_fund.burn_for_testing();
    kiosk_fund.destroy_zero();

    scenario.end();
}

#[test]
fun test_remove_multiple_eggs() {
    use sui::sui::SUI;
    let users = users(2);
    let player = users[0];
    let supplier = users[1];
    let stuff_count = 90;

    let mut scenario = ts::begin(@0x0);
    let s = &mut scenario;
    random::create_for_testing(s.ctx());

    s.next_tx(keeper());
    item::init_for_testing(s.ctx());
    let cap = gcp::create<SUI>(cost(), keeper(), s.ctx());
    transfer::public_transfer(cap, keeper());

    s.next_tx(keeper());
    let mut gachapon = s.take_shared<Gachapon<SUI>>();
    let cap = s.take_from_sender<KeeperCap>();
    gachapon.stuff(&cap, stuff_count, s.ctx());
    assert!(gachapon.egg_supply() == stuff_count);
    ts::return_shared(gachapon);
    s.return_to_sender(cap);

    s.next_tx(keeper());
    let mut gachapon = s.take_shared<Gachapon<SUI>>();
    let cap = s.take_from_sender<KeeperCap>();
    let mut kiosk = s.take_shared<Kiosk>();
    let mut i = 89;
    while (i >= 0) {
        let egg = gachapon.take(&mut kiosk, &cap, i);
        transfer::public_transfer(egg, keeper());
        if (i == 0) {
            break
        };
        i = i - 1;
    };

    s.return_to_sender(cap);
    ts::return_shared(gachapon);
    ts::return_shared(kiosk);

    scenario.end();

}