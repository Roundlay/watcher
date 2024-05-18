package main

import "core:fmt"
import "core:os"
import "core:math/rand"
import "core:sys/windows"
import "core:runtime"


SCREEN_WIDTH :: 80
SCREEN_HEIGHT :: 25
MAX_HEIGHT :: 512 
MAX_WIDTH :: 1024
RUNE_SIZE :: 4
INT_SIZE :: 8
BYTES_PER_ROW :: SCREEN_WIDTH / RUNE_SIZE
ROWS_PER_COLUMN :: SCREEN_HEIGHT / RUNE_SIZE

Colour :: enum u8 {
    Black, Red, Green, Yellow, Blue, Magenta, Cyan, White, Transparent,
}

// Represents a single cell in the drawable region
Cell :: struct {
    ch: rune,
    fg, bg: Colour,
}

// Adapted Stage struct with static buffer size
Stage :: struct {
    buffer: [MAX_HEIGHT][MAX_WIDTH]Cell,
    offsetX, offsetY: int, // Offsets for rendering
    columns, rows: int, // Current console dimensions
}

// Represents a single cell that requires patching
Patch :: struct {
    cell: Cell,
    x, y: int,
}

// Example procedure to update console dimensions and calculate offsets
update_console_dimensions :: proc(stage: ^Stage, consoleWidth: int, consoleHeight: int) {
    stage.columns = consoleWidth
    stage.rows = consoleHeight
    // Calculate offsets based on the difference between the maximum buffer size and the current console size
    stage.offsetX = (MAX_WIDTH - consoleWidth) / 2
    stage.offsetY = (MAX_HEIGHT - consoleHeight) / 2
}

initialise_stage :: proc(stage: ^Stage, width, height: int) {
    stage.columns = width
    stage.rows = height
    for y := 0; y < height; y += 1 {
        for x := 0; x < width; x += 1 {
            if (x + y) % 2 == 0 {
                stage.buffer[y][x] = Cell{'#', Colour.White, Colour.Black}
            } else {
                stage.buffer[y][x] = Cell{' ', Colour.White, Colour.Black}
            }
        }
    }
}

compare_difference :: proc(frontstage, backstage: ^Stage) -> ([dynamic]Patch, bool) {
    patches: [dynamic]Patch
    for y := 0; y < frontstage.rows; y += 1 {
        for x := 0; x < frontstage.columns; x += 1 {
            if frontstage.buffer[y][x] != backstage.buffer[y][x] {
                patch := Patch{frontstage.buffer[y][x], x, y}
                append(&patches, patch)
            }
        }
    }
    return patches, len(patches) > 0
}

set_pixel :: proc(stage: ^Stage, pixel: Patch) {
    if pixel.x < 0 || pixel.x >= stage.columns || pixel.y < 0 || pixel.y >= stage.rows {
        fmt.println("Pixel position out of bounds")
        return
    }
    stage.buffer[pixel.y][pixel.x] = pixel.cell
}

patch_pixels :: proc(stage: ^Stage, patches: [dynamic]Patch) {
    for patch in patches {
        set_pixel(stage, patch)
    }
}

clear_screen :: proc() {
    fmt.print("\x1b[2J\x1b[H")  // Clear screen and move cursor to home position
}

set_cursor_position :: proc(x, y: int) {
    fmt.printf("\x1b[%d;%dH", y + 1, x + 1)
}

render_patches :: proc(stage: ^Stage, patches: [dynamic]Patch) {
    for patch in patches {
        // Directly set the pixel without redundant escape code generation
        set_pixel(stage, patch)
        
        // Move cursor and print the updated cell
        set_cursor_position(patch.x, patch.y)
        cell := patch.cell
        fmt.printf("\x1b[38;5;%dm\x1b[48;5;%dm%c\x1b[0m", cell.fg, cell.bg, cell.ch)
    }
}

set_colour :: proc(colour: Colour, is_foreground: bool) {
    base_code : int

    if is_foreground {
        base_code = 30
    } else {
        base_code = 40
    }

    colour_code : int

    switch colour {
        case .Black:
        colour_code = base_code + 0
        case .Red:
        colour_code = base_code + 1
        case .Green:
        colour_code = base_code + 2
        case .Yellow:
        colour_code = base_code + 3
        case .Blue:
        colour_code = base_code + 4
        case .Magenta:
        colour_code = base_code + 5
        case .Cyan:
        colour_code = base_code + 6
        case .White:
        colour_code = base_code + 7
        case .Transparent:
        if is_foreground {
            colour_code = 39
        } else {
            colour_code = 49
        }
        case:
            colour_code = 0
    }

    fmt.printf("\x1b[%dm", colour_code)
}

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

