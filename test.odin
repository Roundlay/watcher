// package main
//
// import "core:fmt"
//
// main :: proc() {
//     data : []int = {1, 2, 3, 4, 5}
//     fmt.printf("Initial array: {}", data)
//
//     // Corrected section
//     // This loop correctly iterates through the array, doubling each element's value
//     for i := 0; i < len(data); i += 1 { // Corrected loop boundaries
//         data[i] *= 2
//     }
//     // End corrected section
//
//     fmt.printf("Modified array: {}", data)
// }

package main

import "core:fmt"

main :: proc() {
    data : []int = {1, 2, 3, 4, 5}
    fmt.println("Initial array: {}", data)

    // This isn't working. I keep getting [2, 4, 6, 8, 5] instead of [2, 4, 6, 8, 10]
    for i := 1; i < len(data); i += 1 {
        data[i-1] *= 2
    }

    fmt.println("Modified array: {}", data)
}
