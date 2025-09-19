{
  description = "Dev environment with jq, exported as a flake-parts module";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ self, flake-parts, ... }:
    let
      # Reusable flake-parts module to export
      module = { config, lib, ... }: {
        options = {}; # Add options if you want to parameterize packages later
        config.perSystem = { pkgs, ... }: {
          devShells.default = pkgs.mkShell {
            packages = [ pkgs.jq ];
          };
        };
      };
    in
      # Use flake-parts locally and expose the module for consumers
      flake-parts.lib.mkFlake { inherit inputs; } {
        # IMPORTANT: declare all systems you want to expose
        systems = [
          "x86_64-linux" "aarch64-linux"
          "x86_64-darwin" "aarch64-darwin"
        ];

        # Apply our module to this repo
        imports = [ module ];

        # Export the module so other flakes can import it
        flake.flakeModule = module;
      };
}
