# SlopLang Semantics

SlopLang keeps Python's surface syntax but runs on the BEAM, where all data
is immutable. This document describes where SlopLang follows Python, and
where it deliberately deviates.

## Values

| SlopLang type | BEAM representation |
| ------------- | ------------------- |
| `int`         | integer             |
| `float`       | float               |
| `str`         | UTF-8 binary        |
| `bool`        | `true` / `false`    |
| `None`        | `nil`               |
| `list`        | Erlang list         |
| `tuple`       | Erlang tuple        |
| `dict`        | Erlang map          |
| `set`         | `{'$set', Map}`     |
| instance      | map with a `'$class'` key |
| class         | atom `'module.Name'` |

All values are immutable terms. There is no in-place mutation anywhere in
the language.

## Rebinding instead of mutation

Because values are immutable, "mutating" operations return updated values:

```python
xs = [3, 1, 2]
ys = xs.sort()      # xs is unchanged; ys is the sorted list
```

To keep Python's ergonomic statement style, SlopLang has the **statement
rebind rule**: when a statement consists of a single method call whose
receiver is a name (or an attr/subscript chain rooted at a name), the
receiver is rebound to the call's result:

```python
xs.sort()                # same as: xs = xs.sort()
self.items.append(x)     # same as: self.items = self.items.append(x)
st.push(1).push(2)       # same as: st = st.push(1).push(2)
```

The rebind is **type-conditional**: it only takes effect when the result
has the same kind as the receiver (list→list, dict→dict, set→set, or an
instance of the same class). Value-returning calls leave the binding
alone:

```python
st.pop()     # st is NOT rebound to the popped integer
n.bit_length()  # n is unchanged
```

In expression position (`y = xs.pop()` etc.) no rebind ever happens; the
expression simply evaluates to the result.

## The pop protocol

Since a single value cannot both yield an element and the updated
collection, `pop` on lists, dicts, and sets returns a 2-tuple
`(updated, element)`:

```python
xs, top = xs.pop()       # unpack rebinds xs and binds top
d2, val = d.pop("k")
```

User classes that model mutable state should follow the same convention
(see `examples/09_classes_state.slop`):

```python
class Stack:
    def pop(self):
        self.items, top = self.items.pop()
        return (self, top)

st, a = st.pop()
```

## Objects and methods

- `__init__` initializes `self` via attribute assignment; its (implicit)
  return value is the resulting instance.
- A method with no explicit `return` evaluates to `self`, so mutating
  methods chain naturally: `st.push(1).push(2).push(3)`.
- Attribute assignment returns the updated object, so `self.x = 1`
  rebinds the local `self` variable; callers that hold the old instance
  keep the old value unless the rebind rule applies.

## Closures

Closures capture their enclosing environment **by value** at the point
the function is created:

```python
fs = [lambda: i for i in range(3)]
[f() for f in fs]    # [2, 2, 2], matching Python's late binding here
```

`nonlocal` is not supported (parse error); rebinding a captured variable
inside a closure does not affect the outer scope. Module-level names are
always read through the module environment, so lambdas can reference
module globals defined by the time the call happens (including the
binding they are assigned to, e.g. memoized self-recursion at module
level).

## Other deviations from Python

- Generators are eager: a generator expression fully evaluates to a list.
- `NAME.method()` in statement position rebinds (see above); Python
  mutates in place instead.
- Loop closures capture loop variables by value per iteration state.
- Integers are arbitrary precision (BEAM), floats are 64-bit.
- `str` is a UTF-8 binary; indexing yields 1-character strings.

## Error model

SlopLang exceptions are thrown as `{'$slop_exc', Class, Instance}` terms
and integrate with `try`/`except`/`finally`, `raise ... from ...`, and
exception classes with inheritance. Uncaught exceptions print the class
and `args`.
