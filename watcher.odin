package watcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/windows"
import "core:time"
import "base:runtime"

/*
    FILE SYSTEM WATCHER
    
    A robust, single-file watcher for Windows using IOCP (ReadDirectoryChangesW).
    
    FEATURES:
    - Non-blocking IO (IOCP)
    - Zero-allocation hot loop (using temp_allocator)
    - Variable substitution ($file, $bin, $root)
    - Pattern matching rules
    - Auto-correction for Windows paths/quoting
*/

/*

    TODO

    - Test behavior with rapid file changes.

    1. Calling watcher shouldn't default to Odin build command. Without arguments it should do nothing and print usage. Easier to demand a directory to watch.

    2. Add verbose (--verbose or -v) flag that reports all the file system watcher events being detected even if they aren't relevant. This will allow someone to run e.g. watcher -w "..." -v and see all the file changes happening in that directory. That being said, if the user is only passing the watch folder they probably want to see all changes by default. So maybe if a watch folder and no rules are specified we default to verbose mode.

    3. Fix output text. Currently we output:

    """
    File Changed. Building...
    Restarting...
    """

    But this may be misleading if the user passes a command that has nothing to do with compiling code. We should just emit something that indicates that an even type corresponding to template matching occured and corresponding command is being executed.

*/

// --- Constants ---

ANSI_RESET :: "\x1b[0m"
ANSI_CLEAR :: "\x1b[2J"
ANSI_HOME  :: "\x1b[H"
ANSI_RED   :: "\x1b[31m"
ANSI_GREEN :: "\x1b[32m"
ANSI_BLUE  :: "\x1b[34m"
ANSI_CYAN  :: "\x1b[36m"
ANSI_WHITE :: "\x1b[37m"

STILL_ACTIVE :: windows.DWORD(259)

PIPE_BUFFER_CAPACITY :: 8192 * 8
FSW_BUFFER_SIZE      :: 4096 

// --- Data Structures ---

Rule :: struct {
    pattern : string,
    command : string,
}

Config :: struct {
    watch_dir   : string,
    watch_dir_w : windows.wstring,
    rules       : [dynamic]Rule,
}

ProcessState :: struct {
    h_process     : windows.HANDLE,
    h_thread      : windows.HANDLE,
    pipe_out_read : windows.HANDLE, 
    pipe_err_read : windows.HANDLE, 
    is_running    : bool,
    start_time    : time.Tick,
}

IOBuffers :: struct {
    fsw_buffer   : [FSW_BUFFER_SIZE]byte, 
    pipe_buffer  : [PIPE_BUFFER_CAPACITY]byte,
    overlapped   : windows.OVERLAPPED,
}

should_terminate := false

signal_handler :: proc "stdcall" (signal_type: windows.DWORD) -> windows.BOOL {
    if signal_type == windows.CTRL_C_EVENT {
        should_terminate = true
        return windows.TRUE
    }
    return windows.FALSE
}

// --- Helper Procedures ---

enable_vt_mode :: proc() {
    // Enables ANSI escape sequences on Windows Console
    handle := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    if handle == windows.INVALID_HANDLE_VALUE do return
    
    mode: windows.DWORD
    if !windows.GetConsoleMode(handle, &mode) do return
    
    mode |= windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING
    windows.SetConsoleMode(handle, mode)
}

close_handle_safe :: proc(handle: ^windows.HANDLE) {
    if handle^ != windows.INVALID_HANDLE_VALUE && handle^ != nil {
        windows.CloseHandle(handle^)
        handle^ = windows.INVALID_HANDLE_VALUE
    }
}

print_usage :: proc() {
    fmt.println("Watcher - High performance file system watcher")
    fmt.println("\nUsage:")
    fmt.println("  watcher [options]")
    fmt.println("\nOptions:")
    fmt.println("  -watch:<dir>   Directory to watch (default: current)")
    fmt.println("  -do:<rule>     Rule in format 'pattern:command'")
    fmt.println("\nVariables in Command:")
    fmt.println("  $file          Full path to changed file")
    fmt.println("  $bin           Full path without extension")
    fmt.println("  $root          Watch directory path")
    fmt.println("\nExamples:")
    fmt.println("  watcher")
    fmt.println("  watcher -do:\"*.odin:odin run '$file' -file\"")
    fmt.println("  watcher -do:\"*.c:cmd /C '$root\\build.bat' gcc\"")
}

