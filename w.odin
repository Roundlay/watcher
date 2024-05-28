package main

import "core:os"
import "core:fmt"
import "core:mem"
import "core:time"
import "core:strings"
import "core:strconv"
import "core:sys/windows"
import "core:runtime"

ANSI_RESET :: "\x1b[0m"
ANSI_CLEAR :: "\x1b[2J"
ANSI_HOME  :: "\x1b[H"
BLOCKING    :: windows.INFINITE
NON_BLOCKING :: windows.DWORD(0)
PROCESS_COMPLETED :: windows.WAIT_OBJECT_0
PROCESS_RUNNING   :: windows.WAIT_TIMEOUT

// This works, as far as I can tell, but I don't know how to verify that
// everything is getting cleaned up yet.
should_terminate : bool = false
signal_handler :: proc "stdcall" (signal_type: windows.DWORD) -> windows.BOOL {
    context = runtime.default_context()
    if signal_type == windows.CTRL_C_EVENT {
        fmt.printf("Received CTRL_C_EVENT siganl.\n")
        should_terminate = true
    }
    return windows.TRUE
}

main :: proc() {
    fmt.printf("%s%s", ANSI_CLEAR, ANSI_HOME)

    // Display memory leaks when running the executable with the -debug flag.
    when ODIN_DEBUG {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        defer {
            if len(track.allocation_map) > 0 {
                fmt.eprintf("%v allocations not freed: \n", len(track.allocation_map))
                for _, entry in track.allocation_map {
                    fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
                }
            }
            if len(track.bad_free_array) > 0 {
                fmt.eprintf("%v incorrect frees: \n", len(track.bad_free_array))
                for entry in track.bad_free_array {
                    fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
                }
            }
            mem.tracking_allocator_destroy(&track)
        }
    }

    h_out := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    if h_out == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("ERROR: `h_out` is invalid: {}", windows.GetLastError())
        return
    }
    h_in := windows.GetStdHandle(windows.STD_INPUT_HANDLE)
    if h_in == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("ERROR: `h_in` is invalid: {}", windows.GetLastError())
        return
    }

    original_output_mode : windows.DWORD
    if !windows.GetConsoleMode(h_out, &original_output_mode) {
        fmt.eprintf("ERROR: `windows.GetConsoleMode` failed: {}", windows.GetLastError())
        return
    } else {
        fmt.printf("DEBUG: Original output mode: %b\n", original_output_mode)
    }

    original_input_mode : windows.DWORD
    if !windows.GetConsoleMode(h_in, &original_input_mode) {
        fmt.eprintf("ERROR: `windows.GetConsoleMode` failed: {}", windows.GetLastError())
        return
    } else {
        fmt.printf("DEBUG: Original input mode: %b\n", original_input_mode)
    }

    requested_output_mode : windows.DWORD = windows.ENABLE_WRAP_AT_EOL_OUTPUT | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING | windows.ENABLE_PROCESSED_OUTPUT
    output_mode : windows.DWORD = original_output_mode | requested_output_mode

    if !windows.SetConsoleMode(h_out, output_mode) {
        // We failed to set both modes, try to step down mode gracefully.
        output_mode = original_output_mode | requested_output_mode
        if !windows.SetConsoleMode(h_out, output_mode) {
            // Failed to set any VT mode, can't do anything here.
            fmt.eprintf("Failed to set any VT mode, can't do anything here.")
            fmt.eprintf("ERROR: `windows.SetConsoleMode` failed for standard out: {}", windows.GetLastError())
            return
        }
    } else {
        fmt.printf("DEBUG: Current output mode: %b\n", output_mode)
    }

    requested_input_mode : windows.DWORD = windows.ENABLE_ECHO_INPUT | windows.ENABLE_LINE_INPUT | windows.ENABLE_WINDOW_INPUT | windows.ENABLE_PROCESSED_INPUT | windows.ENABLE_VIRTUAL_TERMINAL_INPUT
    input_mode  : windows.DWORD = original_input_mode  | requested_input_mode

    if !windows.SetConsoleMode(h_in, input_mode) {
        fmt.eprintf("ERROR: `windows.SetConsoleMode` failed for standard in: {}", windows.GetLastError())
        fmt.eprintf("Failed to set any VT mode, can't do anything here.")
        return
    } else {
        fmt.printf("DEBUG: Current input_mode: %b\n", input_mode)
    }

    // Get console screen buffer info.
    csbi : windows.CONSOLE_SCREEN_BUFFER_INFO
    if !windows.GetConsoleScreenBufferInfo(h_out, &csbi) {
        fmt.eprintf("ERROR: `windows.GetConsoleScreenBufferInfo` failed: {}", windows.GetLastError())
        return
    }
    fmt.printf("DEBUG: Screen Buffer Size: %d x %d\n", csbi.dwSize.X, csbi.dwSize.Y)

    for i : i16 = 0; i < csbi.dwSize.X; i += 1 {
        fmt.printf("-")
    }
    fmt.printf("\n")

    // File System Watcher

    windows.SetConsoleCtrlHandler(signal_handler, windows.TRUE)

    io_completion_port_handle := windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, nil, nil, 1)
    if io_completion_port_handle == windows.INVALID_HANDLE_VALUE do return
    defer windows.CloseHandle(io_completion_port_handle)

    // Make sure to pass the full file path to the Odin compiler, otherwise the
    // watcher will always look for events in the same directory as the watcher
    // executable.

    // TODO: Make sure the target directory exists before trying to watch it.
    watched_directory : windows.wstring 
    filepath : string

    if len(os.args) > 1 {
        command_line_argument := os.args[1]

        file_info, file_info_error := os.lstat(command_line_argument)

        if file_info_error != 0 {
            fmt.println("ERROR: Invalid directory: {}", command_line_argument)
            return
        } else if !os.is_dir(file_info.fullpath) {
            fmt.println("ERROR: Not a directory: {}", command_line_argument)
            return
        }

        watched_directory = windows.utf8_to_wstring(os.args[1])
        fmt.printf("INFO: Watching user defined directory: {}\n", os.args[1])

        filepath = os.args[1]
        if strings.has_prefix(filepath, "\\\\?\\") {
            filepath = filepath[4:]
            fmt.printf("\x1b[34mINFO: Stripped prefix from long-filepath: {}\x1b[0m\n", filepath)
        }
    } else {
        watched_directory = windows.utf8_to_wstring(os.get_current_directory())
        fmt.printf("INFO: Watching root directory: {}\n", os.get_current_directory())

        filepath = os.get_current_directory()
        if strings.has_prefix(filepath, "\\\\?\\") {
            filepath = filepath[4:]
            fmt.printf("\x1b[34mINFO: Stripped prefix from long-filepath: {}\x1b[0m\n", filepath)
        }
    }

    watched_directory_handle : windows.HANDLE = windows.CreateFileW(watched_directory, windows.FILE_LIST_DIRECTORY, windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED, nil)
    if watched_directory_handle == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("ERROR: Handle to target directory is invalid: {}", windows.GetLastError())
        return
    }

    overlapped := new(windows.OVERLAPPED)

    ids := make([dynamic][3]any)
    id  := [3]any{overlapped, watched_directory_handle, watched_directory}
    append(&ids, id)

    defer {
        for id in ids {
            windows.CloseHandle(id[1].(windows.HANDLE))
            free(id[0].(^windows.OVERLAPPED))
        }
        delete(ids)
    }

    if windows.CreateIoCompletionPort(watched_directory_handle, io_completion_port_handle, cast(^uintptr)(&id), 1) == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("`windows.CreateIoCompletionPort` has an invalid watched_directory_handle value: {}", windows.GetLastError())
        return
    }

    // TODO - Document slash justify the choice of buffer size here. It was pulled out of thin air.
    buffer := make([]byte, 2048)
    defer delete(buffer)

    if windows.ReadDirectoryChangesW(watched_directory_handle, &buffer[0], u32(len(buffer)), true, windows.FILE_NOTIFY_CHANGE_FILE_NAME | windows.FILE_NOTIFY_CHANGE_DIR_NAME  | windows.FILE_NOTIFY_CHANGE_LAST_WRITE, nil, overlapped, nil) == windows.BOOL(false) {
        fmt.eprintf("`windows.ReadDirectoryChangesW` returned false or failed. Last error: {}", windows.GetLastError())
        return
    }

    // TODO - What's the point of putting all this in a struct?
    Metadata :: struct {
        startup_information     : windows.STARTUPINFOW,
        process_information     : windows.PROCESS_INFORMATION,
        security_attributes     : windows.SECURITY_ATTRIBUTES,
        running_process         : windows.HANDLE,
        output_read_handle      : windows.HANDLE,
        output_write_handle     : windows.HANDLE,
        error_read_handle       : windows.HANDLE,
        error_write_handle      : windows.HANDLE,
        creation_flags          : windows.DWORD,
        exit_code               : windows.DWORD,
        process_name            : windows.wstring,
    }

    metadata := Metadata {}

    metadata.startup_information.dwFlags        = windows.STARTF_USESTDHANDLES
    metadata.startup_information.hStdOutput     = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    metadata.startup_information.hStdError      = windows.GetStdHandle(windows.STD_ERROR_HANDLE)
    metadata.security_attributes.bInheritHandle = windows.TRUE
    metadata.security_attributes.nLength        = size_of(windows.SECURITY_ATTRIBUTES)
    metadata.creation_flags = windows.CREATE_NEW_PROCESS_GROUP | windows.CREATE_UNICODE_ENVIRONMENT

    process_output_overlapped := new(windows.OVERLAPPED)
    process_output_overlapped.hEvent = windows.CreateEventW(nil, windows.TRUE, windows.FALSE, nil)

    // Need to make sure the size of the buffer is pretty big if we want to start parsing and colouring the output.
    // 4096 supported about 76 lines of compiler output before it had to be resized.
    compilation_output_buffer := make([]u8, 4096 * 2)
    defer delete(compilation_output_buffer)

    builder, builder_error := strings.builder_make_len_cap(0, 512)
    defer strings.builder_destroy(&builder)

    compiled, executing : bool = false, false
    timer : time.Tick

    for {
        time.sleep(time.Millisecond * 1)

        if should_terminate {
            if watched_directory_handle != windows.INVALID_HANDLE_VALUE {
                windows.CloseHandle(watched_directory_handle)
                watched_directory_handle = windows.INVALID_HANDLE_VALUE
            }

            if io_completion_port_handle != windows.INVALID_HANDLE_VALUE {
                windows.CloseHandle(io_completion_port_handle)
                io_completion_port_handle = windows.INVALID_HANDLE_VALUE
            }

            // TODO: Close the process handle and terminate the process if it's still running
            if metadata.running_process != windows.INVALID_HANDLE_VALUE {
                windows.TerminateProcess(metadata.running_process, 1)
                windows.CloseHandle(metadata.running_process)
            }

            break
        }

        if !windows.GetConsoleScreenBufferInfo(h_out, &csbi) {
            fmt.eprintf("\x1b[31mERROR: `windows.GetConsoleScreenBufferInfo` failed: {}\x1b[0m\n", windows.GetLastError())
        }

        // TODO: Deal with programs that alter the console mode. We need to reset the console mode ourselves after every iteration through the file system watcher.
        if executing {
            bytes_read := windows.DWORD(0)

            output_buffer := make([]u8, 4096)
            defer delete(output_buffer)

            read_success := windows.ReadFile(metadata.output_read_handle, &output_buffer[0], u32(len(output_buffer)), &bytes_read, process_output_overlapped)
            if read_success {
                fmt.printf("%s", output_buffer[:bytes_read])
            } else {
                last_error := windows.GetLastError()
                if last_error == windows.ERROR_IO_PENDING {
                    if !windows.GetOverlappedResult(metadata.output_read_handle, process_output_overlapped, &bytes_read, windows.TRUE) {
                        fmt.eprintf("\x1b[31mERROR: GetOverlappedResult failed: {}\x1b[0m\n", windows.GetLastError())
                    } else {
                        fmt.printf("%s", output_buffer[:bytes_read])
                    }
                } else {
                    fmt.eprintf("\x1b[31mERROR: ReadFile failed: {}\x1b[0m\n", last_error)
                }
            }

            status_of_running_process := windows.WaitForSingleObject(metadata.running_process, 0)
            if status_of_running_process == PROCESS_COMPLETED {
                if windows.GetExitCodeProcess(metadata.running_process, &metadata.exit_code) {
                    if metadata.exit_code == 0 {
                        fmt.printf("\x1b[32mINFO: Process execution completed successfully in {} ms.\x1b[0m\n", time.tick_since(timer))
                    } else {
                        fmt.eprintf("\x1b[31mERROR: Process completed with non-zero exit code %d.\x1b[0m\n", metadata.exit_code)
                    }
                } else {
                    fmt.eprintf("\x1b[31mERROR: Failed to get exit code for process: %d\x1b[0m\n\n", windows.GetLastError())
                }

                metadata.process_information.hProcess = nil
                metadata.process_information.hThread = nil
                metadata.output_read_handle = nil
                metadata.error_read_handle = nil

                executing = false
                compiled = false
            }

            if !windows.SetConsoleMode(h_out, original_output_mode) {
                fmt.eprintf("\x1b[31mERROR: Failed to reset output console mode: {}\x1b[0m\n", windows.GetLastError())
            }

            if !windows.SetConsoleMode(h_in, original_input_mode) {
                fmt.eprintf("\x1b[31mERROR: Failed to reset input console mode: {}\x1b[0m\n", windows.GetLastError())
            }

            // Reset colours.
            fmt.printf("%s", ANSI_RESET)
        }

        number_of_bytes_transferred := windows.DWORD(0)

        if windows.GetQueuedCompletionStatus(io_completion_port_handle, &number_of_bytes_transferred, cast(uintptr)(&id), &overlapped, NON_BLOCKING) == windows.BOOL(false) {
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
        } else {
            // TODO: You should probably just put everything that follows in here?
            // Else file event detected.
            // fmt.printf("\x1b[32mINFO: Event detected.\x1b[0m\n")
        }

        notifications := (^windows.FILE_NOTIFY_INFORMATION)(&buffer[0])

        queue_command : bool = false

        filename := ""
        file_action_old_name := ""

        for {
            event_filename, event_filename_error := windows.wstring_to_utf8(&notifications.file_name[0], int(notifications.file_name_length) / 2)
            if strings.has_suffix(event_filename, ".obj") do break

            action := notifications.action

            // Vim creates a temporary file with the name '4913' every time
            // a file is saved to check if the directory is writable. It then
            // removes the file. There might be other telltale event signatures
            // associated with different editors that we can use to filter
            // out events that we don't care about or to identify the editor if
            // we want to display something in the UI.

            switch action {
                case windows.FILE_ACTION_ADDED:
                    if strings.contains(event_filename, "4913") do break
                    fmt.printf("\x1b[33mEVENT: Created {}\x1b[0m\n", event_filename)

                case windows.FILE_ACTION_REMOVED:
                    if strings.contains(event_filename, "4913") do break
                    fmt.printf("\x1b[33mEVENT: Removed {}\x1b[0m\n", event_filename)

                case windows.FILE_ACTION_MODIFIED:
                    fmt.printf("\x1b[33mEVENT: Modified {}\x1b[0m\n", event_filename)
                    if strings.has_suffix(event_filename, ".odin") {
                        // We don't just process the command here immediately because might want to log the other events that occur after the file is modified.
                        queue_command = true
                        filename = event_filename
                    }

                case windows.FILE_ACTION_RENAMED_OLD_NAME:
                    file_action_old_name = event_filename

                case windows.FILE_ACTION_RENAMED_NEW_NAME:
                    fmt.printf("\n\x1b[33mEVENT: Renamed {} to {}\x1b[0m\n", file_action_old_name, event_filename)

                case:
                    fmt.eprintf("\x1b[33m{} - Unknown action {}\x1b[0m\n", event_filename, action)
            }

            if notifications.next_entry_offset == 0 do break
            notifications = (^windows.FILE_NOTIFY_INFORMATION)(uintptr(notifications) + uintptr(notifications.next_entry_offset))
        }

        if queue_command {

            if metadata.running_process != windows.INVALID_HANDLE_VALUE {
                windows.TerminateProcess(metadata.running_process, 1)
                windows.CloseHandle(metadata.running_process)
                metadata.running_process = windows.INVALID_HANDLE_VALUE
            }

            compiled, executing = false, false

            // TODO: Don't hardcode extension length.
            strings.builder_reset(&builder) // Ensure the builder is reset before use
            fmt.sbprintf(&builder, "odin build {}\\{} -file -out:{}\\{}.exe", filepath, filename, filepath, filename[:len(filename)-5])
            command := strings.to_string(builder)
            fmt.printf("\x1b[34mTEST: Built compilation command: {}\x1b[0m\n", command)
            strings.builder_reset(&builder)

            // Compile the modified file using the filepath and compilation command
            Error :: struct {
                filepath, message, snippet, underline: string,
                row, column : int,
                coordinates, carots: [2]int,
                suggestions : [dynamic]string,
            }

            error: Error
            error.coordinates = {0, 0}
            error.carots = {0, 0}
            coordinates : []string

            if !compiled {
                defer {
                    windows.CloseHandle(metadata.error_write_handle)
                    windows.CloseHandle(metadata.error_read_handle)
                    windows.CloseHandle(metadata.running_process)
                }

                if !windows.CreatePipe(&metadata.error_read_handle, &metadata.error_write_handle, &metadata.security_attributes, 0) {
                    fmt.eprintf("\x1b[31mERROR: CreatePipe failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                    break
                }
                metadata.startup_information.hStdError = metadata.error_write_handle

                timer = time.tick_now()
                if !windows.CreateProcessW(nil, windows.utf8_to_wstring(command), nil, nil, windows.TRUE, metadata.creation_flags, nil, nil, &metadata.startup_information, &metadata.process_information) {
                        fmt.eprintf("\x1b[31mERROR: CreateProcessW failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                    break
                }
                metadata.running_process = metadata.process_information.hProcess
                windows.CloseHandle(metadata.process_information.hThread)
                windows.CloseHandle(metadata.error_write_handle)

                row_column_separator := ":"
                line_code_separator := " | "
                compiler_output : string
                parse_suggestions := false
                line_offeset := 0

                for {
                    bytes_read: windows.DWORD
                    if !windows.ReadFile(metadata.error_read_handle, &compilation_output_buffer[0], u32(len(compilation_output_buffer)), &bytes_read, nil) || bytes_read == 0 {
                        break
                    }

                    compiler_output = cast(string)compilation_output_buffer[:bytes_read]
                    compiler_output_lines := strings.split(compiler_output, "\n")

                    for i := 0; i <= len(compiler_output_lines) - 1; i += 1 {
                        if strings.index(compiler_output_lines[i], ":/") == 1 {
                            // error.filepath = strings.cut(compiler_output_lines[i], 0, strings.index(compiler_output_lines[i], "("))
                            error.filepath = strings.cut(compiler_output_lines[i], 0, strings.index(compiler_output_lines[i], "("))
                            segments := strings.split(error.filepath, "/")
                            short_filepath : string
                            if len(segments) > 2 {
                                short_filepath = strings.join(segments[len(segments)-3:], "/")
                            } else {
                                short_filepath = error.filepath
                            }

                            error.coordinates = {strings.index_any(compiler_output_lines[i], "(") + 1, strings.index_any(compiler_output_lines[i], ")")}
                            if error.coordinates[0] != -1 && error.coordinates[1] != -1 {
                                // coordinates_pair := compiler_output_lines[i][error.coordinates[0] : error.coordinates[1]]
                                coordinates = strings.split(compiler_output_lines[i][error.coordinates[0] : error.coordinates[1]], ":")

                                if len(coordinates) == 2 {
                                    error.row = strconv.atoi(coordinates[0])
                                    error.column = strconv.atoi(coordinates[1])
                                }
                            }
                            fmt.sbprintf(&builder, "\x1b[31m.../{}\x1b[0m\n", short_filepath)

                            error.message = strings.trim_left_space(compiler_output_lines[i][error.coordinates[1] + 1:])
                            fmt.sbprintf(&builder, "\x1b[31m{}\x1b[0m\n", error.message)

                            error.snippet = strings.trim_left_space(compiler_output_lines[i + 1])
                            // fmt.sbprintf(&builder, "\x1b[31m{}\x1b[0m\n", error.snippet)
                            fmt.sbprintf(&builder, "\x1b[31m{}{}{}{}{}\x1b[0m\n", error.row, row_column_separator, error.column, line_code_separator, error.snippet)
                            // same but black background with white text

                            error.carots[0] = strings.index_any(compiler_output_lines[i + 2], "^") - 1 + len(line_code_separator) + len(row_column_separator) + len(coordinates[0]) + len(coordinates[1])
                            error.carots[1] = strings.last_index_any(compiler_output_lines[i + 2], "^") - 1 + len(line_code_separator) + len(row_column_separator) + len(coordinates[0]) + len(coordinates[1])

                            for i in 0..=error.carots[1] {
                                if i < error.carots[0] {
                                    fmt.sbprintf(&builder, "\x1b[31m{}\x1b[0m", " ")
                                } else {
                                    fmt.sbprintf(&builder, "\x1b[31m{}\x1b[0m", "^")
                                }
                            }
                            fmt.sbprintf(&builder, "\n")

                        } else if strings.contains(compiler_output_lines[i], "Suggestion:") {
                            parse_suggestions = true

                        } else if parse_suggestions {
                            for strings.index(compiler_output_lines[i + line_offeset], ":/") != 1 {
                                append(&error.suggestions, strings.trim_left_space(compiler_output_lines[i + line_offeset]))
                                line_offeset += 1
                            }

                            for suggestion in error.suggestions {
                                fmt.sbprintf(&builder, "\x1b[33m{}\x1b[0m", suggestion)
                            }

                            fmt.sbprintf(&builder, "\n\n")
                            clear(&error.suggestions)
                            parse_suggestions = false
                        }
                    }

                    fmt.eprintf("\x1b[31m{}\x1b[0m\n", strings.to_string(builder))
                    strings.builder_reset(&builder)

                    error = Error{}

                    // compilation_output := string(compilation_output_buffer[:bytes_read])
                    // for line in strings.split_by_byte_iterator(&compilation_output, '\n') {
                    //     fmt.eprintf("\x1b[33m{}\x1b[0m\n", line)
                    // }

                    // fmt.printf(string(compilation_output_buffer[:bytes_read]))
                }
                
                if windows.WaitForSingleObject(metadata.running_process, BLOCKING) != PROCESS_COMPLETED {
                    fmt.eprintf("\x1b[31mERROR: WaitForSingleObject (PROCESS_COMPLETED) failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                    break
                }
                
                if !windows.GetExitCodeProcess(metadata.running_process, &metadata.exit_code) {
                    fmt.eprintf("\x1b[31mERROR: GetExitCodeProcess failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                } else if metadata.exit_code == 0 {
                    compiled = true  
                } else {
                    fmt.printf("\x1b[31mERROR: Compilation failed after {} ms with exit code {}\x1b[0m\n", time.tick_since(timer), metadata.exit_code)
                }
            }

            // Run the file that we just built

            if compiled && !executing {
                strings.builder_reset(&builder) // Ensure the builder is reset before use
                fmt.sbprintf(&builder, "{}\\{}.exe", filepath, filename[:len(filename)-5])
                process_name := strings.to_string(builder)
                metadata.process_name = windows.utf8_to_wstring(process_name)
                fmt.printf("\x1b[34mINFO: Attempting to run process: %s\x1b[0m\n", process_name)

                if windows.CreatePipe(&metadata.output_read_handle, &metadata.output_write_handle, &metadata.security_attributes, 0) {
                    metadata.startup_information.hStdOutput = metadata.output_write_handle
                }

                if windows.CreatePipe(&metadata.error_read_handle, &metadata.error_write_handle, &metadata.security_attributes, 0) {
                    metadata.startup_information.hStdError = metadata.error_write_handle
                }

                timer = time.tick_now()
                if windows.CreateProcessW(nil, metadata.process_name, nil, nil, windows.TRUE, metadata.creation_flags, nil, nil, &metadata.startup_information, &metadata.process_information) {
                    executing = true
                    fmt.printf("\x1b[34mINFO: Running process: %s\x1b[0m\n", process_name)
                    metadata.running_process = metadata.process_information.hProcess

                    // The child process (the compiled binary we execute here) inherits the write
                    // ends of the pipes (output_write_handle, error_write_handle). We close these
                    // handles in the parent process after creating the child process to avoid
                    // interfering with the child's ability to write to them.

                    // Cleanup write ends of pipes 
                    windows.CloseHandle(metadata.output_write_handle)
                    windows.CloseHandle(metadata.error_write_handle)

                    // Cleanup child process thread handle
                    windows.CloseHandle(metadata.process_information.hThread) 
                }
            }
            queue_command = false
        }

        FSW_WATCHING_EVENTS : windows.DWORD : windows.FILE_NOTIFY_CHANGE_FILE_NAME | windows.FILE_NOTIFY_CHANGE_DIR_NAME  | windows.FILE_NOTIFY_CHANGE_LAST_WRITE
        if !windows.ReadDirectoryChangesW(watched_directory_handle, &buffer[0], u32(len(buffer)), true, FSW_WATCHING_EVENTS, nil, overlapped, nil) {
            fmt.eprintf("\x1b[31mERROR: ReadDirectoryChangesW failed!\x1b[0m\n", time.tick_since(timer), metadata.exit_code)
        }
    }
}
