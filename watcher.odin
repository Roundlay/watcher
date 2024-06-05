// TODO: Need to implement queing system that can handle infinite loops and programs that open a window...

package watcher

import "core:os"
import "core:fmt"
import "core:mem"
import "core:time"
import "core:strings"
import "base:runtime"
import "core:strconv"
import "core:sys/windows"
// import "core:math/rand"

ANSI_OPEN :: "\x1b["
ANSI_RESET :: "\x1b[0m"
ANSI_CLEAR :: "\x1b[2J"
ANSI_HOME  :: "\x1b[H"

ANSI_032C :: "\x1b[38;2;237;41;57m"
ANSI_032C_BOLD :: "\x1b[38;2;237;41;57;1m"
ANSI_CANDIED_GINGER :: "\x1b[38;2;191;163;135m"
ANSI_PERSIAN_ORANGE :: "\x1b[38;2;197;141;101m"
ANSI_ANTIQUE_WHITE:: "\x1b[38;2;214;210;196m"

BLOCKING    :: windows.INFINITE
NON_BLOCKING :: windows.DWORD(0)

PROCESS_COMPLETED :: windows.WAIT_OBJECT_0
PROCESS_RUNNING   :: windows.WAIT_TIMEOUT

// TODO: Verify that everything is terminated properly.
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

    // Enables UTF-8 output and input processing.
    windows.SetConsoleOutputCP(windows.CP_UTF8)

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
    // csbi : windows.CONSOLE_SCREEN_BUFFER_INFO
    // if !windows.GetConsoleScreenBufferInfo(h_out, &csbi) {
    //     fmt.eprintf("ERROR: `windows.GetConsoleScreenBufferInfo` failed: {}", windows.GetLastError())
    //     return
    // }
    // fmt.printf("DEBUG: Screen Buffer Size: %d x %d\n", csbi.dwSize.X, csbi.dwSize.Y)

    // File System Watcher
    // -------------------------------------------------------------------------

    windows.SetConsoleCtrlHandler(signal_handler, windows.TRUE)

    // NOTE: When creating an I/O completion port without associating it with a
    // file handle (i.e. by passing `windows.INVALID_HANDLE_VALUE` as the first
    // argument) the completion key is ignored, so we use 0 for the completion
    // key value for simplicity.

    null_completion_key : uint = 0
    io_completion_port_handle := windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, nil, null_completion_key, 1)
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

        watched_directory = windows.utf8_to_wstring(command_line_argument)
        fmt.printf("INFO: Watching user defined directory: {}\n", command_line_argument)

        filepath = command_line_argument
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

    // TODO: This `id` array is redundant if we're manually creating completion
    // keys. Passing the pointer to the start of an array as the completion key
    // might be useful later on if we decide to watch multiple directories at
    // once or something. That's what the `id` array was originally for.

    // ids := make([dynamic][3]any)
    // id  := [3]any{overlapped, watched_directory_handle, watched_directory}
    // append(&ids, id)
    //
    // defer {
    //     for id in ids {
    //         windows.CloseHandle(id[1].(windows.HANDLE))
    //         free(id[0].(^windows.OVERLAPPED))
    //     }
    //     delete(ids)
    // }

    // [X] 2024/06/05: TODO: Why does this not work all of a sudden?
    // NOTE: The CompletionKey argument required by CreateIoCompletionPort is
    // essentially just that, some key that has some meaning to you that you can
    // use to identify the completion port when you get a completion
    // packet back. We can't direclty cast a windows.HANDLE typed variable
    // to uint, so we have to cast it to uintptr first, and then cast it to uint
    // in the function call.

    completion_key := cast(uintptr)watched_directory_handle
    if windows.CreateIoCompletionPort(watched_directory_handle, io_completion_port_handle, cast(uint)completion_key, 1) == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("`windows.CreateIoCompletionPort` has an invalid watched_directory_handle value: {}", windows.GetLastError())
        return
    }

    // TODO: Document slash justify slash test thie limits of the choice of buffer size here.
    buffer := make([]byte, 2048)
    defer delete(buffer)

    if windows.ReadDirectoryChangesW(watched_directory_handle, &buffer[0], u32(len(buffer)), true, windows.FILE_NOTIFY_CHANGE_FILE_NAME | windows.FILE_NOTIFY_CHANGE_DIR_NAME  | windows.FILE_NOTIFY_CHANGE_LAST_WRITE, nil, overlapped, nil) == windows.BOOL(false) {
        fmt.eprintf("`windows.ReadDirectoryChangesW` returned false or failed. Last error: {}", windows.GetLastError())
        return
    }

    // TODO: What's the point of putting all this in a struct?
    // TOOD: Clean up the struct or throw it out.
    Metadata :: struct {
        // startup_information     : windows.STARTUPINFOW,
        // process_information     : windows.PROCESS_INFORMATION,
        // security_attributes     : windows.SECURITY_ATTRIBUTES,
        // running_process         : windows.HANDLE,
        // creation_flags          : windows.DWORD,
        output_read_handle      : windows.HANDLE,
        output_write_handle     : windows.HANDLE,
        error_read_handle       : windows.HANDLE,
        error_write_handle      : windows.HANDLE,
        exit_code               : windows.DWORD,
        process_name            : windows.wstring,
    }

    metadata := Metadata {}

    startup_information : windows.STARTUPINFOW
    startup_information.dwFlags = windows.STARTF_USESTDHANDLES
    startup_information.hStdOutput = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    startup_information.hStdError = windows.GetStdHandle(windows.STD_ERROR_HANDLE)

    process_information : windows.PROCESS_INFORMATION

    creation_flags : windows.DWORD = windows.CREATE_NEW_PROCESS_GROUP | windows.CREATE_UNICODE_ENVIRONMENT

    security_attributes : windows.SECURITY_ATTRIBUTES
    security_attributes.bInheritHandle = windows.TRUE
    security_attributes.nLength = size_of(windows.SECURITY_ATTRIBUTES)

    running_process : windows.HANDLE

    process_output_overlapped := new(windows.OVERLAPPED)
    process_output_overlapped.hEvent = windows.CreateEventW(nil, windows.TRUE, windows.FALSE, nil)

    // Need to make sure the size of the buffer is pretty big if we want to start parsing and colouring the output.
    // 4096 supported about 76 lines of compiler output before it had to be resized.
    // Can we get this small enough to fit in the cache?
    compilation_output_buffer := make([]u8, 4096 * 2)
    defer delete(compilation_output_buffer)

    builder, builder_error := strings.builder_make_len_cap(0, 512)
    defer strings.builder_destroy(&builder)

    compiled, executing : bool = false, false
    timer : time.Tick

    for {
        // Prevent the CPU from getting rustled.
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
            if running_process != windows.INVALID_HANDLE_VALUE {
                windows.TerminateProcess(running_process, 1)
                windows.CloseHandle(running_process)
            }

            break
        }

        // In case we want to do anything relative to the console window size.
        // if !windows.GetConsoleScreenBufferInfo(h_out, &csbi) {
        //     fmt.eprintf("\x1b[31mERROR: `windows.GetConsoleScreenBufferInfo` failed: {}\x1b[0m\n", windows.GetLastError())
        // }

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
                }
            }

            status_of_running_process := windows.WaitForSingleObject(running_process, 0)
            if status_of_running_process == PROCESS_COMPLETED {
                if windows.GetExitCodeProcess(running_process, &metadata.exit_code) {
                    if metadata.exit_code == 0 {
                        fmt.printf("\x1b[32mINFO: Process execution completed successfully in {} ms.\x1b[0m\n", time.tick_since(timer))
                    } else {
                        fmt.eprintf("\x1b[31mERROR: Process completed with non-zero exit code %d.\x1b[0m\n", metadata.exit_code)
                    }
                } else {
                    fmt.eprintf("\x1b[31mERROR: Failed to get exit code for process: %d\x1b[0m\n\n", windows.GetLastError())
                }

                process_information.hProcess = nil
                process_information.hThread = nil
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

            // Reset colours when we switch back to the console
            fmt.printf("%s", ANSI_RESET)
        }

        number_of_bytes_transferred := windows.DWORD(0)


        // TODO: Refactor this; we want to pass the same completion key that we create earlier if we can.
        lp_completion_key : uint = 0
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
        } else {
            // TODO: You should probably just put everything that follows in here?
            // Else file event detected
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

            if running_process != windows.INVALID_HANDLE_VALUE {
                windows.TerminateProcess(running_process, 1)
                windows.CloseHandle(running_process)
                running_process = windows.INVALID_HANDLE_VALUE
            }

            compiled, executing = false, false

            // TODO: Don't hardcode extension length.
            strings.builder_reset(&builder) // Ensure the builder is reset before use
            fmt.sbprintf(&builder, "odin build {}\\{} -file -out:{}\\{}.exe", filepath, filename, filepath, filename[:len(filename)-5])
            command := strings.to_string(builder)
            fmt.printf("\x1b[34mINFO: Built compilation command: {}\x1b[0m\n", command)
            strings.builder_reset(&builder)

            // Compile the modified file using the filepath and compilation command

            // TODO: Can likely factor some of these out and just determine these on the fly, especially for coordinates and carots.
            // I.e. you have to create a separate coordinates variable later anyway.
            Error :: struct {
                filepath, message, snippet, underline: string,
                row, column : int,
                coordinates, carots: [2]int,
                suggestions : [dynamic]string,
            }

            error: Error

            compiler_output : string = ""
            parse_multiline_suggestions : bool = false

            line_offset := 0

            row_column_separator := ":"
            line_code_separator := " | "

            if !compiled {
                defer {
                    windows.CloseHandle(metadata.error_write_handle)
                    windows.CloseHandle(metadata.error_read_handle)
                    windows.CloseHandle(running_process)
                }

                if !windows.CreatePipe(&metadata.error_read_handle, &metadata.error_write_handle, &security_attributes, 0) {
                    fmt.eprintf("\x1b[31mERROR: CreatePipe failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                    break
                }
                startup_information.hStdError = metadata.error_write_handle

                timer = time.tick_now()
                if !windows.CreateProcessW(nil, windows.utf8_to_wstring(command), nil, nil, windows.TRUE, creation_flags, nil, nil, &startup_information, &process_information) {
                        fmt.eprintf("\x1b[31mERROR: CreateProcessW failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                    break
                }
                running_process = process_information.hProcess
                windows.CloseHandle(process_information.hThread)
                windows.CloseHandle(metadata.error_write_handle)


                for {
                    bytes_read: windows.DWORD
                    if !windows.ReadFile(metadata.error_read_handle, &compilation_output_buffer[0], u32(len(compilation_output_buffer)), &bytes_read, nil) || bytes_read == 0 {
                        break
                    }

                    compiler_output = cast(string)compilation_output_buffer[:bytes_read]
                    compiler_output_lines := strings.split(compiler_output, "\n")
                    coordinates : []string

                    fmt.sbprint(&builder, "\n")

                    for i := 0; i < len(compiler_output_lines); i += 1 {
                        if strings.index(compiler_output_lines[i], ":/") == 1 {
                            filepath_segments := strings.split(strings.cut(compiler_output_lines[i], 0, strings.index(compiler_output_lines[i], "(")), "/")
                            error.filepath = strings.join(filepath_segments[len(filepath_segments) - 4:], "/")
                            fmt.sbprintf(&builder, "\x1b[38;2;237;237;237m.../{}\x1b[0m\n", error.filepath)

                            error.coordinates = {strings.index_any(compiler_output_lines[i], "(") + 1, strings.index_any(compiler_output_lines[i], ")")}
                            coordinates = strings.split(compiler_output_lines[i][error.coordinates[0] : error.coordinates[1]], ":")
                            error.row = strconv.atoi(coordinates[0])
                            error.column = strconv.atoi(coordinates[1])

                            error.message = strings.trim_left_space(compiler_output_lines[i][error.coordinates[1] + 1:])
                            // fmt.sbprintf(&builder, "\x1b[38;2;237;41;57m{}\x1b[0m\n", error.message)
                            fmt.sbprintf(&builder, "\x1b[38;2;237;237;237;1m{}\x1b[0m\n", error.message)

                            error.snippet = strings.trim_left_space(compiler_output_lines[i + 1])

                            error.carots[0] = strings.index_any(compiler_output_lines[i + 2], "^") - 1 + len(line_code_separator) + len(row_column_separator) + len(coordinates[0]) + len(coordinates[1])
                            error.carots[1] = strings.last_index_any(compiler_output_lines[i + 2], "^") - 1 + len(line_code_separator) + len(row_column_separator) + len(coordinates[0]) + len(coordinates[1])

                            // Highlight the error region in the snippet itself.

                            // The exit code is left open because we don't know precisely where we'll start highlighting the error in the snippet.
                            fmt.sbprintf(&builder, "\x1b[38;2;237;237;237;1m{}\x1b[0m\x1b[38;2;237;237;237m{}{}{}", error.row, row_column_separator, error.column, line_code_separator)

                            // Tried adding random colours to the row and column numbers to make errors more distinguishable.

                            // random_red := rand.uint32() % 255
                            // random_green := rand.uint32() % 255
                            // random_blue := rand.uint32() % 255
                            // fmt.sbprintf(&builder, "\x1b[38;2;{};{};{}m{}\x1b[0m{}\x1b[38;2;{};{};{}m{}\x1b[0m\x1b[38;2;237;41;57m{}", random_red, random_green, random_blue, error.row, row_column_separator, random_red, random_green, random_blue, error.column, line_code_separator)

                            for i in 0..<len(error.snippet) {
                                character := cast(rune)error.snippet[i]
                                if i == error.carots[0] - len(row_column_separator) - len(line_code_separator) - len(coordinates[0]) - len(coordinates[1]) {
                                    // When we reach the start of the error we complete the exit code for normal text and start the inverted color effect.
                                    fmt.sbprintf(&builder, "\x1b[0m\x1b[38;2;237;237;237m{}", character)

                                } else if i == error.carots[1] - len(row_column_separator) - len(line_code_separator) - len(coordinates[0]) - len(coordinates[1]) {
                                    // We close the inverted color effect and open the normal color effect exit code.
                                    fmt.sbprintf(&builder, "{}\x1b[0m\x1b[38;2;237;237;237m", character)
                                } else {
                                    fmt.sbprint(&builder, character)
                                }
                            }

                            // Finally we close the normal color effect exit code.
                            fmt.sbprint(&builder, "\x1b[0m\n")

                            for i in 0..=error.carots[1] {
                                if i < error.carots[0] {
                                    fmt.sbprintf(&builder, "{}", " ")
                                } else {
                                    fmt.sbprintf(&builder, "\x1b[38;2;237;41;57m{}\x1b[0m", "⠉")
                                }
                            }

                            fmt.sbprintf(&builder, "\n")

                        } else if strings.contains(compiler_output_lines[i], "Suggestion") && !strings.contains_any(compiler_output_lines[i], "?") {
                            fmt.sbprintf(&builder, "\x1b[38;2;237;237;237m{}\x1b[0m\n\n", strings.trim_left_space(compiler_output_lines[i]))

                        } else if strings.contains(compiler_output_lines[i], "Suggestion") && strings.contains_any(compiler_output_lines[i], "?") {
                            parse_multiline_suggestions = true
                            line_offset = 0

                        // * TODO: This isn't working. This correctly handles the suggestions in the first error, but errors that follow don't have their suggestions parsed. Instead, all we see is 'Suggestions: ' then nothing.
                        } else if parse_multiline_suggestions {
                            for i + line_offset < len(compiler_output_lines) && strings.index(compiler_output_lines[i + line_offset], ":/") != 1 {
                                append(&error.suggestions, strings.trim_left_space(compiler_output_lines[i + line_offset]))
                                line_offset += 1
                            }

                            fmt.sbprintf(&builder, "{}Suggestions: \x1b[0m", "\x1b[38;2;255;255;255m")

                            // We start with a suggestion line length of 13 because that's the length of the "Suggestions: " string.
                            suggestion_line_length := 13
                            for suggestion in error.suggestions {
                                if suggestion_line_length + len(suggestion) >= 80 {
                                    fmt.sbprintf(&builder, "{}{}\x1b[0m\n", "\x1b[38;2;255;255;255m", suggestion)
                                    suggestion_line_length = 0
                                } else {
                                    fmt.sbprintf(&builder, "{}{}\x1b[0m", "\x1b[38;2;255;255;255m", suggestion)
                                    suggestion_line_length += len(suggestion) + 1
                                }
                                fmt.sbprint(&builder, "\x1b[0m")
                            }

                            fmt.sbprintf(&builder, "\n\n")
                            clear(&error.suggestions)
                            parse_multiline_suggestions = false
                        }
                    }

                    fmt.eprintf("\x1b[31m{}\x1b[0m", strings.to_string(builder))
                    strings.builder_reset(&builder)

                    error = Error{}

                    /*
                    compilation_output := string(compilation_output_buffer[:bytes_read])
                    for line in strings.split_by_byte_iterator(&compilation_output, '\n') {
                        fmt.eprintf("\x1b[33m{}\x1b[0m\n", line)
                    }
                    // fmt.printf(string(compilation_output_buffer[:bytes_read]))
                    */

                }
                
                if windows.WaitForSingleObject(running_process, BLOCKING) != PROCESS_COMPLETED {
                    fmt.eprintf("\x1b[31mERROR: WaitForSingleObject (PROCESS_COMPLETED) failed. Last error: {}\x1b[0m\n", windows.GetLastError())
                    break
                }
                
                if !windows.GetExitCodeProcess(running_process, &metadata.exit_code) {
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

                if windows.CreatePipe(&metadata.output_read_handle, &metadata.output_write_handle, &security_attributes, 0) {
                    startup_information.hStdOutput = metadata.output_write_handle
                }

                if windows.CreatePipe(&metadata.error_read_handle, &metadata.error_write_handle, &security_attributes, 0) {
                    startup_information.hStdError = metadata.error_write_handle
                }

                timer = time.tick_now()
                if windows.CreateProcessW(nil, metadata.process_name, nil, nil, windows.TRUE, creation_flags, nil, nil, &startup_information, &process_information) {
                    executing = true
                    fmt.printf("\x1b[34mINFO: Running process: %s\x1b[0m\n", process_name)
                    running_process = process_information.hProcess

                    // The child process (the compiled binary we execute here) inherits the write
                    // ends of the pipes (output_write_handle, error_write_handle). We close these
                    // handles in the parent process after creating the child process to avoid
                    // interfering with the child's ability to write to them.

                    // Cleanup write ends of pipes 
                    windows.CloseHandle(metadata.output_write_handle)
                    windows.CloseHandle(metadata.error_write_handle)

                    // Cleanup child process thread handle
                    windows.CloseHandle(process_information.hThread) 
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