parse_args :: proc() -> (Config, bool) {
    config := Config{
        watch_dir = os.get_current_directory(),
        rules     = make([dynamic]Rule),
    }
    
    watch_dir_explicit := false
    args := os.args

    if len(args) > 1 {
        for i := 1; i < len(args); i += 1 {
            arg := args[i]

            if arg == "-help" || arg == "-h" || arg == "/?" {
                print_usage()
                return config, false
            }
            
            if strings.has_prefix(arg, "-watch:") || strings.has_prefix(arg, "-w:") {
                val := strings.cut(arg, strings.index(arg, ":") + 1)
                if strings.has_suffix(val, "\"") {
                    val = val[:len(val)-1]
                }
                config.watch_dir = val
                watch_dir_explicit = true
                continue
            } 
            
            if strings.has_prefix(arg, "-do:") {
                val := strings.cut(arg, 4) 
                split_idx := -1
                for c, idx in val {
                    if c == ':' {
                        if idx == 1 && len(val) > 2 && (val[2] == '\\' || val[2] == '/') {
                            continue 
                        }
                        split_idx = idx
                        break
                    }
                }

                if split_idx > 0 {
                    raw_pattern := val[:split_idx]
                    cmd         := val[split_idx+1:]
                    
                    final_pattern := raw_pattern
                    if filepath.is_abs(raw_pattern) {
                        if !watch_dir_explicit {
                            config.watch_dir = filepath.dir(raw_pattern, context.temp_allocator)
                            watch_dir_explicit = true 
                        }
                        final_pattern = filepath.base(raw_pattern)
                    }
                    append(&config.rules, Rule{final_pattern, cmd})
                } else {
                    fmt.eprintfln("ERROR: Invalid rule format '%s'. Expected 'pattern:command'", val)
                    return config, false
                }
                continue
            }
        }
    }

    if len(config.rules) == 0 {
        append(&config.rules, Rule{"*.odin", "odin run '$file' -file"})
    }

    if !os.is_dir(config.watch_dir) {
        fmt.eprintfln("ERROR: Watch directory '%s' does not exist.", config.watch_dir)
        return config, false
    }
    
    if strings.has_prefix(config.watch_dir, "\\\\?\\") {
        config.watch_dir = config.watch_dir[4:]
    }

    config.watch_dir_w = windows.utf8_to_wstring(config.watch_dir)
    return config, true
}

terminate_current_process :: proc(p: ^ProcessState) {
    if p.h_process != windows.INVALID_HANDLE_VALUE {
        windows.TerminateProcess(p.h_process, 1)
        windows.WaitForSingleObject(p.h_process, windows.INFINITE) 
        close_handle_safe(&p.h_process)
    }
    close_handle_safe(&p.h_thread)
    close_handle_safe(&p.pipe_out_read)
    close_handle_safe(&p.pipe_err_read)
    p.is_running = false
}

drain_pipe :: proc(handle: windows.HANDLE, buffer: []byte) {
    if handle == windows.INVALID_HANDLE_VALUE do return
    bytes_read: windows.DWORD
    avail: windows.DWORD
    if windows.PeekNamedPipe(handle, nil, 0, nil, &avail, nil) && avail > 0 {
        if windows.ReadFile(handle, raw_data(buffer), u32(len(buffer)), &bytes_read, nil) {
            if bytes_read > 0 {
                os.write(os.stdout, buffer[:bytes_read])
            }
        }
    }
}

flush_pipe :: proc(handle: windows.HANDLE, buffer: []byte) {
    if handle == windows.INVALID_HANDLE_VALUE do return
    bytes_read: windows.DWORD
    for {
        if windows.ReadFile(handle, raw_data(buffer), u32(len(buffer)), &bytes_read, nil) {
            if bytes_read > 0 {
                os.write(os.stdout, buffer[:bytes_read])
            } else {
                break
            }
        } else {
            break
        }
    }
}

