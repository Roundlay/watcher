A simple auto-compiler for the Odin programming language.

Watcher implements a basic Win32 file-system watcher that looks for modifications to files with the `.odin` extension. When a change is detected, the program attempts to compile and execute the associated file. If compilation fails for some reason, the program displays some nicely formatted compiler warnings.

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
- - - - -
![Screenshot (362)](https://github.com/Roundlay/watcher/assets/4133752/beeef4f6-0348-4e74-bef8-b9379c94ab60)
