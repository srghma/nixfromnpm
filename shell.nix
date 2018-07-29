{
  nixpkgs ? import ./nix/nixpkgs.nix,
  compiler ? null
}:

let
  pkgs = (import ./release.nix { inherit nixpkgs compiler; });

  inherit (pkgs.haskellPackages) nixfromnpm;

  haskellPackages = if compiler == null then pkgs.haskellPackages
                    else pkgs.haskell.packages."${compiler}";

  my-intero =
    (import ((import <nixpkgs> {}).pkgs.fetchFromGitHub {
      owner = "NixOS"; repo = "nixpkgs";
      rev = "2c1838ab99b";
      sha256 = "0lz9gmb97y6cvjj5pbz89cx97c6d49v5nmfwh8sbmgfmqy8cfwxp";
    }) {}).haskellPackages.intero;


  ghc = haskellPackages.ghcWithPackages (ps: with ps; [
    monad-par mtl my-intero QuickCheck
  ]);
in

pkgs.stdenv.mkDerivation {
  name = "my-haskell-env-0";
  buildInputs = [ ghc ];
  shellHook = "eval $(egrep ^export ${ghc}/bin/ghc)";
}
