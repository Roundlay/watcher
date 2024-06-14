### 𝐖𝐚𝐭𝐜𝐡𝐞𝐫: A simple file-system watcher and auto-compiler for the Odin programming language.

𝐖𝐚𝐭𝐜𝐡𝐞𝐫 implements a basic Win32 file-system watcher that looks for and responds to modifications to `.odin` files in a specific directory. When such a an event is detected 𝐖𝐚𝐭𝐜𝐡𝐞𝐫 attempts to compile and execute the modified file. If the compilation or execution process fails, the program emits some nicely formatted error messages from the compiler. In principle, the tool can easily be extended to watch for changes to other event or file types.

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

- - - - -

![Screenshot (362)](https://github.com/Roundlay/watcher/assets/4133752/beeef4f6-0348-4e74-bef8-b9379c94ab60)