build_command :: proc(template: string, changed_file: string, root_dir: string) -> string {
    file_raw := changed_file
    ext := filepath.ext(changed_file)
    bin_raw := changed_file
    if len(ext) > 0 {
        bin_raw = changed_file[:len(changed_file)-len(ext)]
    }
    root_raw, _ := strings.replace_all(root_dir, "/", "\\", context.temp_allocator)

    cmd := template
    cmd, _ = strings.replace_all(cmd, "$file", file_raw, context.temp_allocator)
    cmd, _ = strings.replace_all(cmd, "$bin",  bin_raw,  context.temp_allocator)
    cmd, _ = strings.replace_all(cmd, "$root", root_raw, context.temp_allocator)
    cmd, _ = strings.replace_all(cmd, "'", "\"", context.temp_allocator)
    
    return cmd
}

main :: proc() {
    context.allocator = runtime.default_allocator()
    
    enable_vt_mode()
    windows.SetConsoleCtrlHandler(signal_handler, windows.TRUE)

    config, ok := parse_args()
    if !ok do return
    
    // Only clear screen if args were valid and we are starting
    fmt.print(ANSI_CLEAR, ANSI_HOME)

    dir_handle := windows.CreateFileW(
        config.watch_dir_w,
        windows.FILE_LIST_DIRECTORY,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        nil,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
        nil,
    )

    if dir_handle == windows.INVALID_HANDLE_VALUE {
        fmt.eprintln("Failed to open watch directory.")
        return
    }
    defer windows.CloseHandle(dir_handle)

    iocp_handle := windows.CreateIoCompletionPort(dir_handle, nil, 1, 1)
    if iocp_handle == windows.INVALID_HANDLE_VALUE {
        fmt.eprintln("Failed to create IOCP.")
        return
    }
    defer windows.CloseHandle(iocp_handle)

    proc_state := ProcessState{
        h_process     = windows.INVALID_HANDLE_VALUE,
        h_thread      = windows.INVALID_HANDLE_VALUE,
        pipe_out_read = windows.INVALID_HANDLE_VALUE,
        pipe_err_read = windows.INVALID_HANDLE_VALUE,
    }
    
    io_bufs := IOBuffers{}
    
    bytes_returned: windows.DWORD
    if !windows.ReadDirectoryChangesW(
        dir_handle, 
        &io_bufs.fsw_buffer[0], 
        u32(len(io_bufs.fsw_buffer)), 
        true, 
        windows.FILE_NOTIFY_CHANGE_LAST_WRITE | windows.FILE_NOTIFY_CHANGE_FILE_NAME, 
        &bytes_returned, 
        &io_bufs.overlapped, 
        nil,
    ) {
        fmt.eprintln("Initial ReadDirectoryChangesW failed.")
        return
    }

    fmt.printf("%sWatching: %s%s\n", ANSI_CYAN, config.watch_dir, ANSI_RESET)
    for rule, i in config.rules {
        fmt.printf("Rule %d: [%s] -> %s\n", i+1, rule.pattern, rule.command)
    }

    for !should_terminate {
        free_all(context.temp_allocator)
        
        if proc_state.is_running {
            drain_pipe(proc_state.pipe_out_read, io_bufs.pipe_buffer[:])
            drain_pipe(proc_state.pipe_err_read, io_bufs.pipe_buffer[:])

            exit_code: windows.DWORD
            if windows.GetExitCodeProcess(proc_state.h_process, &exit_code) {
                if exit_code != STILL_ACTIVE {
                    flush_pipe(proc_state.pipe_out_read, io_bufs.pipe_buffer[:])
                    flush_pipe(proc_state.pipe_err_read, io_bufs.pipe_buffer[:])

                    duration := time.tick_since(proc_state.start_time)
                    if exit_code == 0 {
                        fmt.printf("\n%sProcess finished successfully in %v%s\n", ANSI_GREEN, duration, ANSI_RESET)
                    } else {
                        fmt.printf("\n%sProcess failed with exit code %d in %v%s\n", ANSI_RED, exit_code, duration, ANSI_RESET)
                    }
                    terminate_current_process(&proc_state)
                }
            }
        }

        num_bytes: windows.DWORD
        key: uint
        ovlp: ^windows.OVERLAPPED

        status := windows.GetQueuedCompletionStatus(iocp_handle, &num_bytes, &key, &ovlp, 10)
        
        if bool(status) {
            if ovlp != nil && num_bytes > 0 {
                curr_offset := 0
                should_rebuild := false
                changed_file := ""
                selected_cmd := ""

                for {
                    info := (^windows.FILE_NOTIFY_INFORMATION)(&io_bufs.fsw_buffer[curr_offset])
                    wname := windows.wstring(&info.file_name[0])
                    fname, _ := windows.wstring_to_utf8(wname, int(info.file_name_length)/2, context.temp_allocator)

                    for rule in config.rules {
                        match_target := fname
                        if !strings.contains(rule.pattern, "/") && !strings.contains(rule.pattern, "\\") {
                            match_target = filepath.base(fname)
                        }

                        if matched, _ := filepath.match(rule.pattern, match_target); matched {
                            should_rebuild = true
                            changed_file = fname
                            selected_cmd = rule.command
                            break 
                        }
                    }

                    if should_rebuild do break
                    if info.next_entry_offset == 0 do break
                    curr_offset += int(info.next_entry_offset)
                }

                windows.ReadDirectoryChangesW(
                    dir_handle, 
                    &io_bufs.fsw_buffer[0], 
                    u32(len(io_bufs.fsw_buffer)), 
                    true, 
                    windows.FILE_NOTIFY_CHANGE_LAST_WRITE | windows.FILE_NOTIFY_CHANGE_FILE_NAME, 
                    nil, 
                    &io_bufs.overlapped, 
                    nil,
                )

                if should_rebuild {
                    if proc_state.is_running {
                        terminate_current_process(&proc_state)
                        fmt.println(ANSI_CYAN, "Restarting...", ANSI_RESET)
                    } else {
                        fmt.print(ANSI_CLEAR, ANSI_HOME)
                        fmt.println(ANSI_CYAN, "File Changed. Building...", ANSI_RESET)
                    }

                    sa := windows.SECURITY_ATTRIBUTES{ nLength = size_of(windows.SECURITY_ATTRIBUTES), bInheritHandle = true }
                    h_out_read, h_out_write, h_err_read, h_err_write: windows.HANDLE
                    
                    windows.CreatePipe(&h_out_read, &h_out_write, &sa, 0)
                    windows.CreatePipe(&h_err_read, &h_err_write, &sa, 0)
                    windows.SetHandleInformation(h_out_read, windows.HANDLE_FLAG_INHERIT, 0)
                    windows.SetHandleInformation(h_err_read, windows.HANDLE_FLAG_INHERIT, 0)

                    proc_state.pipe_out_read = h_out_read
                    proc_state.pipe_err_read = h_err_read

                    si := windows.STARTUPINFOW{
                        cb = size_of(windows.STARTUPINFOW),
                        dwFlags = windows.STARTF_USESTDHANDLES,
                        hStdOutput = h_out_write,
                        hStdError  = h_err_write,
                    }
                    pi := windows.PROCESS_INFORMATION{}

                    full_path := filepath.join({config.watch_dir, changed_file}, context.temp_allocator)
                    working_dir := config.watch_dir
                    
                    cmd_str := build_command(selected_cmd, full_path, config.watch_dir)
                    cmd_w   := windows.utf8_to_wstring(cmd_str, context.temp_allocator)
                    wd_w    := windows.utf8_to_wstring(working_dir, context.temp_allocator)

                    if windows.CreateProcessW(nil, cmd_w, nil, nil, true, windows.CREATE_NO_WINDOW | windows.CREATE_UNICODE_ENVIRONMENT, nil, wd_w, &si, &pi) {
                        proc_state.h_process = pi.hProcess
                        proc_state.h_thread  = pi.hThread
                        proc_state.is_running = true
                        proc_state.start_time = time.tick_now()
                        windows.CloseHandle(h_out_write)
                        windows.CloseHandle(h_err_write)
                    } else {
                        fmt.printf("%sFailed to start process: %d%s\n", ANSI_RED, windows.GetLastError(), ANSI_RESET)
                        close_handle_safe(&proc_state.pipe_out_read)
                        close_handle_safe(&proc_state.pipe_err_read)
                        windows.CloseHandle(h_out_write)
                        windows.CloseHandle(h_err_write)
                    }
                }
            }
        } else {
            err := windows.GetLastError()
            if err != windows.WAIT_TIMEOUT {
                // Handle unexpected errors
            }
        }
    }

    terminate_current_process(&proc_state)
}
