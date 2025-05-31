package tests

import "core:testing"
import "../rule_layer"

@test
test_parse_ext :: proc(t: ^testing.T) {
    exts, ok := rule_layer.parse_ext("odin,odin32")
    testing.expect(t, ok && len(exts) == 2)
}

@test
test_load_config :: proc(t: ^testing.T) {
    cfg, ok := rule_layer.load_config("./config/example.watcher.toml")
    testing.expect(t, ok && len(cfg.rules) > 0)
}
