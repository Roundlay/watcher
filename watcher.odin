package watcher

/*

A file system watcher written in Odin.

TODO: Should we move away from ReadDirectoryChangesW API as a default for tracking changes in directory? Because it requires a file handle, it locks folder we're watching.

TODO: Would any parts of the code benefit from complete refactors? If not, what parts of the code could be improved in terms of performance and/or a reduction in instruction count by adhering to the data-oriented design principles outlined in <dod>?

*/

import "core:os"
import "core:fmt"
import "core:time"
import "core:strings"
import "base:runtime"
import "core:sys/windows"
import "core:path/filepath"

import "core:os/os2"

ANSI_RESET :: "\x1b[0m"
ANSI_CLEAR :: "\x1b[2J"
ANSI_HOME  :: "\x1b[H"
ANSI_WHITE :: "\x1b[38;2;256;256;256m"

BLOCKING :: windows.INFINITE
NON_BLOCKING :: windows.DWORD(0)
PROCESS_COMPLETED :: windows.WAIT_OBJECT_0
PROCESS_RUNNING :: windows.WAIT_TIMEOUT

ProcessCreationState :: struct {
    startup_information : windows.STARTUPINFOW,
    security_attributes : windows.SECURITY_ATTRIBUTES,
    process_information : windows.PROCESS_INFORMATION,
    process_name        : windows.wstring,
    creation_flags      : windows.DWORD,
}

// Helper function to initialize the process creation state.
initialise_process_creation_state :: proc() -> ProcessCreationState {
    state : ProcessCreationState
    state.startup_information.dwFlags = windows.STARTF_USESTDHANDLES
    state.startup_information.hStdOutput = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    state.startup_information.hStdError  = windows.GetStdHandle(windows.STD_ERROR_HANDLE)

    state.security_attributes.bInheritHandle = windows.TRUE
    state.security_attributes.nLength = size_of(windows.SECURITY_ATTRIBUTES)

    state.process_information.hProcess = windows.INVALID_HANDLE_VALUE
    state.process_information.hThread  = windows.INVALID_HANDLE_VALUE

    state.creation_flags = windows.CREATE_NEW_PROCESS_GROUP | windows.CREATE_UNICODE_ENVIRONMENT
    return state
}

PIPE_BUFFER_CAPACITY_BYTES :: uintptr(8192 * 16)

ProcessPipe :: struct {
    read_handle  : windows.HANDLE,
    write_handle : windows.HANDLE,
    overlapped   : windows.OVERLAPPED,
    buffer       : []u8,
}

ProcessIOState :: struct {
    stdout : ProcessPipe,
    stderr : ProcessPipe,
}

PipeDrainTarget :: enum {
    Stdout,
    Stderr,
}

// Helper function to initialize the process IO state.
initialise_process_io_state :: proc() -> ProcessIOState {
    state : ProcessIOState
    init_pipe :: proc() -> ProcessPipe {
        pipe : ProcessPipe
        pipe.read_handle  = windows.INVALID_HANDLE_VALUE
        pipe.write_handle = windows.INVALID_HANDLE_VALUE
        pipe.overlapped   = windows.OVERLAPPED{}
        pipe.overlapped.hEvent = windows.CreateEventW(nil, windows.TRUE, windows.FALSE, nil)
        pipe.buffer = make([]u8, int(PIPE_BUFFER_CAPACITY_BYTES))
        return pipe
    }

    state.stdout = init_pipe()
    state.stderr = init_pipe()
    return state
}

destroy_process_io_state :: proc(state: ^ProcessIOState) {
    destroy_pipe :: proc(pipe: ^ProcessPipe) {
        if pipe.buffer != nil {
            delete(pipe.buffer)
            pipe.buffer = nil
        }
        if pipe.overlapped.hEvent != windows.INVALID_HANDLE_VALUE {
            windows.CloseHandle(pipe.overlapped.hEvent)
            pipe.overlapped.hEvent = windows.INVALID_HANDLE_VALUE
        }
        if pipe.read_handle != windows.INVALID_HANDLE_VALUE {
            windows.CloseHandle(pipe.read_handle)
            pipe.read_handle = windows.INVALID_HANDLE_VALUE
        }
        if pipe.write_handle != windows.INVALID_HANDLE_VALUE {
            windows.CloseHandle(pipe.write_handle)
            pipe.write_handle = windows.INVALID_HANDLE_VALUE
        }
    }

    destroy_pipe(&state.stdout)
    destroy_pipe(&state.stderr)
}

