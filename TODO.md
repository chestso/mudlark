# TODO

## Unicode width

Width is boba's fact, not mudlark's: the runtime pins a cell-width model
(`TUI_WIDTH_MODEL_GRID`, `WCWIDTH` or `UTS51`) from the startup environment
before the first byte is emitted, and every measurement goes through it. Read
it back with `(termcap 'width-model)`.

The interesting residue is the model that has to be guessed rather than asked
for: a terminal reached without its environment (kitty over ssh without the
ssh kitten) measures with the grid rule and may land a cell off on a selector
cluster. boba's `TuiRuntimeConfig.width_model` is the escape hatch; mudlark
does not set it, so an override would be a `--width-model` flag here.

What mudlark no longer does — and should not start doing — is its own probing
or `wcwidth()` fallback: a second measurement rule can only disagree with the
one that decided where the committed scrollback's columns land.

## Inline frame: very tall input

A frame taller than the terminal (a pasted multi-line input, or a narrow
window) is outside inline mode's model: boba's inline render moves the cursor
up over the previous frame, and once the frame itself has scrolled there is
nothing stable to move up over. nevermore has the same shape and answers it by
capping its live region.

boba 0.7.1 has no textinput height setter (the field exists but relative mode
does not consult it), so capping means either a boba API or a mudlark-side
row cap in `telnet_app_view`. Not done: it needs a scroll window inside the
input to stay useful, which is a textinput feature.

## Scripting architecture

Lisp is the scripting environment. Each connection has a Lisp environment that holds all session state — aliases, actions, highlights, variables, and triggers are all stored in Lisp hash tables. This is the source of truth, and everything saved to disk is Lisp code.

TinTin++ commands (`#act`, `#alias`, `#var`, `#highlight`, etc.) are prompt-level sugar. They exist because `#alias go north` is quick to type at a MUD prompt. But Lisp equivalents don't have to be verbose — e.g. `(alias "go" "north")`. And Lisp shines when things get conditional:

```lisp
(action "* arrives from the *."
  (lambda (mob dir)
    (when (string=? mob "goblin")
      "kill goblin")))
```

Compare the TinTin++ equivalent:

```
#act {%0 arrives from the %1.} {#if {"%0" == "goblin"} {kill goblin}}
```

The `#if` with string-based conditionals is its own mini-language duplicating what Lisp does natively. So the TinTin++ layer is mainly about familiarity. The underlying data structures are Lisp — currently hash tables, though the exact representation hasn't been deeply considered and may evolve.

This split is intentional:

- **`#save`** writes Lisp. The output is a `.lisp` file of `hash-set!` calls that reconstructs the session state. There is no TinTin++ config format.
- **`#load`** evaluates Lisp. Loading a saved session just evaluates the Lisp file, which populates the hash tables.
- **`#read`** bridges TinTin++ config files into the Lisp environment. It parses TinTin++ command syntax and translates each line into the equivalent Lisp operation. This lets users bring existing TinTin++ configs without rewriting them by hand.

### Future directions

- Better Lisp integration at the prompt — make it easy to drop into Lisp expressions without needing the TinTin++ layer.
- Reduce reliance on TinTin++ string interpretation. The current TinTin++ parser does its own variable substitution, pattern matching, and flow control (`#if`/`#else`), all of which duplicate what Lisp already does natively. Over time, make Lisp the natural choice for anything beyond simple one-liners.
- TinTin++ config transpiler — an offline batch tool that reads a full TinTin++ config file and emits equivalent Lisp code, producing clean, idiomatic output. `#read` handles this at runtime already; the transpiler would be a standalone version for migration. Could later expand to support importing from zMUD, CMUD, and Mudlet config formats as well.
