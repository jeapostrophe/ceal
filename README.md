# CEAL

TEAL is low-level stack-based programming language for the Algorand network.
It has some disadvantages:
- The bytecode format is ad-hoc and difficult to produce.
- It is necessary to have a complex assembler that, for example, determines the
  four most common constants and deals with jump offsets.
- It is difficult to analyze for verification and for computing worst-case
  execution times (WCET).
- It is difficult to evaluate efficiently.
- It is difficult to produce by hand, because it is a low-level stack-based
  machine.

CEAL is low-level C-style programming language for the Algorand network.
- It uses msgpack encoding, which is available in all languages and platforms,
  and used pervasively in Algorand.
- It has a trivial assembler and uses language-level binding for recurring objects.
- It is trivial to analyze and compute WCETs.
- It is amenable to many common evaluation and compilation techniques, such as
  compilation to LLVM.
- It is feasible to produce by hand and amenable to a simple implementation
  with a C-style surface syntax.

# Design

CEAL has global constants, first-order functions, a fixed set of
primitives, single-static assignment, switches, and bounded `for` loops.
See `Main.hs` for an example implementation.

Programs defines an initial heap, the global constants, the functions, and the
program body (referred to as a "tail", for computational tail.)

The initial heap is a bytestring which is a prefix of the heap.
The rest of the heap is filled with 0s.
The total heap size is fixed.
(The maximum memory available to existing TEAL programs is 256 x 4096 bytes = 1 megabyte.)

Variables are integers.

Constants are integers.

Functions have a list of parameters, a variable bound to a `return` function,
and a body.
A function evaluates to what its body evaluates to.
Functions are bound in a specific order with no recursion or forward
references.
That is, if functions definitions appear in the order `f, g, h`, then `h` may
call `f` and `g`, but neither `f` nor `g` may call `h`.
Thus, functions are a form of code compression and abstraction, but do not
allow any new computations.

Tails are either:
- An expression in tail position
- An expression bound to a variable
- An expression evalaute for effect
- An `if` statement
- A `switch` with a jump table and a default target
- A `for` loop which is evaluated for effect followed by a continuation.
  The `for` loop has a variable which is bound to `0` to `m` for some constant
  `m`.
  The `for` loop body may `break` or `continue` by calling one of the nullary
  functions bound by the header.

Expressions are either:
- Variable references
- Primitive applications
- Function applications

Primitives come from a fixed-set and are annotated with costs.
The set of primitives would contain adaptations of most of the TEAL opcodes,
except many which will instead work on heap fragments rather than bytestring
objects.
For example, `b+` would take three pointers to 32 byte regions set `m[z] = m[x] + m[y]` and `btoi` would be replaced with something like `cast(uint64)(x)` which reads 8 bytes from the memory starting at `x`.

A few other TEAL concepts would be adjusted too.
For example, we would remove "keys" as a concept in global/local storage and
the thing corresponding to `app_global_get` would either be a specific region
of the heap that would be memory mapped (so changes are automatically set at
the end of the program) or it would be `app_global_copy` and would copy the
memory starting at a pointer.
The second is probably better if there will eventually be many "pages" of
global memory and it would be more "symmetric" with a `app_local_copy` that
read the state of a specific account.

# Cost accounting

It is trivial to compute a worst-case execution time by computing the maximum
cost across all paths.
Since functions are not recursive, it is not necessary to do more than
preprocess each function.
Since loops are bounded, you may simply multiple the WCET of their body by
their bound.

In pseudo-code (see `Main.hs` for a real implementation):
```
wcet (if _ t f) = max (wcet t) (wcet f)
wcet (for m b k) = m * wcet b + wcet k
...
```

--

Currently TEAL uses dynamic cost accounting.
Previously it used a non-sensical cost accounting where both sides of a branch
were counted, i.e.:
```
wcet (if _ t f) = (wcet t) + (wcet f)
```
This was used because there was (and is) no control-flow analysis of TEAL code
to construct a graph from.

