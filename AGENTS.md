# Notes on Environment

- Development environment: `Windows 11(WSL2(Linux(Ubuntu)))`.
- Odin compiler available via `odin` command.
- Windows specific code fails to compile on Linux due to missing `windows` package, and this is expected for the time being.
- Always run `odin build {file} -file` to build, doing so on the Windows side using `CMD.exe`.
- Tests can be executed with `odin test {dir}`.
