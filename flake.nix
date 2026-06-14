{
  description = "zdos — a DOS emulator written in Zig 0.16";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        # Pin to the exact Zig 0.16.0 release from zig-overlay.
        zig = zig-overlay.packages.${system}."0.16.0";
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [ zig ];

          shellHook = ''
            echo "zdos dev shell — $(zig version)"
          '';
        };

        packages.zig = zig;
        packages.default = zig;
      });
}
