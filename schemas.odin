package watcher

import "core:fmt"
import "core:strings"
import "core:strconv"
// Pull in runtime so we can call `append_elem`
import "base:runtime"

ErrorRecord :: struct {
    file_path   : string,
    row         : int,
    column      : int,
    message     : string,
    snippet     : string,
    underline   : string,
    suggestions : []string,
}

// parseCompilerOutput ...
parseCompilerOutput :: proc(raw_output: string) -> []ErrorRecord {
    // strings.split() returns a slice of type string.
    lines := strings.split(raw_output, "\n")
    // Is the issue that we're saying "errors" is a slice of ErrorRecord, and ErrorRecord is a struct?
    errors : [dynamic]ErrorRecord
    i := 0

    for i < len(lines) {
        line := strings.trim_space(lines[i])

        if strings.index(line, ".odin(") != -1 {
            error_record: ErrorRecord
            open_paren_index := strings.index(line, "(")
            close_paren_index := strings.index(line, ")")

            if (open_paren_index != -1) && (close_paren_index != -1) && (close_paren_index > open_paren_index) {
                error_record.file_path = strings.trim_space(line[:open_paren_index])
                inside_paren := line[open_paren_index+1:close_paren_index]
                row_col_parts := strings.split(inside_paren, ":")
                if len(row_col_parts) == 2 {
                    error_record.row    = strconv.atoi(strings.trim_space(row_col_parts[0]))
                    error_record.column = strconv.atoi(strings.trim_space(row_col_parts[1]))
                }
                if close_paren_index+1 < len(line) {
                    error_record.message = strings.trim_space(line[close_paren_index+1:])
                }
            } else {
                error_record.message = line
            }

            if (i+1) < len(lines) {
                error_record.snippet = strings.trim_right_space(lines[i+1])
            }

            if (i+2) < len(lines) {
                underline_line := strings.trim_right_space(lines[i+2])
                if strings.index(underline_line, "^") != -1 {
                    error_record.underline = underline_line
                }
            }

            error_record.suggestions = parseSuggestions(lines, i+3)

            append(&errors, error_record)

            i += 3
            continue
        }

        i += 1
    }

    return errors[:]
}

// parseSuggestions ...
parseSuggestions :: proc(lines: []string, start_index: int) -> []string {
    suggestions : [dynamic]string
    i := start_index
    if i >= len(lines) {
        return suggestions[:]
    }

    if !strings.has_prefix(strings.trim_space(lines[i]), "Suggestion:") {
        return suggestions[:]
    }
    i += 1

    for i < len(lines) {
        trimmed := strings.trim_space(lines[i])
        if trimmed == "" {
            break
        }
        if strings.has_prefix(trimmed, "C:/") || strings.has_prefix(trimmed, "Suggestion:") {
            break
        }
        // Use append_elem
        append(&suggestions, trimmed)
        i += 1
    }

    return suggestions[:]
}

formatError :: proc(err: ErrorRecord) -> string {
    builder, _ := strings.builder_make_len_cap(0, 512)
    // defer strings.builder_destroy(&builder)

    fmt.sbprintf(&builder, "---File Path---\n%s\n", err.file_path)
    fmt.sbprintf(&builder, "---Row---\n%d\n", err.row)
    fmt.sbprintf(&builder, "---Column---\n%d\n", err.column)
    fmt.sbprintf(&builder, "---Message---\n%s\n", err.message)
    fmt.sbprintf(&builder, "---Snippet---\n%s\n", err.snippet)
    fmt.sbprintf(&builder, "---Underline---\n%s\n", err.underline)

    if len(err.suggestions) > 0 {
        fmt.sbprintf(&builder, "---Suggestions (count: %d)---\n", len(err.suggestions))
        for s in err.suggestions {
            fmt.sbprintf(&builder, "- %s\n", s)
        }
    }

    output_string := strings.to_string(builder)
    return output_string
}

main :: proc() {
    raw_output := `
C:/Users/Christopher/Projects/pikuma/3D Graphics Programming from Scratch/renderer/test.odin(8:5) 'printl' is not declared by 'fmt'
        fmt.printl("Test")
        ^~~~~~~~~^
        Suggestion: Did you mean?
                print
                printf
                println
                ...
                bprintln
    `
    errors := parseCompilerOutput(raw_output)
    if len(errors) == 0 {
        fmt.println("No recognized errors. Dumping raw output:")
        fmt.println(raw_output)
        return
    }

    for err in errors {
        output := formatError(err)
        fmt.println(output)
    }
}
