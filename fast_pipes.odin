// NOTE: This doesn't do anything. This is just a test.

package main

import "core:sys/windows"
import "core:fmt"

// import "core:strings"
// fmt: Formatting string.
// args: A variadic list of arguments to be formatted
// cprintf :: proc(fmt: string, args: ..any) -> cstring {
//     cstring_builder := strings.builder_make()
//     defer strings.builder_destroy(&cstring_builder)
//     strings.builder_reset(&cstring_builder)
//     fmt.sbprintf(&cstring_builder, fmt, ..args)
//     strings.write_byte(&cstring_builder, 0)
//     return strings.unsafe_string_to_cstring(strings.to_string(cstring_builder))
// }
// cptintf("\\\\.\\pipe\\fastpipe%x", windows.GetCurrentProcessId())


main :: proc() {
    // Attempts to establish a fast pipe based on the current process ID.
    // It returns true if successful, false otherwise.
    pipe := windows.utf8_to_wstring(fmt.tprintf("\\\\.\\pipe\\fastpipe%x", windows.GetCurrentProcessId()))
    fast_pipe : windows.HANDLE = windows.CreateFileW(pipe, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_EXISTING, 0, nil)

    // Set the standard output and input handles to the fast pipe.
    // if fast_pipe != windows.INVALID_HANDLE_VALUE {
    //     windows.SetStdHandle(windows.STD_OUTPUT_HANDLE, fast_pipe)
    //     windows.SetStdHandle(windows.STD_INPUT_HANDLE, fast_pipe)
    // }

    // Format the pipe name with the current process ID.
    // process_id := windows.GetCurrentProcessId()
    // _, err := fmt.sbprintf(pipe_name, "\\\\?\\pipe\\fastpipe%x", process_id)
    // if err != nil {
    //     fmt.println("Error formatting pipe name:", err)
    //     return false
    // }

    // Attempt to open the fast pipe.
    // fast_pipe := win.CreateFileW(&pipe_name[0], win.GENERIC_READ|win.GENERIC_WRITE, 0, nil, win.OPEN_EXISTING, 0, nil)
    // if fast_pipe == win.INVALID_HANDLE_VALUE {
    //     // Fast pipe is not available.
    //     return false
    // }
}


