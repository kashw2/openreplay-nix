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
          # Single pinned upstream checkout that every package inherits from.
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
          # Build-time CLI (not a server): upload JS sourcemaps in CI so stack
          # traces symbolicate. Kept out of the `openreplay` bundle below.
          openreplay-sourcemap-uploader = pkgs.callPackage ./nix/packages/openreplay-sourcemap-uploader.nix {
            inherit openreplay-src;
          };
          # The Python dashboard API isn't a built artifact — it runs from source
          # against an inline python env in the module, so it isn't packaged here.
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
