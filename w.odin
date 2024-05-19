// TODO - For testing purposes, let's make sure we handle cases where the watcher itself is updated and we attempt to compile and run it.
// We see something like this when we save the watcher program file itself:
// ```
// REN: w.odin to w.odin~
// ADD: w.odin
// MOD: w.odin
// REM: w.odin~
// INFO: Built filepath: C:\Users\Christopher\Projects\Advent\2023\
// INFO: Built compilation command: odin build C:\Users\Christopher\Projects\Advent\2023\w.odin -file -out:w.exe
// LINK : fatal error LNK1104: cannot open file 'C:\Users\Christopher\Projects\Advent\2023\w.exe'
// WARN: The compilation process completed with exit code 1104.
// INFO: Closing the compilation error write handle to signal no more data.
// INFO: Reading from compilation error pipe...
// ```
// It looks like we might be able to do something after the step with "INFO: Built compilation command: ..."
// However, when we save the file itself when it contains errors, we see those errors in the output as we expect.

// *TODO - Reports successful compilation when main_test.odin is saved and watched, however manually building the file yields numerous errors. Investigate.

package main

import "core:os"
import "core:fmt"
import "core:mem"
import "core:time"
import "core:strings"
import "core:sys/windows"
import "core:runtime"
import "core:io"
import "core:bufio"
import "core:path/filepath"

// TODO: Maybe try messing around with PeekNamedPipe to see if we can get
// the output of the process without blocking? Any benefit?

// NOTE: Do I need to call @(default_calling_convention="stdcall") on
// every foreign import?

// TODO: Document foreign imports and how they work.

// TODO: Deal with programs that alter the console mode. We need to reset the
// console mode ourselves after every iteration through the
// file system watcher.

foreign import kernel32 "system:kernel32.lib"
@(default_calling_convention="stdcall")
foreign kernel32 {
    PeekNamedPipe :: proc "stdcall" (hNamedPipe: windows.HANDLE, lpBuffer: ^u8, nBufferSize: windows.DWORD, lpBytesRead: ^windows.DWORD, lpTotalBytesAvail: ^windows.DWORD, lpBytesLeftThisMessage: ^windows.DWORD) -> windows.BOOL ---
}

ANSIRESET :: "\x1b[0m"
ANSICLEAR :: "\x1b[2J"
ANSIHOME  :: "\x1b[H"

BLOCKING    :: windows.INFINITE
NONBLOCKING :: windows.DWORD(0)

// This works, as far as I can tell, but I don't know how to verify that
// everything is getting cleaned up yet.
should_terminate : bool = false
signal_handler :: proc "stdcall" (signal_type: windows.DWORD) -> windows.BOOL {
    context = runtime.default_context()
    // CTRL_C_EVENT : DWORD : 0
    if signal_type == windows.CTRL_C_EVENT {
        fmt.printf("Received CTRL-C event.\n")
        should_terminate = true
    }
    return windows.TRUE
}

