{
  description = "Zig build for graphviz";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, flake-utils, zig-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        version = builtins.head (builtins.match
          ".*\n *const graphviz_version = \"([^\"]+)\";\n.*"
          (builtins.readFile ./build.zig));

        # Release tarball, not a git checkout: only it ships the pre-generated
        # grammar.c, scan.c and htmlparse.c.
        upstream = pkgs.fetchzip {
          url = "https://gitlab.com/api/v4/projects/graphviz%2Fgraphviz/packages/generic/graphviz-releases/${version}/graphviz-${version}.tar.xz";
          hash = "sha256-SwNKwzYNA3K+idl0azA6nmmUspYE3fAfcnDNTxGgeKo=";
        };
      in {
        devShells.default = pkgs.mkShell {
          packages = [ zig-overlay.packages.${system}."0.17.0" ];

          GRAPHVIZ_SRC = upstream;
        };
      });
}
