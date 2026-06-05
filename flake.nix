{
  description = "nimble for Nix/macOS with working TLS — fixes the openssl dlopen/segfault on `nimble refresh`/`install`";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      overlays.default = final: prev: {
        nimble = self.packages.${prev.stdenv.hostPlatform.system}.nimble;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;

          # The fix, in three parts (all empirically required on nix/darwin):
          #
          #  1. `--define:ssl` — without it nimble's openssl procs are not
          #     link-bound, so the binary doesn't even reference nix's libssl.
          #     With it, the *bulk* procs (SSL_CTX_new, SSL_connect, …) bind to
          #     nixpkgs openssl at link time.
          #
          #  2. DYLD_FALLBACK_LIBRARY_PATH -> nix openssl. Nim's std/openssl
          #     keeps a *compat layer* (TLS_method, getOpenSSLVersion, …) that
          #     still resolves libssl at runtime via `dlopen` of a BARE name
          #     ("libssl(.3|.1.1|…).dylib"). On macOS that bare-name lookup does
          #     NOT find the link-bound nix openssl, so it loads a *different*
          #     libssl (or none) — and mixing two OpenSSLs crashes inside
          #     SSL_CTX_new (the exact failure std/openssl's own header warns
          #     about). Pointing the fallback path at nix's openssl makes the
          #     runtime probe resolve to the SAME library → no mismatch.
          #
          #  3. SSL_CERT_FILE -> cacert bundle, so certificate verification
          #     succeeds (otherwise: "Failed to verify the SSL certificate").
          #
          # Wrapping bakes (2) and (3) into the binary, so the user needs no
          # environment setup — `nimble refresh` just works.
          opensslLibPath = lib.makeLibraryPath [ pkgs.openssl ];
          caBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

          nimble-tls = pkgs.nimble.overrideAttrs (old: {
            pname = "nimble-tls-fixed";

            nimFlags = (old.nimFlags or [ ]) ++ [ "--define:ssl" ];

            # Re-wrap from scratch: preserve nimble's own `nim`-on-PATH wrap and
            # add the openssl/cert environment. (DYLD_* is darwin-only and
            # LD_LIBRARY_PATH is linux-only; setting both is harmless and keeps
            # one expression for all systems.)
            postInstall = ''
              wrapProgram $out/bin/nimble \
                --suffix PATH : ${lib.makeBinPath [ pkgs.nim ]} \
                --prefix DYLD_FALLBACK_LIBRARY_PATH : ${opensslLibPath} \
                --prefix LD_LIBRARY_PATH : ${opensslLibPath} \
                --set-default SSL_CERT_FILE ${caBundle}
            '';

            meta = old.meta // {
              description = "nimble with working TLS on Nix/macOS (openssl dlopen fix)";
            };
          });
        in
        {
          nimble = nimble-tls;
          default = nimble-tls;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.nimble}/bin/nimble";
        };
      });
    };
}
