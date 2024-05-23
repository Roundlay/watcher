/*

   Odin Programming Language

   Please provide feedback on the following questions.
   Where there are multiple defintions, please pick the one that best explains the concept.

   What is a file descriptor (fd)?
   - A file descriptor is a unique identifier (handle) that an operating system assigns to a resource (file, output stream, etc.) in order to keep track of it.

   What is a handle?
   - An abstract indicator (typically a non-negative integer) used to access or track a file or a stream.

   What is the difference between streaming and writing data?
   - Streaming is continuous while writing is discrete.

 */

package main

import "core:fmt"

main :: proc() {
    // fmt.printl("Hello, World!")
    fmt.printf("Hello, %s!", "World")
}