drain_process_pipe :: proc(pipe: ^ProcessPipe, target: PipeDrainTarget) {
    if pipe.read_handle == windows.INVALID_HANDLE_VALUE || len(pipe.buffer) == 0 {
        return
    }

    target_name := "stdout"
    if target == .Stderr {
        target_name = "stderr"
    }

    bytes_read := windows.DWORD(0)
    if pipe.overlapped.hEvent != windows.INVALID_HANDLE_VALUE {
        windows.ResetEvent(pipe.overlapped.hEvent)
    }

    read_success := windows.ReadFile(pipe.read_handle, &pipe.buffer[0], u32(len(pipe.buffer)), &bytes_read, &pipe.overlapped)
    if read_success {
        if bytes_read > 0 {
            if target == .Stdout {
                fmt.printf("%s", pipe.buffer[:bytes_read])
            } else {
                fmt.eprintf("%s", pipe.buffer[:bytes_read])
            }
        }
        return
    }

    last_error := windows.GetLastError()
    if last_error == windows.ERROR_IO_PENDING {
        if windows.GetOverlappedResult(pipe.read_handle, &pipe.overlapped, &bytes_read, windows.TRUE) {
            if bytes_read > 0 {
                if target == .Stdout {
                    fmt.printf("%s", pipe.buffer[:bytes_read])
                } else {
                    fmt.eprintf("%s", pipe.buffer[:bytes_read])
                }
            }
        } else {
            fmt.eprintf("\x1b[31mERROR: GetOverlappedResult failed for pipe {}: {}\x1b[0m\n", target_name, windows.GetLastError())
        }
    } else if last_error != windows.ERROR_BROKEN_PIPE {
        fmt.eprintf("\x1b[31mERROR: ReadFile failed for pipe {}: {}\x1b[0m\n", target_name, last_error)
    }
}

ConsoleState :: struct {
    standard_output_handle : windows.HANDLE,
    standard_input_handle : windows.HANDLE,
    original_output_mode : windows.DWORD,
    original_input_mode : windows.DWORD,
}

// Helper function to initialize the console state.
initialise_console_state :: proc() -> ConsoleState {
    // Enable UTF-8 processing for console output.
    // windows.SetConsoleOutputCP(windows.CP_UTF8)
    
    // Retrieve the handle for standard output.
    console_standard_output_handle := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    if console_standard_output_handle == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("ERROR: The standard output handle is invalid: {}\n", windows.GetLastError())
        return ConsoleState{}
    }
    
    // Retrieve the original output mode.
    original_console_output_mode : windows.DWORD
    if !windows.GetConsoleMode(console_standard_output_handle, &original_console_output_mode) {
        fmt.eprintf("ERROR: windows.GetConsoleMode failed for standard output handle: {}\n", windows.GetLastError())
        return ConsoleState{}
    }
    
    // Retrieve the handle for standard input.
    console_standard_input_handle := windows.GetStdHandle(windows.STD_INPUT_HANDLE)
    if console_standard_input_handle == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("ERROR: The standard input handle is invalid: {}\n", windows.GetLastError())
        return ConsoleState{}
    }
    
    // Retrieve the original input mode.
    original_console_input_mode : windows.DWORD
    if !windows.GetConsoleMode(console_standard_input_handle, &original_console_input_mode) {
        fmt.eprintf("ERROR: windows.GetConsoleMode failed for standard input handle: {}\n", windows.GetLastError())
        return ConsoleState{}
    }
    
    // Helper function to combine base mode flags with additional mode flags and set them.
    apply_console_mode_flags :: proc(console_handle : windows.HANDLE, base_mode_flags : windows.DWORD, additional_mode_flags : windows.DWORD) -> bool {
        combined_mode_flags := base_mode_flags | additional_mode_flags
        if !windows.SetConsoleMode(console_handle, combined_mode_flags) {
            fmt.eprintf("ERROR: windows.SetConsoleMode failed for handle {}: {}\n", console_handle, windows.GetLastError())
            return false
        }
        return true
    }
    
    additional_output_mode_flags := windows.ENABLE_WRAP_AT_EOL_OUTPUT |
                                    windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
                                    windows.ENABLE_PROCESSED_OUTPUT
    if !apply_console_mode_flags(console_standard_output_handle, original_console_output_mode, additional_output_mode_flags) {
        return ConsoleState{}
    }
    
    additional_input_mode_flags := windows.ENABLE_ECHO_INPUT |
                                   windows.ENABLE_LINE_INPUT |
                                   windows.ENABLE_WINDOW_INPUT |
                                   windows.ENABLE_PROCESSED_INPUT |
                                   windows.ENABLE_VIRTUAL_TERMINAL_INPUT
    if !apply_console_mode_flags(console_standard_input_handle, original_console_input_mode, additional_input_mode_flags) {
        return ConsoleState{}
    }
    
    return ConsoleState{
        standard_output_handle = console_standard_output_handle,
        standard_input_handle  = console_standard_input_handle,
        original_output_mode   = original_console_output_mode,
        original_input_mode    = original_console_input_mode,
    }
}

get_console_screen_buffer_dimensions :: proc(standard_output_handle: windows.HANDLE) -> (width: int, height: int) {
    console_screen_buffer_info : windows.CONSOLE_SCREEN_BUFFER_INFO
    if !windows.GetConsoleScreenBufferInfo(standard_output_handle, &console_screen_buffer_info) do return 0, 0
    return int(console_screen_buffer_info.srWindow.Right - console_screen_buffer_info.srWindow.Left + 1), int(console_screen_buffer_info.srWindow.Bottom - console_screen_buffer_info.srWindow.Top + 1)
}

// TEMP

StatusInfo :: struct {
    file_path   : string,    // absolute or relative
    modified    : bool,
    cursor_line : int,       // 1‑based
    cursor_col  : int,       // 1‑based (UTF‑8 code‑points, keep it simple)
    total_lines : int,
}

