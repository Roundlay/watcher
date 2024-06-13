A simple auto-compiler for the Odin programming language.

Watcher implements a basic file-system watcher that looks for changes to Odin files (e.g. you saving your work). When a change is detected to any files with a `.odin` extension, the file is compiled and executed.

**Command-line Launch Arguments**

- `-watch:<string>`: Supply a watch-directory (`-w`, `--watch`)
- `-target:<string>`: Supply a compilation target (`-t`, `--target`)

**How-tos**

Watch for changes in Watcher's directory:

- `watcher`

Watch for changes in a specific directory:

- `watcher --watch:C:\Users\User\Projects\watch`

Watch for changes in a specific directory and compile to a specific compilation target:

- `watcher -w:C:\Users\User\Projects\watch -t:js_wasm32`


