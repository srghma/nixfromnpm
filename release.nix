{
  nixpkgs ? import ./nix/nixpkgs.nix,
  compiler ? null,
}:
let
  config   = { allowUnfree = true; };

  overlays = [
    (newPkgs: oldPkgs: rec {
      gitignore = newPkgs.callPackage ./nix/nix-gitignore.nix {};

      origHaskellPackages = if compiler == null then oldPkgs.haskellPackages
                            else oldPkgs.haskell.packages."${compiler}";

      haskellPackages = origHaskellPackages.override {
        overrides = haskellPackagesNew: haskellPackagesOld:
            { semver-range =
                haskellPackagesNew.callPackage ./nix/semver-range.nix { };

              text-render =
                haskellPackagesNew.callPackage ./nix/text-render.nix { };

              hnix = haskellPackagesOld.hnix_0_4_0;

              nixfromnpm =
                newPkgs.haskell.lib.overrideCabal
                  (haskellPackagesNew.callPackage ./default.nix { })
                  (oldDerivation: rec {
                    src =
                      let
                        ignores = ''
                          *
                          !src/
                          !tests/
                          !nix-libs/
                          !LICENSE
                          !nixfromnpm.cabal
                        '';
                      in
                        gitignore.gitignoreSourcePure ignores oldDerivation.src;
                    shellHook = builtins.trace src ((oldDerivation.shellHook or "") + ''
                      export SRC=${src}
                      export CURL_CA_BUNDLE=${newPkgs.cacert}/etc/ssl/certs/ca-bundle.crt
                      export NIX_LIBS_DIR=$PWD/nix-libs
                    '');
                  });
            };
      };

    })
  ];

  pkgs = import nixpkgs { inherit config overlays; };

in

  { inherit (pkgs.haskellPackages) nixfromnpm; inherit pkgs; }