// TEMP STATUS LINE

build_status_line :: proc(s: StatusInfo, width: int) -> string {
    mod_tag : string
    if s.modified { mod_tag = "[+]" } else { mod_tag = "" }
    file_name := filepath.base(s.file_path)

    _string_builder : strings.Builder
    strings.builder_init(&_string_builder)

    // Core pieces; adjust or reorder to taste.
    left  := fmt.sbprintf(&_string_builder, "%s %s", file_name, mod_tag)
    pos   := fmt.sbprintf(&_string_builder, "Ln %d, Col %d", s.cursor_line, s.cursor_col)
    ratio := fmt.sbprintf(&_string_builder, "%d/%d", s.cursor_line, s.total_lines)

    // Assemble with two spaces as separators.
    line := fmt.sbprintf(&_string_builder, "%s  %s  (%s)", left, ratio, pos)

    // arena := strings.to_string(_string_builder)

    // Padding / truncation.
    runes := strings.rune_count(line)
    switch {
    case runes < width: // pad
        pad := strings.repeat(" ", width - runes)
        line_pad : []string = {line, pad}
        line = strings.concatenate(line_pad)
    case runes > width: // truncate and mark with ellipsis
        // naïve rune‑slice; OK for ASCII‑heavy UI.
        line_string := strings.to_string(_string_builder)
        line = strings.cut(line_string, 0, width - 1)
    }

    return line
}

// TODO Does this even work? How do I prove it works?
should_terminate : bool = false
signal_handler :: proc "stdcall" (signal_type: windows.DWORD) -> windows.BOOL {
    context = runtime.default_context()
    if signal_type == windows.CTRL_C_EVENT {
        fmt.printf("Received CTRL_C_EVENT signal\n")
        should_terminate = true
    }
    return windows.TRUE
}

