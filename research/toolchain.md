# Reverse-engineering toolchain

Installed 2026-10-09 on macOS 26.7.1, Apple Silicon. Nothing here is in the repo; the Ghidra snapshot and raw output stay in `.local/ghidra/`.

| Tool   | Version                                                              | Location                                                    | Notes                                                                                                                                                                                |
| ------ | -------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| JDK    | Temurin 21.0.12+8                                                    | `~/.local/share/mise/installs/java/temurin-21.0.12+8.0.LTS` | `mise install` only, not set as a global default                                                                                                                                     |
| Ghidra | 12.1.4 (`ghidra_12.1.4_PUBLIC_20260921.zip`, sha256 `ddac49f9…d4db`) | `~/tools/ghidra_12.1.4_PUBLIC`                              | Release has no macOS arm64 decompiler; built with `cd support/gradle && mise exec gradle@9.5.1 -- gradle buildNatives` (output in `Ghidra/Features/Decompiler/build/os/mac_arm_64/`) |
| rea    | 6.1.0                                                                | `npx -y rea-agents@6.1.0`                                   | CLI only, no agent registration. `rea doctor --provider ghidra` reports healthy                                                                                                      |

## Environment

```sh
export GHIDRA_INSTALL_DIR=$HOME/tools/ghidra_12.1.4_PUBLIC
export JAVA_HOME=$HOME/.local/share/mise/installs/java/temurin-21.0.12+8.0.LTS
export REA_GHIDRA_STARTUP_TIMEOUT_MS=1200000
```

## Usage

```sh
npx -y rea-agents@6.1.0 decompile "$PWD/.local/disc/files/BEASTS.EXE" 0x4268d0 \
  --provider ghidra --snapshot "$PWD/.local/ghidra/beasts.snapshot" --format md
```

Smoke test: `0x4268D0` (Script mode text input) decompiles and matches the hand analysis in `disc-and-executable.md`. Each CLI call imports into an ephemeral Ghidra project, so bulk mapping may be better done through a persistent rea MCP session.
