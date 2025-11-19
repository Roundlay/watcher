### A simple file-system watcher

Watcher implements a basic Win32 file-system watcher that looks for and responds to modifications to file-system events.

**Command-line Launch Arguments**

- `-watch:<string>`: Specify the direcotry to watch for file modification events (`-w`, `--watch`)
- `-target:<string>`: Supply a specific compilation target (`-t`, `--target`)

**How-tos**

Watch for file modification events in the same directory:

- `watcher`

Watch for file modification events in a specific directory:

- `watcher --watch:C:\Users\User\Projects\watch`

Watch for file modification events in a specific directory and use a specific compilation target:

- `watcher -w:C:\Users\User\Projects\watch -t:js_wasm32`