main :: proc() {
    fmt.printf("%s%s", ANSI_CLEAR, ANSI_HOME)

    // TODO Does this even work? How do I prove it works?
    // Display memory leaks when running the executable with the -debug flag.
    // when ODIN_DEBUG {
    //     track: mem.Tracking_Allocator
    //     mem.tracking_allocator_init(&track, context.allocator)
    //     defer {
    //         if len(track.allocation_map) > 0 {
    //             fmt.eprintf("%v allocations not freed: \n", len(track.allocation_map))
    //             for _, entry in track.allocation_map {
    //                 fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
    //             }
    //         }
    //         if len(track.bad_free_array) > 0 {
    //             fmt.eprintf("%v incorrect frees: \n", len(track.bad_free_array))
    //             for entry in track.bad_free_array {
    //                 fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
    //             }
    //         }
    //         mem.tracking_allocator_destroy(&track)
    //     }
    // }

    windows.SetConsoleCtrlHandler(signal_handler, windows.TRUE)

    console_state : ConsoleState = initialise_console_state()

    // FILE SYSTEM WATCHER BEGIN

    // NOTE: When creating an I/O completion port without associating it with a
    // file handle (i.e. by passing `windows.INVALID_HANDLE_VALUE` as the first
    // argument) the completion key is ignored, so it's okay to use `0` as the
    // completion key value for simplicity.

    null_completion_key : uint = 0
    io_completion_port_handle := windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, nil, null_completion_key, 1)
    if io_completion_port_handle == windows.INVALID_HANDLE_VALUE do return
    defer windows.CloseHandle(io_completion_port_handle)

    // NOTE: Make sure to pass the full file path to the Odin compiler, or the
    // file system watcher will look for events in its own directory.

    // watched_directory : windows.wstring 

    ArgInfo :: struct {
        watch_directory         : string,
        watch_directory_wstring : windows.wstring,
        compilation_target      : string,
        build_template          : string,
        outname                 : string
    }

    parse_arguments :: proc(args: []string) -> (info: ArgInfo, ok: bool) {
        // Setup valid targets.
        // TODO Unfinished
        compilation_targets: [24]string = {
            "darwin_amd64", "darwin_arm64", "essence_amd64",
            "linux_i386", "linux_amd64", "linux_arm64", "linux_arm32",
            "windows_i386", "windows_amd64",
            "freebsd_i386", "freebsd_amd64", "freebsd_arm64",
            "openbsd_amd64", "netbsd_amd64", "haiku_amd64",
            "freestanding_wasm32", "wasi_wasm32", "js_wasm32",
            "freestanding_wasm64p32", "js_wasm64p32", "wasi_wasm64p32",
            "freestanding_amd64_sysv", "freestanding_amd64_win64", "freestanding_arm64"
        }

        target_map := make(map[string]bool)
        defer delete(target_map)
        for target in compilation_targets {
            target_map[target] = true
        }

        // If no arguments, default to current directory.
        if len(args) <= 1 {
            info.watch_directory = os.get_current_directory()
            info.watch_directory_wstring = windows.utf8_to_wstring(info.watch_directory)
            if strings.has_prefix(info.watch_directory, "\\\\?\\") {
                info.watch_directory = info.watch_directory[4:]
            }
            return info, true
        }

        // Process command-line arguments (skipping the executable name).
        for arg in args[1:] {
            idx := strings.index(arg, ":")
            if idx < 0 {
                continue
            }

            key := strings.trim_space(arg[:idx])
            value := strings.trim_space(arg[idx+1:])

            switch key {
            case "-watch", "--watch", "-w":
                if value == "" {
                    fmt.eprintln("ERROR: No watch directory provided.")
                    return info, false
                }
                info.watch_directory = value
                file_info, fi_err := os.lstat(info.watch_directory)
                if fi_err != 0 || os.is_dir(file_info.fullpath) != true {
                    return info, false
                }
                info.watch_directory_wstring = windows.utf8_to_wstring(info.watch_directory)
                if strings.has_prefix(info.watch_directory, "\\\\?\\") {
                    info.watch_directory = info.watch_directory[4:]
                }

            case "-target", "--target", "-t":
                _, ok := target_map[value]
                if value == "" || ok != true {
                    return info, false
                }
                info.compilation_target = value

            case "-template", "--template", "-tmpl":
                if value == "" {
                    return info, false
                }
                info.build_template = value

            case "-out", "--out", "-o":
                if value == "" {
                    return info, false
                }
                info.outname = value
            }
        }

        // Default watch directory if not set.
        if info.watch_directory == "" {
            info.watch_directory = os.get_current_directory()
            info.watch_directory_wstring = windows.utf8_to_wstring(info.watch_directory)
            if strings.has_prefix(info.watch_directory, "\\\\?\\") {
                info.watch_directory = info.watch_directory[4:]
            }
        }

        return info, true
    }

    command_line_arguments :: proc() -> [] string {
        result := make([]string, len(runtime.args__))
        for argument, i in runtime.args__ {
            result[i] = string(argument)
        }
        return result
    }

    args := command_line_arguments()
    // args := os._alloc_command_line_arguments()
    defer delete(args)

    // Actually parse the arguments and store them in arg_info
    arg_info, arg_info_ok := parse_arguments(args)
    if !arg_info_ok {
        fmt.eprintln("ERROR: Argument parsing failed; exiting.")
        return
    } else {
        fmt.println(arg_info)
    }

    watched_directory_handle : windows.HANDLE = windows.CreateFileW(arg_info.watch_directory_wstring, windows.FILE_LIST_DIRECTORY, windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED, nil)

    close_handle :: proc(handle: ^windows.HANDLE) {
        if handle^ != windows.INVALID_HANDLE_VALUE {
            windows.CloseHandle(handle^)
            handle^ = windows.INVALID_HANDLE_VALUE
        }
    }
    // close_handle(&watched_directory_handle)

    // NOTE: The `CompletionKey` argument required by `CreateIoCompletionPort`
    // is essentially any value that has some meaning to you. It can be used to
    // identify the completion port when a completion packet is returned to us.
    // We can't direclty cast a windows.HANDLE to uint, so we have to cast it to
    // uintptr first, and then cast it to uint in the function call. Here I'm
    // using the handle to the watched directory as the completion key because
    // it's unique and it's the only thing we're watching.

    completion_key := cast(uintptr)watched_directory_handle
    if windows.CreateIoCompletionPort(watched_directory_handle, io_completion_port_handle, cast(uint)completion_key, 1) == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("`windows.CreateIoCompletionPort` has an invalid watched_directory_handle value: {}", windows.GetLastError())
        return
    }

    overlapped := new(windows.OVERLAPPED)
    buffer := make([]byte, 2048)
    defer delete(buffer)

    if windows.ReadDirectoryChangesW(watched_directory_handle, &buffer[0], u32(len(buffer)), true, windows.FILE_NOTIFY_CHANGE_FILE_NAME | windows.FILE_NOTIFY_CHANGE_DIR_NAME  | windows.FILE_NOTIFY_CHANGE_LAST_WRITE, nil, overlapped, nil) == windows.BOOL(false) {
        fmt.eprintf("`windows.ReadDirectoryChangesW` returned false or failed. Last error: {}", windows.GetLastError())
        return
    }

    exit_code : windows.DWORD
    compiled, executing : bool = false, false
    timer : time.Tick
    command : string

    // NOTE: Faced situations where a buffer size of 8192 wasn't big enough
    // to hold large compilation outputs.
    compilation_output_buffer := make([]u8, 8192 * 8)
    defer delete(compilation_output_buffer)

    builder, builder_error := strings.builder_make_len_cap(0, 8192 * 8) 
    defer strings.builder_destroy(&builder)

    process_state := initialise_process_creation_state()
    io_state      := initialise_process_io_state()
    defer destroy_process_io_state(&io_state)

    for {

        // prevent the cpu from getting rustled.
        time.sleep(time.Millisecond * 1)

        if should_terminate {
            // close handles for watched directory and io completion port.
            if watched_directory_handle != windows.INVALID_HANDLE_VALUE {
                windows.CloseHandle(watched_directory_handle)
                watched_directory_handle = windows.INVALID_HANDLE_VALUE
            }

            if io_completion_port_handle != windows.INVALID_HANDLE_VALUE {
                windows.CloseHandle(io_completion_port_handle)
                io_completion_port_handle = windows.INVALID_HANDLE_VALUE
            }

            // terminate and clean up the process if it is still running.
            if process_state.process_information.hProcess != windows.INVALID_HANDLE_VALUE {
                windows.TerminateProcess(process_state.process_information.hProcess, 1)
                close_handle(&process_state.process_information.hProcess)
            }
            close_handle(&process_state.process_information.hThread)
            close_handle(&io_state.stdout.read_handle)
            close_handle(&io_state.stdout.write_handle)
            close_handle(&io_state.stderr.read_handle)
            close_handle(&io_state.stderr.write_handle)

            break
        }

        if executing {
            drain_process_pipe(&io_state.stdout, .Stdout)
            drain_process_pipe(&io_state.stderr, .Stderr)

            status_of_running_process := windows.WaitForSingleObject(process_state.process_information.hProcess, 0)
            if status_of_running_process == PROCESS_COMPLETED {
                if windows.GetExitCodeProcess(process_state.process_information.hProcess, &exit_code) {
                    if exit_code == 0 {
                        fmt.printf("\n\x1b[32mINFO: Process execution completed successfully in {} ms.\x1b[0m\n", time.tick_since(timer))
                    } else {
                        fmt.eprintf("\n\x1b[31mERROR: Process completed with non-zero exit code %d\x1b[0m\n", exit_code)
                    }
                } else {
                    fmt.eprintf("\n\x1b[31mERROR: Failed to get exit code for process: %d\x1b[0m\n", windows.GetLastError())
                }

                close_handle(&process_state.process_information.hProcess)
                close_handle(&process_state.process_information.hThread)
                close_handle(&io_state.stdout.read_handle)
                close_handle(&io_state.stderr.read_handle)
                executing = false
            }

            if !windows.SetConsoleMode(console_state.standard_output_handle, console_state.original_output_mode) {
                fmt.eprintf("\x1b[31mERROR: Failed to reset output console mode: %d\x1b[0m\n", windows.GetLastError())
            }
            if !windows.SetConsoleMode(console_state.standard_input_handle, console_state.original_input_mode) {
                fmt.eprintf("\x1b[31mERROR: Failed to reset input console mode: %d\x1b[0m\n", windows.GetLastError())
            }
            fmt.printf("%s", ANSI_RESET)
        }

        number_of_bytes_transferred := windows.DWORD(0)
        lp_completion_key : uint = 1

        if windows.GetQueuedCompletionStatus(io_completion_port_handle, &number_of_bytes_transferred, &lp_completion_key, &overlapped, NON_BLOCKING) == windows.BOOL(false) {
            last_error := windows.GetLastError()
            switch last_error {
            case PROCESS_RUNNING:
                continue
            case windows.ERROR_OPERATION_ABORTED:
                continue
            case:
                fmt.eprintf("\x1b[31mERROR: GetQueuedCompletionStatus returned false. Last error: {}\x1b[0m\n", last_error)
                break
            }
        }

        notifications := (^windows.FILE_NOTIFY_INFORMATION)(&buffer[0])
        queue_command : bool = false
        filename := ""
        file_action_old_name := ""

        for {
            // Convert the file notification wide string into UTF-8 once per entry.
            notification_wname := windows.wstring(&notifications.file_name[0])
            event_filename, conversion_err := windows.wstring_to_utf8(notification_wname, int(notifications.file_name_length)/2, context.temp_allocator)
            if conversion_err != runtime.Allocator_Error.None {
                fmt.eprintf("\x1b[31mERROR: Failed to decode file notification: {}\x1b[0m\n", conversion_err)
                break
            }

            if strings.has_suffix(event_filename, ".obj") do break

                action := notifications.action
                strings.builder_reset(&builder)

                switch action {
                case windows.FILE_ACTION_ADDED:
                    if strings.contains(event_filename, "4913") do break
                        // fmt.println("\x1b[33mEVENT: Created\t", event_filename, "\x1b[0m")
                case windows.FILE_ACTION_REMOVED:
                    if strings.contains(event_filename, "4913") do break
                        // fmt.println("\x1b[33mEVENT: Removed\t", event_filename, "\x1b[0m")
                case windows.FILE_ACTION_MODIFIED:
                    if strings.has_suffix(event_filename, ".odin") {
                        // fmt.println("\x1b[33mEVENT: Modified\t", event_filename, "\x1b[0m")
                        queue_command = true
                        filename = event_filename
                    } else {
                        // fmt.println("\x1b[33mEVENT: Modified\t", event_filename, "\x1b[0m")
                    }
                case windows.FILE_ACTION_RENAMED_OLD_NAME:
                    file_action_old_name = event_filename
                case windows.FILE_ACTION_RENAMED_NEW_NAME:
                    // fmt.println("\x1b[33mEVENT: Renamed\t", file_action_old_name, "to", event_filename, "\x1b[0m")
                case:
                    fmt.println("\x1b[33m", event_filename, "- Unknown action", action, "\x1b[0m")
                }

                if notifications.next_entry_offset == 0 do break
                    notifications = (^windows.FILE_NOTIFY_INFORMATION)(uintptr(notifications) + uintptr(notifications.next_entry_offset))
        }

        if queue_command {
            if process_state.process_information.hProcess != windows.INVALID_HANDLE_VALUE {
                windows.TerminateProcess(process_state.process_information.hProcess, 1)
                close_handle(&process_state.process_information.hProcess)
            }

            compiled, executing = false, false
            strings.builder_reset(&builder)

            full_filepath := strings.join({arg_info.watch_directory, filename}, "\\")
            source_dir := filepath.dir(full_filepath)

            if arg_info.build_template != "" {
                for token in strings.split(arg_info.build_template, " ") {
                    if token == "$file" {
                        strings.write_quoted_string(&builder, full_filepath)
                    } else if strings.contains(token, "$out") {
                        outname := arg_info.outname
                        if outname == "" {
                            outname = "main.exe"
                        }
                        out_path := strings.join({source_dir, outname}, "\\")
                        strings.write_string(&builder, "-out:\"")
                        strings.write_string(&builder, out_path)
                        strings.write_string(&builder, "\"")
                    } else if strings.has_prefix(token, "-out:") {
                        outname := token[strings.index(token, ":")+1:]
                        full_outpath := strings.join({full_filepath, outname}, "\\")
                        strings.write_string(&builder, "-out:\"")
                        strings.write_string(&builder, full_outpath)
                        strings.write_string(&builder, "\"")
                    } else if strings.contains(token, "$target") {
                        strings.write_string(&builder, arg_info.compilation_target)
                    } else {
                        strings.write_string(&builder, token)
                    }
                    strings.write_byte(&builder, ' ')
                }

                if arg_info.compilation_target != "" && !strings.contains(strings.to_string(builder), "-target:") {
                    strings.write_string(&builder, "-target:")
                    strings.write_string(&builder, arg_info.compilation_target)
                }
                command = strings.to_string(builder)
                fmt.printf("\x1b[36mDEBUG: Command with template: {}\x1b[0m\n", command)
            } else {
                strings.write_string(&builder, "odin build \"")
                strings.write_string(&builder, full_filepath)
                strings.write_string(&builder, "\" -file")

                outname := arg_info.outname
                out_extension := ".exe"
                if arg_info.compilation_target == "js_wasm32" {
                    out_extension = ".wasm"
                }
                if outname == "" {
                    outname = strings.concatenate({filename[:len(filename)-5], out_extension})
                }
                out_path := strings.join({source_dir, outname}, "\\")
                strings.write_string(&builder, "-out:\"")
                strings.write_string(&builder, out_path)
                strings.write_string(&builder, "\"")

                if arg_info.compilation_target != "" {
                    strings.write_string(&builder, " -target:")
                    strings.write_string(&builder, arg_info.compilation_target)
                }
                command = strings.to_string(builder)
                assert(strings.has_prefix(command, fmt.tprintf("odin build \"{}\"", full_filepath)), fmt.tprintf("Command '{}' should start with 'odin build \"{}\"'", command, full_filepath))
                assert(strings.contains(command, fmt.tprintf("-out:\"{}\"", out_path)), fmt.tprintf("Command '{}' should contain '-out:\"{}\"", command, out_path))
            }

            strings.builder_reset(&builder)
            command_w := windows.utf8_to_wstring(command)
            assert(len(command) > 0, "Generated command should not be empty")
            assert(command_w != nil, "Failed to convert build command to UTF-16")

            // Compilation step.
            Error :: struct {
                filepath, message, snippet, underline: string,
                row, column : int,
                coordinates, carots: [2]int,
                suggestions : [dynamic]string,
            }

            // error: Error

            // parse_multiline_suggestions : bool = false
            // line_offset := 0
            // row_column_separator := ":"
            // line_code_separator := " | "

            if !compiled {
                defer {
                    close_handle(&io_state.stderr.write_handle)
                    close_handle(&io_state.stderr.read_handle)
                    close_handle(&process_state.process_information.hProcess)
                }

                if !windows.CreatePipe(&io_state.stderr.read_handle, &io_state.stderr.write_handle, &process_state.security_attributes, 0) {
                    fmt.eprintf("\x1b[31mERROR: CreatePipe failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                    break
                }
                process_state.startup_information.hStdError = io_state.stderr.write_handle

                timer = time.tick_now()
                source_dir = filepath.dir(full_filepath)
                source_dir_w := windows.utf8_to_wstring(source_dir)
                if source_dir_w == nil {
                    fmt.eprintf("\x1b[31mERROR: Failed to convert source directory '{}' to UTF-16\x1b[0m\n", source_dir)
                    break
                }

                if !windows.CreateProcessW(nil, command_w, nil, nil, windows.TRUE, process_state.creation_flags, nil, source_dir_w, &process_state.startup_information, &process_state.process_information) {
                    last_error := windows.GetLastError()
                    fmt.eprintf("\x1b[31mERROR: CreateProcessW failed. Last error: {}\x1b[0m\n", last_error)
                    break
                }
                // The process handle is stored inside process_state.process_information.
                close_handle(&process_state.process_information.hThread)
                close_handle(&io_state.stderr.write_handle)

                // for {
                //     bytes_read: windows.DWORD
                //     if !windows.ReadFile(io_state.error_read_handle, &compilation_output_buffer[0], u32(len(compilation_output_buffer)), &bytes_read, nil) || bytes_read == 0 {
                //         break
                //     }
                //     fmt.printf("\x1b[34mINFO: Bytes read: {}\x1b[0m", bytes_read)
                //     compiler_output := cast(string)compilation_output_buffer[:bytes_read]
                //     compiler_output_lines := strings.split(compiler_output, "\n")
                //     coordinates : []string
                //     fmt.sbprint(&builder, "\n")
                //     for i := 0; i < len(compiler_output_lines); i += 1 {
                //         if strings.index(compiler_output_lines[i], ":/") == 1 {
                //             filepath_segments := strings.split(strings.cut(compiler_output_lines[i], 0, strings.index(compiler_output_lines[i], "(")), "/")
                //             error.filepath = strings.join(filepath_segments[len(filepath_segments) - 4:], "/")
                //             fmt.sbprintf(&builder, "{}.../{}{}\n", ANSI_WHITE, error.filepath, ANSI_RESET)
                //             open_paren_index := strings.index(compiler_output_lines[i], "(")
                //             close_paren_index := strings.index(compiler_output_lines[i], ")")
                //             if open_paren_index != -1 {
                //                 error.coordinates = {open_paren_index + 1, close_paren_index}
                //                 coords_str := compiler_output_lines[i][error.coordinates[0] : error.coordinates[1]]
                //                 if strings.contains(coords_str, ":") {
                //                     coordinates = strings.split(coords_str, ":")
                //                     if len(coordinates) != 2 {
                //                         fmt.eprintf("Warning: Expected two coordinates but got {}\n", len(coordinates))
                //                         error.row = strconv.atoi(coordinates[0])
                //                         error.column = 0
                //                     } else {
                //                         error.row = strconv.atoi(coordinates[0])
                //                         error.column = strconv.atoi(coordinates[1])
                //                     }
                //                 }
                //             }
                //             error.message = strings.trim_left_space(compiler_output_lines[i][close_paren_index + 1:])
                //             fmt.sbprintf(&builder, "{}{}{}\n", ANSI_WHITE, error.message, ANSI_RESET)
                //             if compiler_output_lines[i + 1] != "" {
                //                 error.snippet = strings.trim_left_space(compiler_output_lines[i + 1])
                //                 if i + 2 < len(compiler_output_lines) {
                //                     error.carots[0] = strings.index_any(compiler_output_lines[i + 2], "^") - 1 + len(line_code_separator) + len(row_column_separator) + len(coordinates[0]) + len(coordinates[1])
                //                     error.carots[1] = strings.last_index_any(compiler_output_lines[i + 2], "^") - 1 + len(line_code_separator) + len(row_column_separator) + len(coordinates[0]) + len(coordinates[1])
                //                 } 
                //                 fmt.sbprintf(&builder, "{}{}\x1b[0m{}{}{}{}{}", ANSI_WHITE, error.row, ANSI_WHITE, row_column_separator, error.column, line_code_separator, ANSI_RESET)
                //                 for i := 0; i < len(error.snippet); i += 1 {
                //                     character := cast(rune)error.snippet[i]
                //                     fmt.sbprint(&builder, character)
                //                 }
                //                 fmt.sbprint(&builder, "\x1b[0m\n")
                //                 for i := 0; i <= error.carots[1]; i += 1 {
                //                     if i < error.carots[0] {
                //                         fmt.sbprintf(&builder, " ")
                //                     } else {
                //                         fmt.sbprintf(&builder, "{}{}\x1b[0m", ANSI_WHITE, "⠉")
                //                     }
                //                 }
                //                 fmt.sbprintf(&builder, "\n")
                //             }
                //         } else if strings.contains(compiler_output_lines[i], "Suggestion") && !strings.contains(compiler_output_lines[i], "Did you mean?") {
                //             fmt.sbprintf(&builder, "{}{}\x1b[0m\n", ANSI_WHITE, strings.trim_left_space(compiler_output_lines[i]))
                //             continue
                //         } else if strings.contains(compiler_output_lines[i], "Suggestion") && strings.contains_any(compiler_output_lines[i], "?") {
                //             parse_multiline_suggestions = true
                //             line_offset = 0
                //             continue
                //         }
                //         if parse_multiline_suggestions {
                //             for (i + line_offset < len(compiler_output_lines)) && (strings.index(compiler_output_lines[i + line_offset], ":/") != 1) {
                //                 append(&error.suggestions, strings.trim_left_space(compiler_output_lines[i + line_offset]))
                //                 line_offset += 1
                //             }
                //             fmt.sbprintf(&builder, "{}Suggestions: \x1b[0m", ANSI_WHITE)
                //             suggestion_line_length := 13
                //             for suggestion in error.suggestions {
                //                 if suggestion_line_length + len(suggestion) >= 80 {
                //                     fmt.sbprintf(&builder, "{}{}{}\n", ANSI_WHITE, suggestion, ANSI_RESET)
                //                     suggestion_line_length = 0
                //                 } else {
                //                     fmt.sbprintf(&builder, "{}{}{}", ANSI_WHITE, suggestion, ANSI_RESET)
                //                     suggestion_line_length += len(suggestion)
                //                 }
                //             }
                //             fmt.sbprint(&builder, "\x1b[0m")
                //             clear(&error.suggestions)
                //             parse_multiline_suggestions = false
                //             i += line_offset - 1
                //         }
                //     }
                //     fmt.eprintf("{}", strings.to_string(builder))
                //     strings.builder_reset(&builder)
                //     error = Error{}
                // }

                // Instead of custom formatting, simply dump the raw output unformatted.
                for {
                    bytes_read: windows.DWORD
                    if !windows.ReadFile(io_state.stderr.read_handle, &compilation_output_buffer[0], u32(len(compilation_output_buffer)), &bytes_read, nil) || bytes_read == 0 {
                        break
                    }
                    fmt.printf("%s", cast(string)compilation_output_buffer[:bytes_read])
                }

                if windows.WaitForSingleObject(process_state.process_information.hProcess, BLOCKING) != PROCESS_COMPLETED {
                    fmt.eprintf("\x1b[31mERROR: WaitForSingleObject (PROCESS_COMPLETED) failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                    break
                }

                if !windows.GetExitCodeProcess(process_state.process_information.hProcess, &exit_code) {
                    fmt.eprintf("\x1b[31mERROR: GetExitCodeProcess failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                } else if exit_code == 0 {
                    compiled = true  
                } else {
                    fmt.printf("\x1b[31mERROR: Compilation failed after {} ms with exit code {}\x1b[0m\n", time.tick_since(timer), exit_code)
                }
            }

            if compiled && !executing {
                // Build the full file path by joining the watch directory and event filename.
                full_filepath = strings.join({arg_info.watch_directory, filename}, "\\")
                // Extract the source directory from the full file path.
                source_dir = filepath.dir(full_filepath)
                // Extract only the base name from the event filename.
                base_filename := filepath.base(filename)
                // Remove the last 5 characters (".odin") to get the executable base name.
                exe_name := base_filename[:len(base_filename)-5]

                // Build the full path to the executable using the source directory.
                strings.builder_reset(&builder)
                fmt.sbprintf(&builder, "{}\\{}.exe", source_dir, exe_name)
                name := strings.to_string(builder)
                process_state.process_name = windows.utf8_to_wstring(name)

                // Create anonymous pipes for stdout and stderr.
                if windows.CreatePipe(&io_state.stdout.read_handle, &io_state.stdout.write_handle, &process_state.security_attributes, 0) {
                    process_state.startup_information.hStdOutput = io_state.stdout.write_handle
                } else {
                    fmt.eprintf("ERROR: CreatePipe for stdout failed. Last error: {}\n", windows.GetLastError())
                }

                if windows.CreatePipe(&io_state.stderr.read_handle, &io_state.stderr.write_handle, &process_state.security_attributes, 0) {
                    process_state.startup_information.hStdError = io_state.stderr.write_handle
                } else {
                    fmt.eprintf("ERROR: CreatePipe for stderr failed. Last error: {}\n", windows.GetLastError())
                }

                timer = time.tick_now()
                if windows.CreateProcessW(nil, process_state.process_name, nil, nil, windows.TRUE, process_state.creation_flags, nil, nil, &process_state.startup_information, &process_state.process_information) {
                    executing = true
                    fmt.printf("\x1b[34mINFO: Running process...\x1b[0m\n")
                    // Since the child inherits the write ends, close them in the parent.
                    close_handle(&io_state.stdout.write_handle)
                    close_handle(&io_state.stderr.write_handle)
                    close_handle(&process_state.process_information.hThread)
                } else {
                    fmt.eprintf("ERROR: CreateProcessW failed. Last error: {}\n", windows.GetLastError())
                    close_handle(&io_state.stdout.read_handle)
                    close_handle(&io_state.stdout.write_handle)
                    close_handle(&io_state.stderr.read_handle)
                    close_handle(&io_state.stderr.write_handle)
                }
            }
            queue_command = false
        }

        FSW_WATCHING_EVENTS : windows.DWORD : windows.FILE_NOTIFY_CHANGE_FILE_NAME | windows.FILE_NOTIFY_CHANGE_DIR_NAME  | windows.FILE_NOTIFY_CHANGE_LAST_WRITE
        if !windows.ReadDirectoryChangesW(watched_directory_handle, &buffer[0], u32(len(buffer)), true, FSW_WATCHING_EVENTS, nil, overlapped, nil) {
            fmt.eprintf("\x1b[31mERROR: ReadDirectoryChangesW failed after {} ms with exit code {}!\x1b[0m\n", time.tick_since(timer), exit_code)
        }

        /* Statusline work */

        // buf: [8]u8
        // now := time.now()
        // now_time_formatted := time.to_string_mm_dd_yy(now, buf[:])
        // strings.builder_reset(&builder)
        // fmt.sbprintf(&builder, "Watching %d  -  %d events processed  -  %s", 1, 2, now_time_formatted)
        // status := strings.to_string(builder)
        // strings.builder_reset(&builder)
        // draw_status_bar(status, console_state)

        // status_info : StatusInfo = {
        //     file_path   = "./main.odin",
        //     modified    = false,
        //     cursor_line = 42,
        //     cursor_col  = 7,
        //     total_lines = 424,
        // }
        // width, height := get_console_screen_buffer_dimensions(console_state.standard_output_handle)
        // status := build_status_line(status_info, width)
        // fmt.printf("\033[%d;1H\033[2K\033[47m\033[30m%s\033[0m", 10, status)
    }
}