// // White noise generator within the console dimensions
// generate_white_noise :: proc(stage: ^Stage) {
//     // Seed the random number generator for white noise
//     rand.set_global_seed(8)
//     noise_chars := []rune{'#', '%', '&', '*', '+', '-', '.', '/'}
//
//     for y := 0; y < stage.rows; y += 1 {
//         for x := 0; x < stage.columns; x += 1 {
//             // Randomly select a character from noise_chars
//             noise_char := rand.choice(noise_chars)
//             // noise_char := noise_chars[char_index]
//
//             // Set the cell to the random noise character with random foreground color
//             color_index := rand.choice([]Colour{Colour.Red, Colour.Green, Colour.Blue, Colour.Yellow, Colour.Magenta, Colour.Cyan, Colour.White})
//             stage.cells[y*stage.columns + x] = Cell{noise_char, Colour(color_index), Colour.Black}
//         }
//     }
// }

main :: proc () {

    // SET UP CONSOLE

    // Need to do this without VT Codes. See: https://github.com/cmuratori/refterm/blob/main/faq.md

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

    // ENABLE_INSERT_MODE 0x0020
    // When enabled, text entered in a console window will be inserted at the current cursor location and all text following that location will not be overwritten. When disabled, all following text will be overwritten.
    // Note: Could this be used to render stuff?

    // requested_input_mode : windows.DWORD = windows.ENABLE_ECHO_INPUT | windows.ENABLE_LINE_INPUT | windows.ENABLE_WINDOW_INPUT | windows.ENABLE_PROCESSED_INPUT | windows.ENABLE_VIRTUAL_TERMINAL_INPUT
    requested_input_mode : windows.DWORD = windows.ENABLE_ECHO_INPUT | windows.ENABLE_LINE_INPUT | windows.ENABLE_WINDOW_INPUT | windows.ENABLE_PROCESSED_INPUT
    input_mode  : windows.DWORD = original_input_mode  | requested_input_mode
    if !windows.SetConsoleMode(h_in, input_mode) {
        fmt.eprintf("ERROR: `windows.SetConsoleMode` failed for standard in: %v\n", windows.GetLastError())
        fmt.eprintf("Failed to set any VT mode, can't do anything here.\n")
        return
    }

    // requested_output_mode : windows.DWORD = windows.ENABLE_WRAP_AT_EOL_OUTPUT | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING | windows.ENABLE_PROCESSED_OUTPUT
    requested_output_mode : windows.DWORD = windows.ENABLE_WRAP_AT_EOL_OUTPUT | windows.ENABLE_PROCESSED_OUTPUT
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
    // Make sure that the console mode is reset no matter how we exit.
    defer windows.SetConsoleMode(h_out, original_output_mode);
    defer windows.SetConsoleMode(h_in, original_input_mode);
    defer clear_screen()

    // Get the console dimensions so that we can adapt the stage to the console no matter the size.
    console_width, console_height : int

    csbi : windows.CONSOLE_SCREEN_BUFFER_INFO
    if windows.GetConsoleScreenBufferInfo(h_out, &csbi) {
        console_width = int(csbi.dwSize.X)
        console_height = int(csbi.dwSize.Y)
    } else {
        fmt.eprintf("ERROR: `windows.GetConsoleScreenBufferInfo` failed: %v\n", windows.GetLastError())
        return
    }

    front_buffer : Stage
    back_buffer : Stage
    // front_buffer.columns = SCREEN_WIDTH
    // front_buffer.rows = SCREEN_HEIGHT
    // back_buffer.columns = SCREEN_WIDTH
    // back_buffer.rows = SCREEN_HEIGHT

    // Initialize front_buffer with checkerboard pattern
    // for y := 0; y < SCREEN_HEIGHT; y += 1 {
    //     for x := 0; x < SCREEN_WIDTH; x += 1 {
    //         if (x + y) % 2 == 0 {
    //             front_buffer.buffer[y][x] = Cell{'#', Colour.White, Colour.Black}
    //         } else {
    //             back_buffer.buffer[y][x] = Cell{' ', Colour.White, Colour.Black}
    //         }
    //     }
    // }

    clear_screen()
    terminate := true
    if !terminate {
        // Assume console_width and console_height are determined correctly here

        // Render only differences between front_buffer and back_buffer, then swap
        for y := 0; y < SCREEN_HEIGHT; y += 1 {
            for x := 0; x < SCREEN_WIDTH; x += 1 {
                if front_buffer.buffer[y][x] != back_buffer.buffer[y][x] {
                    // Set cursor position and render cell from back_buffer
                    set_cursor_position(x, y)
                    cell := back_buffer.buffer[y][x]
                    set_colour(cell.fg, true)  // Set foreground color
                    set_colour(cell.bg, false)  // Set background color
                    fmt.printf("%c", cell.ch)  // Print character
                }
            }
        }

        // Swap front_buffer and back_buffer
        // temp := front_buffer
        // front_buffer = back_buffer
        // back_buffer = temp

        // fmt.println(temp)
        // fmt.println(front_buffer)
        // fmt.println(back_buffer)

        if should_terminate {
            fmt.printf("Terminating...\n")
            windows.SetConsoleMode(h_out, original_output_mode)
            windows.SetConsoleMode(h_in, original_input_mode)
            return
        }
    }
}
