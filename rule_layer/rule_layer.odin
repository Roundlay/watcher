package rule_layer

import "core:os"
import "core:strings"
import "core:fmt"
import "base:runtime"

Rule :: struct {
    pattern: string,
    command: string,
    workdir: string,
}

Config :: struct {
    root: string,
    match: string,
    ignore: [dynamic]string,
    log_json: bool,
    rules: [dynamic]Rule,
}

// parse_ext validates comma separated extensions without dots or wildcards
parse_ext :: proc(s: string) -> ([]string, bool) {
    parts := strings.split(s, ",")
    valid: [dynamic]string
    for p in parts {
        if p == "" || strings.index_any(p, "*.?{}") >= 0 || strings.has_prefix(p, ".") {
            fmt.eprintln("invalid extension", p)
            return valid[:], false
        }
        append(&valid, p)
    }
    return valid[:], true
}

// simple flag parser focusing on new rule related flags
parse_flags :: proc(args: []string) -> (Config, bool) {
    cfg: Config
    cfg.root = os.get_current_directory()
    cfg.match = "all"
    i := 1
    cur: ^Rule
    for i < len(args) {
        arg := args[i]
        switch arg {
        case "-w", "--watch":
            i += 1; if i >= len(args) { fmt.eprintln("--watch requires path"); return cfg, false }
            cfg.root = args[i]
        case "-e", "--ext":
            i += 1; if i >= len(args) { fmt.eprintln("--ext requires value"); return cfg, false }
            exts, ok := parse_ext(args[i])
            if !ok { return cfg, false }
            pattern := strings.join(exts, ",")
            rule := Rule{pattern = pattern}
            append(&cfg.rules, rule)
            cur = &cfg.rules[len(cfg.rules)-1]
        case "-c", "--command":
            i += 1; if i >= len(args) { fmt.eprintln("--command requires value"); return cfg, false }
            if cur == nil { fmt.eprintln("--command used without rule"); return cfg, false }
            cur.command = args[i]
        case "-d", "--dir":
            i += 1; if i >= len(args) { fmt.eprintln("--dir requires value"); return cfg, false }
            if cur == nil { fmt.eprintln("--dir used without rule"); return cfg, false }
            cur.workdir = args[i]
        case "--match":
            i += 1; if i >= len(args) { fmt.eprintln("--match requires value"); return cfg, false }
            cfg.match = args[i]
        case "--ignore":
            i += 1; if i >= len(args) { fmt.eprintln("--ignore requires value"); return cfg, false }
            append(&cfg.ignore, args[i])
        case "--json":
            cfg.log_json = true
        case:
            fmt.eprintln("unknown flag", arg)
            return cfg, false
        }
        i += 1
    }
    return cfg, true
}

// load_config reads a toml file into Config
// very small pseudo TOML loader for example purposes only
load_config :: proc(file: string) -> (Config, bool) {
    data, ok := os.read_entire_file(file)
    if !ok {
        fmt.eprintln("failed to read", file)
        return Config{}, false
    }
    lines := strings.split(string(data), "\n")
    cfg: Config
    cfg.root = os.get_current_directory()
    cfg.match = "all"
    cur: ^Rule
    for line in lines {
        l := strings.trim_space(line)
        if l == "" || strings.has_prefix(l, "#") {
            continue
        }
        if strings.has_prefix(l, "root") {
            parts := strings.split(l, "=")
            if len(parts) == 2 { cfg.root = strings.trim_space(parts[1]) }
        } else if strings.has_prefix(l, "match") {
            parts := strings.split(l, "=")
            if len(parts) == 2 { cfg.match = strings.trim_space(parts[1]) }
        } else if strings.has_prefix(l, "ignore") {
            // ignore not implemented
        } else if strings.has_prefix(l, "[[rule]]") {
            rule := Rule{}
            append(&cfg.rules, rule)
            cur = &cfg.rules[len(cfg.rules)-1]
        } else if strings.has_prefix(l, "extensions") && cur != nil {
            parts := strings.split(l, "=")
            if len(parts) == 2 {
                ex_line := strings.trim_space(parts[1])
                ex_line = strings.trim_prefix(ex_line, "[")
                ex_line = strings.trim_suffix(ex_line, "]")
                ex_line, _ = strings.replace_all(ex_line, "\"", "")
                exts, _ := parse_ext(ex_line)
                cur.pattern = strings.join(exts, ",")
            }
        } else if strings.has_prefix(l, "pattern") && cur != nil {
            parts := strings.split(l, "=")
            if len(parts) == 2 { tmp, _ := strings.replace_all(parts[1], "\"", ""); cur.pattern = strings.trim_space(tmp) }
        } else if strings.has_prefix(l, "command") && cur != nil {
            parts := strings.split(l, "=")
            if len(parts) == 2 { tmp, _ := strings.replace_all(parts[1], "\"", ""); cur.command = strings.trim_space(tmp) }
        } else if strings.has_prefix(l, "workdir") && cur != nil {
            parts := strings.split(l, "=")
            if len(parts) == 2 { tmp, _ := strings.replace_all(parts[1], "\"", ""); cur.workdir = strings.trim_space(tmp) }
        }
    }
    return cfg, true
}

