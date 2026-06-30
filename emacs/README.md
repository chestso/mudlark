# tintin-mode (mudlark contrib)

Emacs major mode for editing [TinTin++](https://tintin.mudhalla.net/) `.tin`
script files. Bundled with mudlark as a contrib package.

## Features

- Syntax highlighting for commands, control flow, variables, functions, and comments
- Pattern matching (`%0`–`%99`, `%*`), speedwalk (`3n2e4sw`), and direction (`w`, `3e`) highlighting
- Three comment styles: `/* */` blocks, `//` lines, and `#nop`
- Brace matching (`C-M-f` / `C-M-b`) and brace highlighting
- Indentation based on brace nesting (`TAB`)
- Case-insensitive command recognition
- [Charm](https://charm.land)-inspired color palette with 8 faces (dark and light variants)

## Build targets

From the mudlark build directory (or top-level source via `make emacs-*`):

```bash
make emacs          # byte-compile tintin-mode.el
make emacs-test     # run ERT test suite
make emacs-format   # indent elisp files + prettier on Markdown
make emacs-install  # install to $(prefix)/share/emacs/site-lisp/
make emacs-clean    # remove byte-compiled artifacts
```

The `EMACS` variable selects the Emacs binary (default: `emacs`).

```bash
make emacs EMACS=/path/to/emacs
```

The `emacs/` subdirectory is built via autotools (`Makefile.am`); these
targets delegate to the autotools build directory.

## Installation

### Via mudlark install

```bash
cd chest/mudlark
./autogen.sh && mkdir build && cd build
../configure --prefix=$HOME/.local
make emacs-install
```

Installs to `$(prefix)/share/emacs/site-lisp/`. Add to your init file:

```elisp
(add-to-list 'load-path
  (expand-file-name "share/emacs/site-lisp"
    (or (getenv "XDG_DATA_HOME") "~/.local/share")))
(require 'tintin-mode)
```

### Manual

Add the `emacs/` directory to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/chest/mudlark/emacs")
(require 'tintin-mode)
```

### use-package :vc (Emacs 30+)

```elisp
(use-package tintin-mode
  :vc (:url "https://codeberg.org/thomasc/mudlark"
      :branch "main" :lisp-dir "emacs"))
```

### straight.el

```elisp
(straight-use-package
 '(tintin-mode :type git :host nil
               :repo "https://codeberg.org/thomasc/mudlark"
               :files "emacs/*.el"))
```

## Usage

Opening any `.tin` file activates the mode automatically. To activate manually:

```
M-x tintin-mode
```

### Customization

```elisp
;; Change indentation width (default 2)
(setq tintin-indent-offset 4)
```

All faces are customizable via `M-x customize-group RET tintin RET`.

## License

GPL-3.0-or-later. See [COPYING](COPYING).
