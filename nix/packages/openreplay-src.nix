# Single source of truth for the pinned OpenReplay checkout: every package builds from
# this. Pinned by `rev` (upstream only tags releases), re-exposed via passthru so
# nix-update can rewrite it. Update everything with:
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
  version = "main-backup-20260918193229-unstable-2026-09-18";
  src = fetchFromGitHub {
    owner = "openreplay";
    repo = "openreplay";
    # Upstream only tags releases, so `tag` would not pin a reproducible build.
    rev = "3fce37d89113ca7a06c9d9d767ba8d274df94d26";
    hash = "sha256-eLZ6c9CxOPD9DQpG7dPstKdXZo/5sZhCvVQ+GVgLiX8=";
  };
in
src.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit version src;

    # Bump the pin, then refresh each consumer's dependency hash (nix-update can't
    # reach them). The dashboard's missing-hashes.json isn't a hash it knows.
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
