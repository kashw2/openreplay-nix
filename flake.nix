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
          openreplay = pkgs.symlinkJoin {
            name = "openreplay";
            paths = [
              openreplay-backend
              openreplay-dashboard
              openreplay-assist
              openreplay-sourcemapreader
            ];
          };
        in
        {
          inherit
            openreplay-src
            openreplay-chalice
            openreplay-alerts
            openreplay-player
            openreplay-backend
            openreplay-dashboard
            openreplay-assist
            openreplay-sourcemapreader
            openreplay-sourcemap-uploader
            openreplay
            ;
          default = openreplay;
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
      nixosModules = rec {
        openreplay = import ./nix/nixos/openreplay.nix { inherit self; };
        default = openreplay;
      };
      checks.${system} = {
        openreplay-module = import ./nix/tests/openreplay.nix {
          inherit self pkgs;
        };
      };
    };
}
