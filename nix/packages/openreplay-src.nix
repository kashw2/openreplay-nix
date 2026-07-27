# Single source of truth for the pinned OpenReplay checkout: every package builds
# from this. We pin an explicit `rev` (upstream only tags on releases, not per
# commit). `.src` is re-exposed via passthru so nix-update can rewrite the pin.
# Update everything with:
#
#   nix-update --flake openreplay-src --use-update-script
{
  lib,
  fetchFromGitHub,
  writeShellApplication,
  nix-update,
  git,
  yarn-berry_4,
}:
let
  version = "main-backup-20260723113021-unstable-2026-07-23";
  src = fetchFromGitHub {
    owner = "openreplay";
    repo = "openreplay";
    # Upstream doesn't release a new tag on every commit into main so builds cannot be idempotent using the `tag` attr
    rev = "dbb68105e865052d6ec0d49c9d2d13cf5d5f4aef";
    hash = "sha256-SFF+FYZudB7wyD9iZAwGEFuPyOZ/Vp28fs4WIE5FTTo=";
  };
in
src.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit version src;

    # Bump the pin, then refresh each consumer's dependency hash against the new
    # source (nix-update on this alone can't reach them). The dashboard's
    # missing-hashes.json isn't a hash nix-update knows, so regenerate it first.
    updateScript = lib.getExe (writeShellApplication {
      name = "openreplay-update";
      runtimeInputs = [
        nix-update
        git
        yarn-berry_4.yarn-berry-fetcher
      ];
      text = ''
        # Latest main commit (rev + hash follow the commit, not a tag).
        nix-update --flake --version=branch=main openreplay-src

        # Regenerate the dashboard's yarn missing-hashes from the new source.
        src="$(nix build --no-link --print-out-paths .#openreplay-src)"
        yarn-berry-fetcher missing-hashes "$src/frontend/yarn.lock" \
          > nix/packages/openreplay-dashboard-missing-hashes.json

        for pkg in \
          openreplay-backend \
          openreplay-assist \
          openreplay-sourcemapreader \
          openreplay-sourcemap-uploader \
          openreplay-dashboard \
          openreplay-player \
          openreplay-mcp; do
          echo "refreshing dependency hashes for $pkg" >&2
          nix-update --flake --version=skip "$pkg"
        done
      '';
    });
  };
})
