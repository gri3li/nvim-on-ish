# Neovim on iSH

Run a **modern Neovim (0.12.x)** in [iSH](https://ish.app) on iPhone/iPad, without upgrading iSH's base system.

iSH's own package repository is frozen at Alpine v3.14, which ships Neovim **0.4.4**. Most current plugins need a much newer Neovim. Upgrading the whole iSH system to a newer Alpine release is possible, but it tends to break things, because newer binaries hit gaps in iSH's emulator.

This project takes a narrower route. It installs Neovim from a recent Alpine release (v3.24, Neovim 0.12.2) into an **isolated directory** and works around each iSH incompatibility with a small shim and a launcher script. Your base system stays on v3.14, and nothing outside `/opt/nvim-on-ish` and the launcher is touched.

```
$ nvim12 --version
NVIM v0.12.2
```

## Quick start

Inside iSH, as root:

```sh
apk add git
git clone https://github.com/gri3li/nvim-on-ish
cd nvim-on-ish
./install.sh
nvim12 file.txt
```

To make it your default `nvim`:

```sh
echo 'alias nvim=nvim12' >> ~/.profile
```

Re-run `./install.sh` at any time to upgrade Neovim inside the isolated root. It re-applies the patches automatically.

### Options

| Variable        | Default                                   | Meaning                          |
|-----------------|-------------------------------------------|----------------------------------|
| `PREFIX`        | `/opt/nvim-on-ish`                        | isolated root for nvim and libs  |
| `ALPINE_BRANCH` | `v3.24`                                   | Alpine branch to take nvim from  |
| `ALPINE_MIRROR` | `https://dl-cdn.alpinelinux.org/alpine`   | Alpine mirror                    |
| `BINDIR`        | `/usr/local/bin`                          | launcher location                |
| `NAME`          | `nvim12`                                  | launcher name                    |

### Uninstall

```sh
./uninstall.sh
```

This removes `PREFIX` and the launcher. It keeps your config (`~/.config/nvim`) and plugins (`~/.local/share/nvim`).

## What goes wrong, and how it is fixed

The interesting part of this project is the list of problems, so each one is documented here. Most of these apply to *any* recent binary you try to run on iSH, not just Neovim.

### 1. iSH's repos are frozen at Alpine v3.14

**Symptom:** `apk add neovim` gives 0.4.4.

**Fix:** `install.sh` uses `apk --root /opt/nvim-on-ish --initdb --arch x86` with the official Alpine v3.24 repositories. Neovim and all its dependencies (luajit, libuv, tree-sitter, utf8proc, …) land in that directory, and the system `/lib` and `/usr` are not touched. `--no-scripts` keeps apk from running v3.24 install scripts.

### 2. New libraries need a newer musl

**Symptom:** with v3.24's own musl loader you get `Invalid system call`. With iSH's musl 1.2.2 you get:

```
Error relocating .../libuv.so.1: pthread_getname_np: symbol not found
```

**Fix:** use iSH's **system** musl (`/lib/ld-musl-i386.so.1`, the default interpreter of the binary), and supply the one missing function from `libshim.so`. libuv only uses `pthread_getname_np` to report thread names, so an empty name is harmless.

### 3. lpeg is linked by absolute path

**Symptom:**

```
Error loading shared library /usr/lib/lua/5.1/lpeg.so: No such file or directory
```

Alpine's nvim has `/usr/lib/lua/5.1/lpeg.so` as an absolute `DT_NEEDED` entry. The loader opens absolute paths as-is and ignores the library search path.

**Fix:** `patchelf --replace-needed /usr/lib/lua/5.1/lpeg.so lpeg.so`. The same patchelf step adds `libshim.so` as a dependency.

### 4. Library search path

Setting an `RPATH` with iSH's patchelf/musl did not take effect in testing. The launcher therefore sets `LD_LIBRARY_PATH` to the isolated root. To keep those libraries from leaking into programs nvim starts (git, `:!cmd`, `:terminal`, LSP servers), the server clears the variable right at startup with `--cmd 'lua vim.env.LD_LIBRARY_PATH = nil'`, before your `init.lua` runs.

### 5. Unimplemented syscalls are fatal (SIGSYS)

**Symptom:** `zsh: invalid system call`, exit code 159 (= 128 + SIGSYS).

When a program makes a syscall that iSH doesn't implement, older iSH builds deliver **SIGSYS**, whose default action kills the process. libuv and musl routinely probe newer syscalls and fall back on `ENOSYS`, but they never get the chance. iSH's master branch already returns plain `ENOSYS` instead (commit [`f8a7e44`](https://github.com/ish-app/ish/commit/f8a7e44c), Oct 2023), but the App Store build used for testing still showed the old behaviour.

**Fix:** the launcher runs `trap '' SYS`. An ignored disposition survives `exec`, so the syscall simply returns `ENOSYS` and the fallback path runs. On iSH builds that include `f8a7e44`, this trap is a harmless no-op.

### 6. The built-in TUI dies on startup

**Symptom:** `nvim12 file.txt` exits immediately with code 159. Your shell then prints terminal junk such as `^[[?1;2c` (the terminal's reply to nvim's startup query, arriving after nvim is already gone). `nvim --headless` works fine.

Since 0.10, Neovim's TUI is a separate process that spawns its own embedded server. Neovim resets signal handlers at startup, so the `trap` from fix 5 no longer protects the TUI process, and it gets killed by SIGSYS during that startup.

**Fix:** the launcher does the split itself. It starts `nvim --headless --listen <sock> <your args>` in the background and attaches with `nvim --remote-ui --server <sock>`. Each launch uses its own socket, the server exits on `:q`, and the launcher cleans up if anything is left behind.

### 7. Directory entries have no type (`d_type = DT_UNKNOWN`)

**Symptom:** with `vim.pack`, every start shows `vim.pack: Installing plugins (n/24)` even though all plugins are already in `~/.local/share/nvim/site/pack/core/opt`.

iSH returns `DT_UNKNOWN` for every directory entry (the type is hard-coded to `0` in its `getdents` implementation). POSIX allows this, but libuv/luv then report the entry type as `nil`. In Neovim 0.12.2 (the version Alpine v3.24 ships), vim.pack compares its lockfile against the plugin directory using those types, decides no plugin is installed, and reinstalls everything. Neovim 0.12.3+ falls back to `lstat` inside `vim.fs.dir()` (neovim/neovim#39612), but plugins that call `vim.uv.fs_scandir_next()` directly still get `nil` (luvit/luv#660).

You can check for it like this:

```sh
nvim12 --headless --clean \
  -c 'lua for n,t in vim.fs.dir(vim.fn.stdpath("data").."/site/pack/core/opt") do print(n,t) end' -c q
# before the fix: "oil.nvim nil"; after: "oil.nvim directory"
```

**Fix:** `libshim.so` wraps `readdir()` and `scandir()`. When `d_type` is unknown, it fills it in with `lstat()`. This fixes both vim.pack on 0.12.2 and plugins that read directories through luv directly.

## How it fits together

```
nvim12 (sh launcher)
 ├─ trap '' SYS                      # fix 5
 ├─ LD_LIBRARY_PATH=$PREFIX/...      # fix 4
 ├─ nvim --headless --listen SOCK    # fix 6: server
 │    --cmd 'unset LD_LIBRARY_PATH'  #        children get a clean env
 └─ nvim --remote-ui --server SOCK   # fix 6: UI

$PREFIX/usr/bin/nvim (patched)       # fix 3
 ├─ interpreter: /lib/ld-musl-i386.so.1   (iSH's musl 1.2.2)   # fix 2
 └─ NEEDED: libshim.so                # fixes 2 and 7
```

## Known limitations

- **Tree-sitter parsers.** nvim-treesitter needs `curl` (`apk add curl`) and a C compiler to build parsers. Compiling under emulation is slow. This is out of scope for now.
- **Git is iSH's 2.32.** That was enough for `vim.pack` in testing.
- **SIGSYS stays ignored for child processes.** In practice this helps them as well, but a program that really depends on an unimplemented syscall will fail with an error instead of crashing.
- **Other binaries from v3.24** (LSP servers via mason, etc.) are not handled by this launcher. The same techniques apply to them, though.
- Tested with Neovim 0.12.2 from Alpine v3.24 on iSH 1.3.2 (build 494, App Store) with an Alpine v3.14 base, iOS 26.5, iPhone 17e.

## Troubleshooting

- **`symbol not found: <name>`.** Some other new libc function is missing. Add a stub to `shim.c` and re-run `./install.sh`. Please open an issue with the name.
- **`nvim12: server exited before start`.** Run `nvim12 --headless +q; echo $?` to see the real error.
- **Terminal looks broken after a crash.** Run `reset`.
- **Plugins still reinstall on every start.** Run the `vim.fs.dir` check from fix 7. If types are still `nil`, the shim is not loaded: `patchelf --print-needed /opt/nvim-on-ish/usr/bin/nvim` should list `libshim.so`.

## Upstream

These workarounds stand in for real fixes that belong upstream:

- **iSH:** `getdents`/`getdents64` always report `d_type = DT_UNKNOWN`. The type is hard-coded to `0` in [`fs/dir.c`](https://github.com/ish-app/ish/blob/master/fs/dir.c). Reported as ish-app/ish#2830. The SIGSYS problem is already fixed on master, so only a release is needed.
- **Neovim:** already fixed. `vim.fs.dir()` falls back to `lstat` since v0.12.3 (neovim/neovim#39612). Alpine v3.24 still ships 0.12.2.
- **luv:** `fs_scandir_next()` returns no type for `DT_UNKNOWN` (luvit/luv#660), so plugins calling it directly still need the shim.

Contributions and reports are welcome.

## License

MIT, see [LICENSE](LICENSE).