main :: proc() {

    fmt.printf("\x1b[2J") // Clear the console window when the program starts.
    fmt.printf("\x1b[1;1H") // Move the cursor to column 0 when the program starts.

    // TODO:
    // -------------------------------------------------------------------------

    // Memory Tracking
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

    // -------------------------------------------------------------------------

    // TUI

    // TODO: Refactor presentation into renderer.
    // TODO: Step down gracefully when the user terminates the program.
    // TODO: Step down gracefully when the program closes.
    // NOTE: Disabled for now; Muratori says that SetConsoleMode is slow.

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
        fmt.printf("original_output_mode: %b\n", original_output_mode)
    }

    original_input_mode : windows.DWORD
    if !windows.GetConsoleMode(h_in, &original_input_mode) {
        fmt.eprintf("ERROR: `windows.GetConsoleMode` failed: {}", windows.GetLastError())
        return
    } else {
        fmt.printf("original_input_mode: %b\n", original_input_mode)
    }

    requested_output_mode : windows.DWORD = windows.ENABLE_WRAP_AT_EOL_OUTPUT | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING | windows.ENABLE_PROCESSED_OUTPUT
    output_mode : windows.DWORD = original_output_mode | requested_output_mode

    if !windows.SetConsoleMode(h_out, output_mode) {
        // We failed to set both modes, try to step down mode gracefully.

        // requested_output_mode = windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING
        output_mode = original_output_mode | requested_output_mode
        if !windows.SetConsoleMode(h_out, output_mode) {
            // Failed to set any VT mode, can't do anything here.
            fmt.eprintf("Failed to set any VT mode, can't do anything here.")
            fmt.eprintf("ERROR: `windows.SetConsoleMode` failed for standard out: {}", windows.GetLastError())
            return
        }
    } else {
        fmt.printf("DEBUG: output_mode: %b\n", output_mode)
    }

    requested_input_mode : windows.DWORD = windows.ENABLE_ECHO_INPUT | windows.ENABLE_LINE_INPUT | windows.ENABLE_WINDOW_INPUT | windows.ENABLE_PROCESSED_INPUT | windows.ENABLE_VIRTUAL_TERMINAL_INPUT
    input_mode  : windows.DWORD = original_input_mode  | requested_input_mode

    if !windows.SetConsoleMode(h_in, input_mode) {
        fmt.eprintf("ERROR: `windows.SetConsoleMode` failed for standard in: {}", windows.GetLastError())
        fmt.eprintf("Failed to set any VT mode, can't do anything here.")
        return
    } else {
        fmt.printf("DEBUG: input_mode: %b\n", input_mode)
    }

    // Get console screen buffer info.
    csbi : windows.CONSOLE_SCREEN_BUFFER_INFO
    if !windows.GetConsoleScreenBufferInfo(h_out, &csbi) {
        fmt.eprintf("ERROR: `windows.GetConsoleScreenBufferInfo` failed: {}", windows.GetLastError())
        return
    }
    fmt.printf("Console Screen Buffer Size: %d x %d\n", csbi.dwSize.X, csbi.dwSize.Y)

    for i : i16 = 0; i < csbi.dwSize.X; i += 1 {
        fmt.printf("-")
    }
    fmt.printf("\n")

    // File System Watcher
    // -------------------------------------------------------------------------

    // Set up the signal handler for graceful shutdown.
    windows.SetConsoleCtrlHandler(signal_handler, windows.TRUE)

    io_completion_port_handle := windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, nil, nil, 1)
    if io_completion_port_handle == windows.INVALID_HANDLE_VALUE do return
    defer windows.CloseHandle(io_completion_port_handle)

    // Make sure to pass the full file path to the Odin compiler, otherwise the
    // watcher will always look for events in the same directory as the watcher
    // executable.
    // ** TODO: Make sure the target directory is passed to the filename builder.
    // TODO: Make sure the target directory exists before trying to watch it.

    watched_directory : windows.wstring 

    if len(os.args) > 1 {
        temp_watched_directory := os.args[1]
        file_info, file_info_error := os.lstat(temp_watched_directory)
        if file_info_error != 0 {
            fmt.println("ERROR: Invalid directory: {}", temp_watched_directory)
            return
        } else if !os.is_dir(file_info.fullpath) {
            fmt.println("ERROR: Not a directory: {}", temp_watched_directory)
            return
        }
        watched_directory = windows.utf8_to_wstring(os.args[1])
        fmt.printf("INFO: Watching directory: {}\n", os.args[1])
    } else {
        watched_directory = windows.utf8_to_wstring(os.get_current_directory())
    }

    watched_directory_handle : windows.HANDLE = windows.CreateFileW(watched_directory, windows.FILE_LIST_DIRECTORY, windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED, nil)
    if watched_directory_handle == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("ERROR: Handle to target directory is invalid: {}", windows.GetLastError())
        return
    }

    // TODO - How do we clear up overlapped?
    overlapped := new(windows.OVERLAPPED)

    // Each ID below is freed but does the handle also need to be yeeted?
    // Something something we actaully need to keep this alive the whole time
    // for Windows?

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
    buffer := make([]byte, 16 * 1024)
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

    // TODO - You were trying to wrap your head around Muratori's fast pipes thing from refterm.
    fast_pipe_name : windows.wstring
    fast_pipe : windows.HANDLE

    compiled, executing : bool = false, false
    timer : time.Tick

    process_output_overlapped := new(windows.OVERLAPPED)
    process_output_overlapped.hEvent = windows.CreateEventW(nil, windows.TRUE, windows.FALSE, nil)

    compilation_output_buffer := make([]u8, 4096)
    defer delete(compilation_output_buffer)

    for {
        // Prevents the CPU from getting rustled.
        time.sleep(time.Millisecond * 1)

        // TODO - Make sure this is cleaning everything up properly; we may not need to do this manually.
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

        // TODO - Finish rendering overhaul.
        // Get the size of the console window every loop.
        if !windows.GetConsoleScreenBufferInfo(h_out, &csbi) {
            fmt.eprintf("ERROR: `windows.GetConsoleScreenBufferInfo` failed: {}", windows.GetLastError())
            return
        }

        if executing {
            bytes_read : windows.DWORD

            output_buffer := make([]u8, 4096)
            defer delete(output_buffer)

            read_success := windows.ReadFile(metadata.output_read_handle, &output_buffer[0], u32(len(output_buffer)), &bytes_read, process_output_overlapped)

            if !read_success {
                last_error := windows.GetLastError()
                if last_error != windows.ERROR_IO_PENDING {
                    fmt.eprintf("ERROR: ReadFile failed: %d\n", last_error)
                } else {
                    bytes_read := windows.DWORD(0)
                    if !windows.GetOverlappedResult(metadata.output_read_handle, process_output_overlapped, &bytes_read, windows.TRUE) {
                        fmt.eprintf("ERROR: GetOverlappedResult failed: %d\n", windows.GetLastError())
                    } else {
                        fmt.printf("%s", output_buffer[:bytes_read])
                    }
                }
            } else {
                fmt.printf("%s", output_buffer[:bytes_read])
            }

            status_of_running_process := windows.WaitForSingleObject(metadata.running_process, 0)
            if status_of_running_process == windows.WAIT_OBJECT_0 { // Process has finished
                if windows.GetExitCodeProcess(metadata.running_process, &metadata.exit_code) {
                    if metadata.exit_code == 0 {
                        fmt.printf("\n")
                        fmt.printf("Process execution completed successfully in {} ms.\n", time.tick_since(timer))
                    } else {
                        fmt.eprintf("Process completed with non-zero exit code %d.\n", metadata.exit_code)
                    }
                } else {
                    fmt.eprintf("Failed to get exit code for process: %d\n", windows.GetLastError())
                }

                if metadata.running_process != nil {
                    windows.CloseHandle(metadata.running_process)
                    metadata.running_process = nil
                }

                if metadata.process_information.hProcess != nil {
                    windows.CloseHandle(metadata.process_information.hProcess)
                    metadata.process_information.hProcess = nil
                }

                if metadata.process_information.hThread != nil {
                    windows.CloseHandle(metadata.process_information.hThread)
                    metadata.process_information.hThread = nil
                }

                if metadata.process_information.dwProcessId != windows.DWORD(0) {
                    metadata.process_information.dwProcessId = windows.DWORD(0)
                }

                if metadata.process_information.dwThreadId != windows.DWORD(0) {
                    metadata.process_information.dwThreadId = windows.DWORD(0)
                }

                // Close and reset output and error handles
                if metadata.output_read_handle != windows.INVALID_HANDLE_VALUE {
                    windows.CloseHandle(metadata.output_read_handle)
                    metadata.output_read_handle = nil
                }
                if metadata.error_read_handle != windows.INVALID_HANDLE_VALUE {
                    windows.CloseHandle(metadata.error_read_handle)
                    metadata.error_read_handle = nil
                }

                // Reset flags
                executing = false
                compiled = false
            }

            if !windows.SetConsoleMode(h_out, original_output_mode) {
                fmt.eprintf("Failed to reset output console mode: {}", windows.GetLastError())
            }

            if !windows.SetConsoleMode(h_in, original_input_mode) {
                fmt.eprintf("Failed to reset input console mode: {}", windows.GetLastError())
            }

            // fmt.printf("DEBUG: Printing all Metadata elements:\n%.*s\n", metadata)

            // Reset colours.
            fmt.printf("\033[0m")

            for i : i16 = 0; i < csbi.dwSize.X; i += 1 {
                fmt.printf("-")
            }
            fmt.printf("\n")
        }

        number_of_bytes_transferred := windows.DWORD(0)

        if windows.GetQueuedCompletionStatus(io_completion_port_handle, &number_of_bytes_transferred, cast(uintptr)(&id), &overlapped, NONBLOCKING) == windows.BOOL(false) {
            last_error := windows.GetLastError()
            switch last_error {
                case windows.WAIT_TIMEOUT:
                    continue
                case windows.ERROR_OPERATION_ABORTED:
                    continue
                case:
                    fmt.eprintf("ERROR: `windows.GetQueuedCompletionStatus` returned false. Last error: {}.\n", last_error)
                    break
            }
        } else {
            // Else file event detected.
            // You should probably just put everything that follows in here?
        }

        notifications := (^windows.FILE_NOTIFY_INFORMATION)(&buffer[0])
        queue_command : bool = false
        filename : string = ""
        file_action_old_name : string

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

            // TODO:
            // Make sure filename, file_action_old_name, and event_filename are not being appended to but rather are being overwritten.
            // Debugger indicates the values are being appended to.
            // `0x18999fa5155 -> "d1_2023.odind1_2023.odin~\\\\\?\\C:\\Users\\Christopher\\Projects\\Advent\\2023"`

            switch action {
                case windows.FILE_ACTION_ADDED:
                    if event_filename == "4913" do break
                    if strings.has_suffix(event_filename, ".obj") do break
                    fmt.printf("ADD: {}\n", event_filename)
                case windows.FILE_ACTION_REMOVED:
                    if event_filename == "4913" do break
                    fmt.printf("REM: {}\n", event_filename)
                case windows.FILE_ACTION_MODIFIED:
                    fmt.printf("MOD: {}\n", event_filename)
                    if strings.has_suffix(event_filename, ".odin") {
                        // We don't just process the command here immediately
                        // because might want to log the other events that occur
                        // after the file is modified.
                        queue_command = true
                        filename = event_filename
                    }
                case windows.FILE_ACTION_RENAMED_OLD_NAME:
                    file_action_old_name = event_filename
                case windows.FILE_ACTION_RENAMED_NEW_NAME:
                    fmt.printf("REN: {} to {}\n", file_action_old_name, event_filename)
                case:
                    fmt.eprintf("{} - Unknown action {} \n", event_filename, action)
            }

            if notifications.next_entry_offset == 0 do break
            notifications = (^windows.FILE_NOTIFY_INFORMATION)(uintptr(notifications) + uintptr(notifications.next_entry_offset))
        }

        if queue_command == true {

            if metadata.running_process != windows.INVALID_HANDLE_VALUE {
                windows.TerminateProcess(metadata.running_process, 1)
                windows.CloseHandle(metadata.running_process)
                metadata.running_process = windows.INVALID_HANDLE_VALUE
            }

            compiled, executing = false, false

            // Build the filepath to the file that was modified.
            // TODO: Pretty sure we could just append the filename to the
            // directory path instead of doing all this, but you know.

            filepath_builder := strings.builder_make()
            defer strings.builder_destroy(&filepath_builder)

            filepath_buffer : [512]u16
            filepath_buffer_length : u32 = 512
            filepath_length : windows.DWORD = windows.GetFinalPathNameByHandleW(watched_directory_handle, &filepath_buffer[0], filepath_buffer_length, 0)
            filepath, filepath_error := windows.wstring_to_utf8(&filepath_buffer[0], -1)

            if strings.has_prefix(filepath, "\\\\?\\") {
                strings.write_string(&filepath_builder, filepath[4:])
                strings.write_string(&filepath_builder, "\\")
            } else {
                strings.write_string(&filepath_builder, filepath)
                strings.write_string(&filepath_builder, "\\")
            }

            filepath = strings.to_string(filepath_builder)
            fmt.printf("Built filepath: {}\n", filepath)

            strings.builder_reset(&filepath_builder)

            // Build the compilation command

            // TODO: Here too we could probably just bake our commands into
            // a variable or define them in a template file and plug the
            // filepath and filename into the template. I guess this way we can
            // arbitrarily change the command based on the file extension we
            // detect, so that we could for e.g. compile Odin, then C, then...

            command_builder, command_builder_error := strings.builder_make_len_cap(0, 2048)
            defer strings.builder_destroy(&command_builder)

            if command_builder_error != nil {
                fmt.printf("Error creating string builder: {}\n", command_builder_error)
                return
            }

            command_prefix : string = "odin build "
            command_suffix : string = " -file"
            command_output : string = " -out:"
            process_suffix : string = ".exe"

            strings.write_string(&command_builder, command_prefix)
            strings.write_string(&command_builder, filepath)
            strings.write_string(&command_builder, filename)
            strings.write_string(&command_builder, command_suffix)
            strings.write_string(&command_builder, command_output)
            strings.write_string(&command_builder, filename[:len(filename)-5])
            strings.write_string(&command_builder, process_suffix)

            command := strings.to_string(command_builder)
            compilation_command := windows.utf8_to_wstring(command)
            fmt.printf("Built compilation command: {}\n", command)

            strings.builder_reset(&command_builder)

            // COMPILE STEP
            fmt.printf("[1] Starting compile step.\n")

            if !compiled {
                fmt.printf("[2] Compilation not done yet. Starting pipe creation.\n")

                if windows.CreatePipe(&metadata.error_read_handle, &metadata.error_write_handle, &metadata.security_attributes, 0) {
                    fmt.printf("[3] Pipe creation successful. Error read handle: {}, Error write handle: {}\n", metadata.error_read_handle, metadata.error_write_handle)
                    metadata.startup_information.hStdError = metadata.error_write_handle
                } else {
                    fmt.eprintf("[4] Failed to create standard error handles for the compilation process. Last error: {}\n", windows.GetLastError())
                }

                timer = time.tick_now()
                fmt.printf("[5] Starting process creation with command: {}\n", compilation_command)
                if !windows.CreateProcessW(nil, compilation_command, nil, nil, windows.TRUE, metadata.creation_flags, nil, nil, &metadata.startup_information, &metadata.process_information) {
                    fmt.eprintf("[6] Failed to create process during compilation step: {}\n", windows.GetLastError())

                    if metadata.error_write_handle != windows.INVALID_HANDLE_VALUE {
                        fmt.printf("[7] Closing error write handle due to process creation failure.\n")
                        windows.CloseHandle(metadata.error_write_handle)
                    }
                    if metadata.error_read_handle != windows.INVALID_HANDLE_VALUE {
                        fmt.printf("[8] Closing error read handle due to process creation failure.\n")
                        windows.CloseHandle(metadata.error_read_handle)
                    }

                    metadata.running_process = nil
                    fmt.printf("[9] Exiting compile step due to process creation failure.\n")
                    return
                }

                fmt.printf("[10] Process creation successful. Process handle: {}, Thread handle: {}\n", metadata.process_information.hProcess, metadata.process_information.hThread)
                windows.CloseHandle(metadata.process_information.hThread)
                metadata.process_information.hThread = nil
                metadata.running_process = metadata.process_information.hProcess

                // Initialize variables for non-blocking read
                bytes_read: windows.DWORD
                total_bytes_avail: windows.DWORD
                bytes_left_this_message: windows.DWORD
                compilation_output_buffer := make([]u8, 1024) // Smaller buffer size for quicker reads

                // Read in a loop while waiting for the process to finish
                fmt.printf("[11] Starting loop to read error output and wait for process completion.\n")
                for {
                    // Non-blocking wait with a short timeout
                    status_of_compilation_process := windows.WaitForSingleObject(metadata.running_process, 100) // 100ms timeout
                    if status_of_compilation_process == windows.WAIT_OBJECT_0 {
                        fmt.printf("[12] Compilation process completed. Retrieving exit code.\n")
                        break
                    } else if status_of_compilation_process == windows.WAIT_TIMEOUT {
                        // Continue to read from the error pipe using PeekNamedPipe
                        if PeekNamedPipe(metadata.error_read_handle, nil, 0, nil, &total_bytes_avail, &bytes_left_this_message) {
                            if total_bytes_avail > 0 {
                                fmt.printf("[13] Data available in error pipe. Attempting to read.\n")
                                if windows.ReadFile(metadata.error_read_handle, &compilation_output_buffer[0], u32(len(compilation_output_buffer)), &bytes_read, nil) {
                                    fmt.printf("[15] Bytes read: {}\n", bytes_read)
                                    fmt.printf("[16] Compilation output buffer as string:\n{}", cast(string)compilation_output_buffer[:bytes_read])
                                } else {
                                    fmt.printf("[14] ReadFile failed or no more data. Breaking out of read loop.\n")
                                    break
                                }
                            }
                        } else {
                            fmt.eprintf("[18] PeekNamedPipe failed. Last error: {}\n", windows.GetLastError())
                            break
                        }
                    } else {
                        fmt.printf("[17] WaitForSingleObject returned unexpected value: {}. Exiting loop.\n", status_of_compilation_process)
                        break
                    }
                }

                // Ensure all remaining error output is read
                fmt.printf("[18] Final read from compilation error pipe...\n")
                for true {
                    if PeekNamedPipe(metadata.error_read_handle, nil, 0, nil, &total_bytes_avail, &bytes_left_this_message) && total_bytes_avail > 0 {
                        fmt.printf("[19] Attempting to read from error read handle: {}\n", metadata.error_read_handle)
                        if windows.ReadFile(metadata.error_read_handle, &compilation_output_buffer[0], u32(len(compilation_output_buffer)), &bytes_read, nil) {
                            if bytes_read > 0 {
                                fmt.printf("[21] Bytes read: {}\n", bytes_read)
                                fmt.printf("[22] Compilation output buffer as string:\n{}", cast(string)compilation_output_buffer[:bytes_read])
                            } else {
                                fmt.printf("[23] No more data to read.\n")
                                break
                            }
                        } else {
                            fmt.printf("[20] ReadFile failed or no more data. Breaking out of read loop.\n")
                            break
                        }
                    } else {
                        fmt.printf("[24] No data available in error pipe. Exiting loop.\n")
                        break
                    }
                }

                if windows.GetExitCodeProcess(metadata.process_information.hProcess, &metadata.exit_code) {
                    fmt.printf("[25] Exit code retrieval successful. Exit code: {}\n", metadata.exit_code)
                    if metadata.exit_code == 0 {
                        fmt.printf("[26] Compilation process completed successfully in {} ms.\n", time.tick_since(timer))
                        compiled = true
                    } else {
                        fmt.eprintf("[27] The compilation process failed in {} ms with exit code %d.\n", time.tick_since(timer), metadata.exit_code)
                    }
                } else {
                    fmt.eprintf("[28] Failed to get exit code of process. Last error: %d\n", windows.GetLastError())
                }

                if metadata.error_write_handle != windows.INVALID_HANDLE_VALUE {
                    fmt.eprintf("[29] Closing the compilation error write handle to signal no more data.\n")
                    windows.CloseHandle(metadata.error_write_handle)
                    metadata.error_write_handle = windows.INVALID_HANDLE_VALUE
                }

                if metadata.error_read_handle != windows.INVALID_HANDLE_VALUE {
                    fmt.printf("[30] Closing error read handle after reading error output.\n")
                    windows.CloseHandle(metadata.error_read_handle)
                    metadata.error_read_handle = windows.INVALID_HANDLE_VALUE
                }

                if metadata.running_process != nil {
                    fmt.printf("[31] Closing running process handle after error output reading.\n")
                    windows.CloseHandle(metadata.running_process)
                    metadata.running_process = nil
                }

                metadata.process_information.hProcess = nil
                metadata.process_information.hThread = nil
            }

            fmt.printf("[32] Compile step completed. Executing.\n")

            // Run the compiled file

            if compiled && !executing {
                process_name := filename[:len(filename)-5]
                metadata.process_name = windows.utf8_to_wstring(process_name)
                fmt.printf("Attempting to run process: `%s`.\n", process_name)

                if windows.CreatePipe(&metadata.output_read_handle, &metadata.output_write_handle, &metadata.security_attributes, 0) {
                    metadata.startup_information.hStdOutput = metadata.output_write_handle
                } else {
                }

                if windows.CreatePipe(&metadata.error_read_handle, &metadata.error_write_handle, &metadata.security_attributes, 0) {
                    metadata.startup_information.hStdError = metadata.error_write_handle
                } else {
                }

                timer = time.tick_now()
                fmt.printf("~\n")
                if windows.CreateProcessW(nil, metadata.process_name, nil, nil, windows.TRUE, metadata.creation_flags, nil, nil, &metadata.startup_information, &metadata.process_information) {
                    executing = true
                    // fmt.printf("INFO: Running process: `%s`.\n", process_name)
                    metadata.running_process = metadata.process_information.hProcess

                    windows.CloseHandle(metadata.process_information.hThread)
                    windows.CloseHandle(metadata.output_write_handle)
                    windows.CloseHandle(metadata.error_write_handle)

                    metadata.output_write_handle = windows.INVALID_HANDLE_VALUE
                    metadata.error_write_handle = windows.INVALID_HANDLE_VALUE
                }
            }
            queue_command = false
        }

        FSW_WATCHING_EVENTS : windows.DWORD : windows.FILE_NOTIFY_CHANGE_FILE_NAME | windows.FILE_NOTIFY_CHANGE_DIR_NAME  | windows.FILE_NOTIFY_CHANGE_LAST_WRITE
        if !windows.ReadDirectoryChangesW(watched_directory_handle, &buffer[0], u32(len(buffer)), true, FSW_WATCHING_EVENTS, nil, overlapped, nil) {
            fmt.eprintf("ReadDirectoryChangesW failed! \n")
        }
    }
}
