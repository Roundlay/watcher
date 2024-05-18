// package main
//
// import "core:fmt"
// import "core:os"
// import "core:math"
// import "core:strconv"
// import "vendor:raylib"
//
// // Vec2 structure to hold mouse position
// Vec2 :: struct {
//     x, y: i32 
// }
//
// // IMGUI structure to hold UI state
// IMGUI :: struct {
//     mouse_pos: Vec2,
//     scroll_offset: f32,
// }
//
// // Function to initialize IMGUI
// init_imgui :: proc() -> IMGUI {
//     return IMGUI{mouse_pos = Vec2{x = 0.0, y = 0.0}, scroll_offset = 0.0}
// }
//
// // Function to handle user input
// handle_input :: proc(ui: ^IMGUI) {
//     // Update mouse position
//     ui.mouse_pos = Vec2{
//         x = raylib.GetMouseX(),
//         y = raylib.GetMouseY(),
//     }
//
//     // Update scroll_offset for smooth scrolling
//     if raylib.IsKeyDown(raylib.KeyboardKey.UP) {
//         ui.scroll_offset -= 5.0
//     }
//     if raylib.IsKeyDown(raylib.KeyboardKey.DOWN) {
//         ui.scroll_offset += 5.0
//     }
// }
//
// // Function to render the IMGUI
// render_imgui :: proc(ui: ^IMGUI) {
//     raylib.BeginDrawing()
//     raylib.ClearBackground(raylib.RAYWHITE)
//
//     i_bucket : [10]f32
//
//     // Render a simple scrolling carousel
//     for i : int = 0; i < 10; i += 1 {
//         pos_y := f32(i) * 50.0 + ui.scroll_offset
//         raylib.DrawRectangle(100, i32(pos_y), 600, 40, raylib.LIGHTGRAY)
//         raylib.DrawText("Test string", 110, i32(pos_y + 10), 20, raylib.DARKGRAY)
//     }
//
//     raylib.EndDrawing()
// }
//
// // Main function
// main :: proc() {
//     // Initialize Raylib
//     screen_width : i32 = 800
//     screen_height : i32 = 600
//     raylib.InitWindow(screen_width, screen_height, "IMGUI with Raylib")
//     raylib.SetTargetFPS(60)
//
//     // Initialize IMGUI
//     ui := init_imgui()
//
//     // Main loop
//     for !raylib.WindowShouldClose() {
//         handle_input(&ui)
//         render_imgui(&ui)
//     }
//
//     raylib.CloseWindow()
// }

package main

import "vendor:raylib"
import "core:os"
import "core:strings"

// Utility function to draw wrapped text
drawHeader :: proc(text: string, posX, posY, maxWidth, fontSize: int, color: raylib.Color) {
    words := strings.split(text, " ")
    currentLine := ""
    yOffset := 0

    word_builder := strings.builder_make()
    defer strings.builder_destroy(&word_builder)

    for word in words {
        if currentLine != "" {
            strings.write_string(&word_builder, currentLine)
            strings.write_rune(&word_builder, ' ')
        } else {
            strings.write_string(&word_builder, word)
        }

        testLine := strings.to_string(&word_builder)
        testWidth := raylib.MeasureText(testLine, fontSize)

        if testWidth > maxWidth {
            raylib.DrawText(currentLine, posX, posY + yOffset, fontSize, color)
            currentLine = word
            yOffset += fontSize
        } else {
            currentLine = testLine
        }
    }

    raylib.DrawText(currentLine, posX, posY + yOffset, fontSize, color)
}

drawSubHeader :: proc(text: string, posX, posY, fontSize: int, color: raylib.Color) {
    raylib.DrawText(text, posX, posY, fontSize, color)
}

drawBodyText :: proc(text: string, posX, posY, maxWidth, fontSize: int, color: raylib.Color) {
    drawHeader(text, posX, posY, maxWidth, fontSize, color)
}

drawButton :: proc(text: string, posX, posY, width, height: int) {
    raylib.DrawRectangle(posX, posY, width, height, raylib.BLACK)
    textWidth := raylib.MeasureText(text, 20)
    raylib.DrawText(text, posX + (width - textWidth) / 2, posY + (height - 20) / 2, 20, raylib.RAYWHITE)
}

// Update function
update :: proc() {
    // Handle input and state updates here
}

main :: proc() {
    // Initialize the window
    screenWidth, screenHeight := 800, 600
    raylib.InitWindow(screenWidth, screenHeight, "Site Mockup with Odin and Raylib")
    raylib.SetTargetFPS(60)

    defer raylib.CloseWindow()

    // Main loop
    for !raylib.WindowShouldClose() {
        // Update
        update()

        // Draw
        raylib.BeginDrawing()
        raylib.ClearBackground(raylib.RAYWHITE)

        drawHeader("This header text should reasonably wrap here and conform to a baseline grid that still needs to be implemented.", 20, 20, screenWidth - 40, 40, raylib.BLACK)
        drawSubHeader("Next meetup: 01/02/2024", 20, 100, 30, raylib.GRAY)
        drawBodyText("This header text should reasonably wrap here and conform to a baseline grid that still needs to be implemented.", 20, 140, screenWidth - 40, 20, raylib.DARKGRAY)
        drawButton("Attend a Meetup", 20, 200, 200, 50)

        raylib.EndDrawing()
    }
}
