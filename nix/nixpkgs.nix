let
  fetchNixpkgs = import ./fetchNixpkgs.nix;
in

# version - 18.09

# to update use
# nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/a260b3d681164bedaeb90fd578390147799d638c.tar.gz

fetchNixpkgs {
  rev    = "a260b3d681164bedaeb90fd578390147799d638c";
  sha256 = "1mhx4psyp4ar920rf4dvdc47dhcnm2gs5gr90xfknnmcqil08gwn";
}
