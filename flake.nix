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
            openreplay-backend
            openreplay-dashboard
            openreplay-assist
            openreplay-sourcemapreader
            openreplay-sourcemap-uploader
            openreplay
            ;
          default = openreplay;
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
