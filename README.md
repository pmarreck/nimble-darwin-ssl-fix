# nimble-darwin-ssl-fix

A Nix flake that ships a **`nimble` whose TLS actually works on Nix/macOS**.

On nixpkgs/darwin, stock `nimble refresh` (and any `nimble install` that hits the
network) dies with:

```
Downloading Official package list
SIGSEGV: Illegal storage access. (Attempt to read from nil?)
```

This flake fixes it. `nimble refresh` works in a completely pristine environment —
no `DYLD_*`, no `SSL_CERT_FILE`, no `--noSSLCheck`.

## Use it

```bash
# one-off
nix run github:pmarreck/nimble-darwin-ssl-fix -- refresh

# in a devShell (flake)
{
  inputs.nimble-fix.url = "github:pmarreck/nimble-darwin-ssl-fix";
  # ...
  devShells.default = pkgs.mkShell {
    buildInputs = [ pkgs.nim inputs.nimble-fix.packages.${system}.nimble ];
  };
}

# or as an overlay
nixpkgs.overlays = [ inputs.nimble-fix.overlays.default ];  # replaces pkgs.nimble
```

## What was actually wrong

This is **not** a missing nil-check (Nim's `std/openssl` already raises
`LibraryError` on a failed symbol load), and Nim's SSL itself is fine — a fresh
`nim c -d:ssl` HTTPS program downloads the very same `packages.json` with no env
hacks. The bug is specific to how **nimble** is built and how Nim binds OpenSSL on
nixpkgs:

`lib/wrappers/openssl.nim` binds OpenSSL two ways at once:

1. **Bulk procs** (`SSL_CTX_new`, `SSL_connect`, `SSL_read`, …) — nixpkgs patches
   these (ehmry, 2023, *"Do not load openssl with dlopen"*) to **link** against
   nixpkgs' OpenSSL at build time.
2. **Compat procs** (`TLS_method`, `getOpenSSLVersion`, …) — still resolved at
   **runtime** via `dlopen` of a **bare** library name
   (`"libssl(.3|.1.1|…).dylib"`).

Two failures compound on darwin:

- The stock nixpkgs `nimble` is built **without `--define:ssl`**, so it isn't even
  link-bound to nix's OpenSSL. (`otool -L` on the shipped binary shows no libssl.)
- Even after adding `-d:ssl`, the compat procs' bare-name `dlopen` does **not**
  resolve to the link-bound nix OpenSSL on macOS. The runtime probe lands on a
  *different* (or no) libssl, and mixing two OpenSSL builds crashes inside
  `SSL_CTX_new` — exactly the *"two different openSSL loaded version causes a
  crash"* scenario `openssl.nim`'s own header comment warns about.

Crash path (from a stacktrace build):

```
packageinfo.nim(151)  fetchList
tools.nim(224)        newSSLContext
net.nim(670)          newContext      <- TLS_method()/SSL_CTX_new, mixed openssl
SIGSEGV
```

It works on Linux (and goes unnoticed by maintainers) because there the
link-bound OpenSSL is on the loader path, so the leftover runtime probe resolves
to the *same* library. macOS + Nix + Nim is the unlucky cell.

## The fix (three parts, all empirically required)

1. **`--define:ssl`** — link-bind the bulk procs to nixpkgs OpenSSL.
2. **`DYLD_FALLBACK_LIBRARY_PATH` → nix openssl `/lib`** — so the compat layer's
   runtime `dlopen` probe resolves to the **same** OpenSSL. No mismatch, no crash.
3. **`SSL_CERT_FILE` → cacert bundle** — so certificate verification passes.

(2) and (3) are baked into the binary via `wrapProgram`, so users set nothing.
See `flake.nix` for the exact derivation.

## Verified

```
$ env -i HOME=/tmp/x PATH=/usr/bin:/bin  result/bin/nimble refresh
Downloading Official package list
    Success Package list downloaded.
```

(`env -i` = empty environment; nothing inherited.)

---

## Ready-to-file nixpkgs issue

> **Title:** `nimble` segfaults on `nimble refresh` on aarch64-darwin (no `-d:ssl`
> + bare-name openssl `dlopen` mismatch)
>
> **Description:** The shipped `nimble` (`pkgs/by-name/ni/nimble/package.nix`) is
> built without `--define:ssl`, so its openssl procs are not link-bound to
> nixpkgs openssl (`otool -L $(which nimble)` shows no libssl). `nimble refresh`
> SIGSEGVs in `net.newContext` (`tools.nim:224 newSSLContext` → `net.nim:670`).
>
> Adding `nimFlags = [ "--define:ssl" ]` makes it link libssl, but it **still**
> segfaults on darwin: Nim's `std/openssl` compat layer (`TLS_method`, etc.)
> resolves libssl at runtime via a bare-name `dlopen`, which on macOS does not
> find the link-bound nix openssl, so a *different* openssl is mixed in →
> crash in `SSL_CTX_new`. A fresh `nim c -d:ssl` HTTPS program works, confirming
> the issue is nimble's build + the leftover runtime probe, not Nim's SSL.
>
> **Fix options:** (a) add `--define:ssl` to the nimble derivation **and** make
> the openssl compat-probe resolve to the link-bound store path on darwin (patch
> `DLLSSLName`/`DLLUtilName` to absolute `${openssl}/lib/...` in `nim-unwrapped`),
> or (b) wrap `nimble` with `DYLD_FALLBACK_LIBRARY_PATH=${openssl}/lib` +
> `SSL_CERT_FILE`. Note: the `--dynlibOverride:ssl` static route is currently
> broken in the patched nim (`Error: invalid pragma: gimportc`).

## Sources

- [NixOS/nixpkgs#150982 — nimble "Illegal storage access" downloading packages.json](https://github.com/NixOS/nixpkgs/issues/150982)
- [NixOS/nixpkgs#201456 — nimble refresh invalid certificates (openssl 3.x)](https://github.com/NixOS/nixpkgs/issues/201456)
- [Nimble troubleshooting — DYLD_LIBRARY_PATH / -d:ssl](https://nim-lang.github.io/nimble/troubleshooting.html)
- nixpkgs commit *"Do not load openssl with dlopen"* (ehmry, 2023) — `pkgs/by-name/ni/nim-unwrapped-2_2/openssl.patch`

## License

MIT (or match upstream nimble's BSD-3 — it's just a build wrapper).
