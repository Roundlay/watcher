package main

import "core:fmt"
import "core:strings"

main :: proc () {
    terminal_width :: 80 // Assuming a width of 80 characters
    terminal_height :: 24 // Assuming a height of 24 lines

    // Move cursor to the bottom of the terminal
    fmt.printf("\033[%d;%dH", terminal_height, 1)

    // Draw the status bar
    status_bar := "-- ODIN VIM-LIKE STATUS BAR --"
    padding_length := terminal_width - len(status_bar)

    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)

    strings.write_string(&builder, status_bar)
    for i := 0; i < padding_length; i += 1 {
        strings.write_byte(&builder, ' ')
    }

    status := strings.to_string(builder)
    strings.builder_reset(&builder)
    fmt.println(status)
}
