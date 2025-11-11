# Notes on Environment

- Odin compiler available via `odin` command.
- Windows specific code fails to compile on Linux due to missing `windows` package.
- Always run `odin build {file} -file` to check compilation errors even if it fails.
- Tests can be executed with `odin test {dir}`.

## Post-mortem

This repository originally contained Windows-specific watcher code that does not compile on Linux. Implementing the full rule layer was complex, so a simplified version was added in `rule_layer.odin` along with an example configuration and basic tests.
