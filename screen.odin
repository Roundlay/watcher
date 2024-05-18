package main

import "core:runtime"
import "core:fmt"
import "core:mem"
import "core:time"
import "core:os"
import "core:sys/windows"

MAXCOLUMNS :: 488
MAXROWS    :: 100
MAXCELLS   :: MAXCOLUMNS * MAXROWS 

ANSI_CLEAR_SCREEN    :: "\x1b[2J"
ANSI_RESET          :: "\x1b[0m"
ANSI_MOVE_CURSOR_HOME :: "\x1b[H"
ANSI_SET_FG_BLACK     :: "\x1b[30m"
ANSI_SET_BG_WHITE     :: "\x1b[47m"

Colour :: enum u8 {
    Black,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    White,
    Transparent, // Added to represent transparent background
}

Rectangle :: struct {
    x, y, w, h: int,
}

Cell :: struct {
    ch: rune,
    fg: Colour,
    bg: Colour,
}

Stage :: struct {
    cells: [MAXCELLS]Cell,
    width, height: int,
}

Patch :: struct {
    cell: Cell,
    x, y: int,
}

frontstage : Stage
backstage : Stage

create_stage :: proc() {}
resize_stage :: proc() {}
clear_stage  :: proc() {}
diff_stage   :: proc() {}
patch_stage  :: proc() {}
reset_stage  :: proc() {}

row_start_index :: proc(row: int) -> int {
    return row * MAXCOLUMNS
}

cell_index :: proc(row, column: int) -> int {
    return (row * MAXCOLUMNS) + column
}
get_colour_escape_code :: proc(colour: Colour, is_foreground: bool) -> string {
    base_code := if is_foreground { 30 } else { 40 }
    colour_code := match colour {
        .Black     => base_code + 0,
        .Red       => base_code + 1,
        .Green     => base_code + 2,
        .Yellow    => base_code + 3,
        .Blue      => base_code + 4,
        .Magenta   => base_code + 5,
        .Cyan      => base_code + 6,
        .White     => base_code + 7,
        .Transparent => if is_foreground { 39 } else { 49 }, // Reset to default
    }
    return fmt.aprintf("\x1b[%dm", colour_code)
}

sanitise_input :: proc() {}
draw_cell      :: proc() {}
draw_cells     :: proc() {}

draw :: proc(stage: ^Stage) {
    // Move cursor to the home position
    fmt.printf("%s", ANSIMOVECURSORHOME)

    for y in 0 ..< stage.height {
        for x in 0 ..< stage.width {
            cell_index := y * stage.width + x
            cell := stage.cells[cell_index]

            // Set foreground and background colours
            fg_colour_code := get_colour_escape_code(cell.fg, true)
            bg_colour_code := get_colour_escape_code(cell.bg, false)

            // Apply colour codes and print the character
            fmt.printf("%s%s%c", fg_colour_code, bg_colour_code, cell.ch)
        }

        // Move to the beginning of the next line
        if y < stage.height - 1 {
            fmt.printf("\n")
        }
    }

    // Reset colours to defaults after rendering
    fmt.printf("%s", ANSIRESET)
}

main :: proc () {
    fmt.println("Hello, World!")

    h_out := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
    if h_out == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("ERROR: `h_out` is invalid: %v\n", windows.GetLastError())
        return
    }

    h_in := windows.GetStdHandle(windows.STD_INPUT_HANDLE)
    if h_in == windows.INVALID_HANDLE_VALUE {
        fmt.eprintf("ERROR: `h_in` is invalid: %v\n", windows.GetLastError())
        return
    }

    original_output_mode : windows.DWORD
    if !windows.GetConsoleMode(h_out, &original_output_mode) {
        fmt.eprintf("ERROR: `windows.GetConsoleMode` failed: %v\n", windows.GetLastError())
        return
    }

    original_input_mode : windows.DWORD
    if !windows.GetConsoleMode(h_in, &original_input_mode) {
        fmt.eprintf("ERROR: `windows.GetConsoleMode` failed: %v\n", windows.GetLastError())
        return
    }

    requested_output_mode : windows.DWORD = windows.ENABLE_WRAP_AT_EOL_OUTPUT | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING | windows.ENABLE_PROCESSED_OUTPUT
    output_mode : windows.DWORD = original_output_mode | requested_output_mode

    if !windows.SetConsoleMode(h_out, output_mode) {
        requested_output_mode = windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING
        output_mode = original_output_mode | requested_output_mode
        if !windows.SetConsoleMode(h_out, output_mode) {
            fmt.eprintf("Failed to set any VT mode, can't do anything here.\n")
            fmt.eprintf("ERROR: `windows.SetConsoleMode` failed for standard out: %v\n", windows.GetLastError())
            return
        }
    }

    requested_input_mode : windows.DWORD = windows.ENABLE_ECHO_INPUT | windows.ENABLE_LINE_INPUT | windows.ENABLE_WINDOW_INPUT | windows.ENABLE_PROCESSED_INPUT | windows.ENABLE_VIRTUAL_TERMINAL_INPUT
    input_mode  : windows.DWORD = original_input_mode  | requested_input_mode

    if !windows.SetConsoleMode(h_in, input_mode) {
        fmt.eprintf("ERROR: `windows.SetConsoleMode` failed for standard in: %v\n", windows.GetLastError())
        fmt.eprintf("Failed to set any VT mode, can't do anything here.\n")
        return
    }

    // Make sure that the console mode is reset no matter how we exit.
    defer windows.SetConsoleMode(h_out, original_output_mode);
    defer windows.SetConsoleMode(h_in, original_input_mode);

    // Get console screen buffer info
    csbi : windows.CONSOLE_SCREEN_BUFFER_INFO
    console_width, console_height : i16
    fmt.printf("CSBI: %v\n", csbi)
    if windows.GetConsoleScreenBufferInfo(h_out, &csbi) {
        console_width = csbi.dwSize.X
        fmt.printf("width: %d\n", console_width)
        console_height = csbi.dwSize.Y
        fmt.printf("height: %d\n", console_height)
    } else {
        fmt.eprintf("ERROR: `windows.GetConsoleScreenBufferInfo` failed: %v\n", windows.GetLastError())
        return
    }

    // Doesn't work, just implementation idea
    // frontstage : Stage
    // frontstage.width = int(console_width)
    // frontstage.height = int(console_height)
    // index := cell_index(10,5)
    // frontstage.cells[index] = Cell{'A', Colour.White, Colour.Black}

}
