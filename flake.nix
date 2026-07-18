{
  description = "OpenReplay backend, API, and dashboard packaged natively with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} =
        let
          openreplay-src = pkgs.callPackage ./nix/packages/openreplay-src.nix { };
          openreplay-backend = pkgs.callPackage ./nix/packages/openreplay-backend.nix {
            inherit openreplay-src;
          };
          openreplay-dashboard = pkgs.callPackage ./nix/packages/openreplay-dashboard.nix {
            inherit openreplay-src;
          };
          openreplay-assist = pkgs.callPackage ./nix/packages/openreplay-assist.nix {
            inherit openreplay-src;
          };
          openreplay-sourcemapreader = pkgs.callPackage ./nix/packages/openreplay-sourcemapreader.nix {
            inherit openreplay-src;
          };
          openreplay-sourcemap-uploader = pkgs.callPackage ./nix/packages/openreplay-sourcemap-uploader.nix {
            inherit openreplay-src;
          };
          # The chalice dashboard API + alerts scheduler run from ${openreplay-src}/api against this interpreter
          # (uvicorn + the deps from api/requirements.txt) and therefore requires python packages in it's environment
          pythonEnv = pkgs.python313.withPackages (
            ps: with ps; [
              fastapi
              uvicorn
              psycopg
              psycopg-pool
              psycopg2
              clickhouse-connect
              boto3
              pyjwt
              python-decouple
              pydantic
              email-validator
              apscheduler
              redis
              elasticsearch
              jira
              cachetools
              requests
              urllib3
            ]
          );
          openreplay-chalice = pkgs.callPackage ./nix/packages/openreplay-chalice.nix {
            inherit openreplay-src pythonEnv;
          };
          openreplay-alerts = pkgs.callPackage ./nix/packages/openreplay-alerts.nix {
            inherit openreplay-src pythonEnv;
          };
          openreplay-player = pkgs.callPackage ./nix/packages/openreplay-player.nix {
            inherit openreplay-src;
          };
          # Server only; for the interactive UI, override with the player:
          #   openreplay-mcp.override { withPlayer = openreplay-player; }
          openreplay-mcp = pkgs.callPackage ./nix/packages/openreplay-mcp.nix {
            inherit openreplay-src;
          };
          openreplay = pkgs.symlinkJoin {
            name = "openreplay";
            paths = [
              openreplay-backend
              openreplay-dashboard
              openreplay-assist
              openreplay-sourcemapreader
            ];
            meta = {
              description = "OpenReplay stack — backend, dashboard, assist, and sourcemapreader combined";
              homepage = "https://github.com/openreplay/openreplay";
              license = pkgs.lib.licenses.mit;
              platforms = pkgs.lib.platforms.linux;
            };
          };
        in
        {
          inherit
            openreplay-src
            openreplay-chalice
            openreplay-alerts
            openreplay-player
            openreplay-mcp
            openreplay-backend
            openreplay-dashboard
            openreplay-assist
            openreplay-sourcemapreader
            openreplay-sourcemap-uploader
            openreplay
            ;
          default = openreplay;
        };
      # `nix run .#openreplay-mcp` / `.#openreplay-sourcemap-uploader` for the CLIs.
      apps.${system} = {
        openreplay-mcp = {
          type = "app";
          program = pkgs.lib.getExe self.packages.${system}.openreplay-mcp;
        };
        openreplay-sourcemap-uploader = {
          type = "app";
          program = pkgs.lib.getExe self.packages.${system}.openreplay-sourcemap-uploader;
        };
      };
      # `nix-update` for the update workflow (see .github/workflows/update.yml),
      # entered with `nix develop`.
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.nix-update
          pkgs.git
        ];
        # nix-update's --use-update-script builds a wrapper via `import <nixpkgs>`,
        # so it needs <nixpkgs> on NIX_PATH (CI gets this from install-nix-action).
        NIX_PATH = "nixpkgs=flake:nixpkgs";
      };
      formatter.${system} = pkgs.nixfmt;
      nixosModules = rec {
        openreplay = import ./nix/nixos/openreplay.nix { inherit self; };
        default = openreplay;
      };
      checks.${system} = {
        openreplay-module = import ./nix/tests/openreplay.nix {
          inherit self pkgs;
        };
        # Fails the flake check if any tracked .nix file isn't nixfmt-clean.
        formatting = pkgs.runCommand "check-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
          cd ${self}
          find . -name '*.nix' -print0 | xargs -0 nixfmt --check
          touch $out
        '';
      };
    };
}
