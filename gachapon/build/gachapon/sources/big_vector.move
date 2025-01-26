module gachapon::big_vector;

// ======== Dependencies ========

use sui::dynamic_field;

// ======== Errors ========

const E_NOT_EMPTY: u64 = 0;

// ======== Structs ========

public struct BigVector<phantom Element> has key, store {
    id: UID,
    slice_count: u64,
    slice_size: u64,
    length: u64,
}

// ======== Functions ========

/// create BigVector
public fun new<Element: store>(slice_size: u64, ctx: &mut TxContext): BigVector<Element> {
    let mut id = object::new(ctx);
    let slice_count = 1;
    dynamic_field::add(&mut id, slice_count, vector::empty<Element>());
    BigVector<Element> {
        id,
        slice_count,
        slice_size,
        length: 0,
    }
}

/// return the slice_count of the BigVector
public fun slice_count<Element: store>(bv: &BigVector<Element>): u64 {
    bv.slice_count
}

/// return the max size of a slice in the BigVector
public fun slice_size<Element: store>(bv: &BigVector<Element>): u64 {
    bv.slice_size
}

/// return the size of the BigVector
public fun length<Element: store>(bv: &BigVector<Element>): u64 {
    bv.length
}

/// return the slice_id related to the index i
public fun slice_id<Element: store>(bv: &BigVector<Element>, i: u64): u64 {
    (i / bv.slice_size) + 1
}

/// return true if the BigVector is empty
public fun is_empty<Element: store>(bv: &BigVector<Element>): bool {
    bv.length == 0
}

/// push a new element at the end of the BigVector
public fun push_back<Element: store>(bv: &mut BigVector<Element>, element: Element) {
    if (length(bv) / bv.slice_size == bv.slice_count) {
        bv.slice_count = bv.slice_count + 1;
        let new_slice = vector::singleton(element);
        dynamic_field::add(&mut bv.id, bv.slice_count, new_slice);
    }
    else {
        let slice = dynamic_field::borrow_mut(&mut bv.id, bv.slice_count);
        vector::push_back(slice, element);
    };
    bv.length = bv.length + 1;
}

/// pop an element from the end of the BigVector
public fun pop_back<Element: store>(bv: &mut BigVector<Element>): Element {
    let slice = dynamic_field::borrow_mut(&mut bv.id, bv.slice_count);
    let element = vector::pop_back(slice);
    trim_slice(bv);
    bv.length = bv.length - 1;

    element
}

/// borrow an element at index i from the BigVector
public fun borrow<Element: store>(bv: &BigVector<Element>, i: u64): &Element {
    let slice_count = (i / bv.slice_size) + 1;
    let slice = dynamic_field::borrow(&bv.id, slice_count);
    vector::borrow(slice, i % bv.slice_size)
}

/// borrow a mutable element at index i from the BigVector
public fun borrow_mut<Element: store>(bv: &mut BigVector<Element>, i: u64): &mut Element {
    let slice_count = (i / bv.slice_size) + 1;
    let slice = dynamic_field::borrow_mut(&mut bv.id, slice_count);
    vector::borrow_mut(slice, i % bv.slice_size)
}

/// borrow a slice from the BigVector
public fun borrow_slice<Element: store>(bv: &BigVector<Element>, slice_count: u64): &vector<Element> {
    dynamic_field::borrow(&bv.id, slice_count)
}

/// borrow a mutable slice from the BigVector
public fun borrow_slice_mut<Element: store>(bv: &mut BigVector<Element>, slice_count: u64): &mut vector<Element> {
    dynamic_field::borrow_mut(&mut bv.id, slice_count)
}

/// swap and pop the element at index i with the last element
public fun swap_remove<Element: store>(bv: &mut BigVector<Element>, i: u64): Element {
    let result = pop_back(bv);
    if (i == length(bv)) {
        result
    } else {
        let slice_count = (i / bv.slice_size) + 1;
        let slice = dynamic_field::borrow_mut<u64, vector<Element>>(&mut bv.id, slice_count);
        vector::push_back(slice, result);
        vector::swap_remove(slice, i % bv.slice_size)
    }
}

/// remove the element at index i and shift the rest elements
/// abort when reference more thant 1000 slices
/// costly function, use wisely
public fun remove<Element: store>(bv: &mut BigVector<Element>, i: u64): Element {
    let slice = dynamic_field::borrow_mut<u64, vector<Element>>(&mut bv.id, (i / bv.slice_size) + 1);
    let result = vector::remove(slice, i % bv.slice_size);
    let mut slice_count = bv.slice_count;
    while (slice_count > (i / bv.slice_size) + 1 && slice_count > 1) {
        let slice = dynamic_field::borrow_mut<u64, vector<Element>>(&mut bv.id, slice_count);
        let tmp = vector::remove(slice, 0);
        let prev_slice = dynamic_field::borrow_mut<u64, vector<Element>>(&mut bv.id, slice_count - 1);
        vector::push_back(prev_slice, tmp);
        slice_count = slice_count - 1;
    };
    trim_slice(bv);
    bv.length = bv.length - 1;

    result
}

/// drop BigVector, abort if it's not empty
public fun destroy_empty<Element: store>(bv: BigVector<Element>) {
    let BigVector {
        mut id,
        slice_count: _,
        slice_size: _,
        length,
    } = bv;
    assert!(length == 0, E_NOT_EMPTY);
    let empty_slice = dynamic_field::remove(&mut id, 1);
    vector::destroy_empty<Element>(empty_slice);
    object::delete(id);
}

/// drop BigVector if element has drop ability
/// abort when the BigVector contains more thant 1000 slices
public fun drop<Element: store + drop>(bv: BigVector<Element>) {
    let BigVector {
        mut id,
        mut slice_count,
        slice_size: _,
        length: _,
    } = bv;
    while (slice_count > 0) {
        dynamic_field::remove<u64, vector<Element>>(&mut id, slice_count);
        slice_count = slice_count - 1;
    };
    object::delete(id);
}

/// remove empty slice after element removal
fun trim_slice<Element: store>(bv: &mut BigVector<Element>) {
    let slice = dynamic_field::borrow_mut<u64, vector<Element>>(&mut bv.id, bv.slice_count);
    if (bv.slice_count > 1 && vector::length(slice) == 0) {
        let empty_slice = dynamic_field::remove(&mut bv.id, bv.slice_count);
        vector::destroy_empty<Element>(empty_slice);
        bv.slice_count = bv.slice_count - 1;
    };
}