You may think that I (Jay McCarthy) prefer dynamic cost accounting, but I
don't.
I think that valid worst-cost accounting is best, but it is just too hard to do
in assembly with functions and backjumps, so dynamic cost accounting is a
compromise, just like the previous accounting strategy was a compromise.

# Implementation

It is trivial to transform this language into LLVM IR, which provides
officially supported Go bindings.
- https://github.com/llvm/llvm-project/tree/main/llvm/bindings/go/llvm
- https://felix.engineer/blogs/an-introduction-to-llvm-in-go
- ^ this example uses the interpreter, but you really want a JIT engine.
  Here's a snippet: https://stackoverflow.com/a/36878491/336884

Algorand nodes do not need to store compiled code, but can JIT it outside of
the hot region before a transaction enters the pool.

The JIT'd code can call into the go-algorand implementation by directly binding
those functions into built-ins.
This would be used to provide implementation of primitives like `txn` and
`global`.

This implementation would be drastically faster than the current
implementation, which would justify drastically increasing the cost budget.

# Encoding Options

I would highly recommend a no-binding-variable format where variables never
actually appear in binding position.

You can do this by mandating that global constants and first-order functions
are sequentialized, rather than named.
That is, rather than:

```
prog := heap [(var, const) ...] [(var, fundef) ...] body
```

It would be better to have

```
prog := heap [const ...] [fundef ...] body
```

And automatically compute the constant and function variables by their
position in the sequence. Similarly, for all other positions.
For example, rather than `let x = e in b` you can simply have `let e in b` and
`e` is just bound to the next variable.
Rather than `fun (x_1, ..., x_n) ret b` you can just have `fun n b` and you know
that there are `n` variables bound to the next `n` that are available, plus one
for the `return` label.
This `n` can itself be one of the global constants for more compression.

As a complete example:

```
const a := 1
fun b ( c ) d {
 let e := isZero(c)
 if e {
  d(a)
 }
 let f := c + c
 f + f
}
main {
 let c := a + a
 b(c)
}
```

would be:

```
const 1
fun 1 {
 let isZero(#2)
 if #4 {
  #3(#0)
 }
 let #2 + #2
 #5 + #5
}
main {
 let #0 + #0
 #1(#2)
}
```

Obviously no human could keep this straight in their head, but it is a trivial
assembler.

--

It may be advisable for encoding to inline all primitives forms into the
definition of expression.
That is, rather than:

```
expr := var
      | var(var, ...)
      | prim(var, ...)
prim := + | - | memref | memset | ...
```

It would probably be better to have
```
expr := var
      | var(var, ...)
      | +(var, var)
      | -(var, var)
      | memref(var)
      | memset(var)
      | ...
```

But I'm not an expert on how relatively efficient msgpack is in these two
situations.

--

We assume that program encodings are capped in size similar to existing TEAL
bytecode.

# Plausible Additions

The could be a `switch` variable that work for ABI method signatures.
It would receive a variable pointing to method signature in the heap and each
case would be a method signature.

# Discussion

The main advantages of this are a drastically simpler encoding and drastically
faster evaluator.

The main disadvantages of this are a totally new implementation, but I think it
could share a lot in common with the current implementation in V1.
As an alternative, I don't think it is plausible to take current TEAL and, for
example, JIT it (whether through LLVM or not) because it would be too
stack-intensive (obviously).

Although CEAL, as presented above, is not a user-facing language, it would be
easy to translate a C-like language into it by doing simple SSA-style
ANF-transformation of the source, lifting integer constants to the top-level,
and lifting non-integer constants into an initial heap as pointers.
I think the Algorand audience would expand if people could write "C" smart
contracts and you could even adapt PyTEAL pretty readily to output this style.

As a final note, I don't think there's any value is js-algorand-sdk (and
friends) to do any bytecode validation, like they do now, because the nodes
have to do this again anyways (i.e. they can't trust that they've received
valid input from the user), so I think you should just completely delete that
code rather than worry about reimplementing some new strategy for this new
format.
