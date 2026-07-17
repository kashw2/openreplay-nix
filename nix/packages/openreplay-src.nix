# Single source of truth for the pinned OpenReplay checkout: every package builds
# from this and the module reads schema SQL / Python API out of it, so the rev and
# hash are pinned in one place. `.version` is exposed via passthru so consumers
# inherit it instead of re-declaring the tag.
#
# OpenReplay only moves its release tag on releases, not on every commit to main, so
# a tag can't guarantee the same commit across rebuilds — we pin an explicit `rev`.
# `.src` is re-exposed via passthru (pointing at the pristine fetcher, which keeps
# its `rev`/`url`/`outputHash`) so `nix-update` can locate this file and rewrite the
# `rev` + `hash` in place. Update the whole repo with a single command:
#
#   nix-update --flake openreplay-src --use-update-script
#
# which runs the `passthru.updateScript` below: it bumps the pin to the latest main
# commit, then re-pins every consumer hash the new source invalidates.
{
  lib,
  fetchFromGitHub,
  writeShellApplication,
  nix-update,
  git,
  yarn-berry_4,
}:
let
  # `nix-update --version=branch` rewrites this to `<release>-unstable-YYYY-MM-DD`.
  version = "1.27.0";
  src = fetchFromGitHub {
    owner = "openreplay";
    repo = "openreplay";
    # tag = "v${version}";
    rev = "e702456e66ff8a4d546abe1c3fa72c5c23154a4d";
    hash = "sha256-V4IZQJPW2yvCEzjHm5ubkAKGOoIdMnOA4fbpBatB0HQ=";
  };
in
src.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit version src;

    updateScript = lib.getExe (writeShellApplication {
      name = "openreplay-update";
      runtimeInputs = [
        nix-update
        git
        yarn-berry_4.yarn-berry-fetcher
      ];
      text = ''
        nix-update --flake --version=branch=main openreplay-src

        src="$(nix build --no-link --print-out-paths .#openreplay-src)"
        yarn-berry-fetcher missing-hashes "$src/frontend/yarn.lock" \
          > nix/packages/openreplay-dashboard-missing-hashes.json

        for pkg in \
          openreplay-backend \
          openreplay-assist \
          openreplay-sourcemapreader \
          openreplay-sourcemap-uploader \
          openreplay-dashboard; do
          echo "==> refreshing dependency hashes for $pkg" >&2
          nix-update --flake --version=skip "$pkg"
        done
      '';
    });
  };
})
