// Whitebox tests for the typed state store (RFC 0001 §3.3). Pure MoonBit.

///|
test "new_cell stores and updates a typed value" {
  let s = Store::new()
  let c : CellId[Int] = s.new_cell(10)
  assert_eq(s.get(c), 10)
  s.set(c, 32)
  assert_eq(s.get(c), 32)
}

///|
test "cells of different types coexist" {
  let s = Store::new()
  let i : CellId[Int] = s.new_cell(1)
  let b : CellId[Bool] = s.new_cell(false)
  let t : CellId[String] = s.new_cell("a")
  let f : CellId[Float] = s.new_cell(1.5)
  s.set(i, 2)
  s.set(b, true)
  s.set(t, "b")
  s.set(f, 2.5)
  assert_eq(s.get(i), 2)
  assert_eq(s.get(b), true)
  assert_eq(s.get(t), "b")
  assert_eq(s.get(f), 2.5)
}

///|
test "cell ids are independent" {
  let s = Store::new()
  let a : CellId[Int] = s.new_cell(1)
  let b : CellId[Int] = s.new_cell(2)
  s.set(a, 100)
  assert_eq(s.get(b), 2)
}

///|
test "cell_for_key returns the same cell on repeat calls" {
  let s = Store::new()
  let first : CellId[Int] = s.cell_for_key("k", 5)
  s.set(first, 42)
  // Second call with the same key ignores `init` and returns the live cell.
  let second : CellId[Int] = s.cell_for_key("k", 99)
  assert_eq(s.get(second), 42)
}

///|
test "cell_for_key scopes by key and by type" {
  let s = Store::new()
  let a : CellId[Int] = s.cell_for_key("k", 1)
  let b : CellId[Int] = s.cell_for_key("other", 2)
  // Same key, different value type: a distinct cell.
  let t : CellId[String] = s.cell_for_key("k", "text")
  s.set(a, 10)
  assert_eq(s.get(b), 2)
  assert_eq(s.get(t), "text")
}

///|
test "closures capture cells across registries" {
  // The component-model wiring: a handler closure mutates a store cell.
  let s = Store::new()
  let count : CellId[Int] = s.new_cell(0)
  let r = HandlerRegistry::new()
  let id = r.on_click(fn(_view) { s.set(count, s.get(count) + 1) })
  r.dispatch(Click(id.to_int()), 0)
  r.dispatch(Click(id.to_int()), 0)
  assert_eq(s.get(count), 2)
}
