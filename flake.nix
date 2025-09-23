{
  description = "Glossary tools (jq) exported as a flake-parts module with apps/packages/devShell";

  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url  = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ self, flake-parts, ... }:
    let
      # Reusable flake-parts module consumed by other flakes
      module = { config, lib, inputs, ... }:
        let
          # Input name that consumers should use for this flake; can be overridden
          srcName = config.glossTools.sourceInputName or "gloss-tools";

          # Resolve the flake that contains the scripts:
          # - when imported by another flake: inputs.<srcName>
          # - when used locally: inputs.self
          sourceFlake =
            if builtins.hasAttr srcName inputs
            then builtins.getAttr srcName inputs
            else inputs.self;

          # Absolute paths to scripts in the source flake
          genScript  = "${sourceFlake}/scripts/generate_glossary.sh";
          fillScript = "${sourceFlake}/scripts/fill_glossary.sh";

          # Path to Zisk conventions JSON in this repo
          ziskJson   = ./sources/zisk-gloss-conventions-2024.json;
        in {
          options.glossTools.sourceInputName = lib.mkOption {
            type = lib.types.str;
            default = "gloss-tools";
            description = "Glossing tool for mapping interlinear glosses to Zisk JSON format.";
          };

          config.perSystem = { pkgs, ... }:
            let
              # Wrap raw scripts as runnable packages with jq available at runtime
              generateGlossary = pkgs.writeShellApplication {
                name = "generate-glossary";
                runtimeInputs = [ pkgs.jq ];
                text = builtins.readFile genScript;
              };

              fillGlossary = pkgs.writeShellApplication {
                name = "fill-glossary";
                runtimeInputs = [ pkgs.jq ];
                text = builtins.readFile fillScript;
              };

              # Ship the Zisk JSON as a package output for easy reference from consumers
              ziskConventions = pkgs.writeText "zisk-gloss-conventions-2024.json"
                (builtins.readFile ziskJson);
            in {
              # Packages (buildable artifacts)
              packages.generate-glossary = generateGlossary;
              packages.fill-glossary     = fillGlossary;
              packages.zisk-conventions  = ziskConventions;

              # Apps (runnable via `nix run`)
              apps.generate-glossary = {
                type = "app";
                program = "${generateGlossary}/bin/generate-glossary";
              };
              apps.fill-glossary = {
                type = "app";
                program = "${fillGlossary}/bin/fill-glossary";
              };

              # Dev shell: jq + make + both commands on PATH
              devShells.default = pkgs.mkShell {
                packages = (with pkgs; [
                  jq
                  gnumake
                ]) ++
                [
                  generateGlossary
                  fillGlossary
                ];
              };
            };
        };
    in
      # Provider also uses the module locally and exports it
      flake-parts.lib.mkFlake { inherit inputs; } {
        # Expose outputs for all major platforms
        systems = [
          "x86_64-linux" "aarch64-linux"
          "x86_64-darwin" "aarch64-darwin"
        ];

        # Apply module locally (so `nix run` works in this repo too)
        imports = [ module ];

        # Export the module for consumers
        flake.flakeModule = module;
      };
}
