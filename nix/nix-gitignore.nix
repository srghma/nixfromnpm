{ pkgs }:

pkgs.callPackage (pkgs.fetchFromGitHub {
  owner = "siers";
  repo = "nix-gitignore";
  rev = "6dd9ece00991003c0f5d3b4da3f29e67956d266e";
  sha256 = "0jn5yryf511shdp8g9pwrsxgk57p6xhpb79dbi2sf5hzlqm2csy4";
}) { }
