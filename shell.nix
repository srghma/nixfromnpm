{
  nixpkgs ? import ./nix/nixpkgs.nix,
  compiler ? null
}:

let
  pkgs = (import ./release.nix { inherit nixpkgs compiler; });

  inherit (pkgs) haskellPackages;

  inherit (haskellPackages) nixfromnpm;

  hie = (import ((import nixpkgs {}).fetchFromGitHub {
    owner = "domenkozar"; repo = "hie-nix";
    rev = "e3113da93b479bec3046e67c0123860732335dd9";
    sha256 = "05rkzjvzywsg66iafm84xgjlkf27yfbagrdcb8sc9fd59hrzyiqk";
  }) {}).hie82;
in

pkgs.lib.overrideDerivation nixfromnpm.env (oldAttrs: {
  buildInputs =
    oldAttrs.buildInputs ++
    [ hie ] ++
    (with haskellPackages; [cabal-install hlint hindent stylish-haskell]);

  # Caution: leave oldAttrs.shellHook in place, or HIE will break (just HIE!).
  shellHook = oldAttrs.shellHook + ''
    export NIX_PATH='nixpkgs=${nixpkgs}'
  '';
})
