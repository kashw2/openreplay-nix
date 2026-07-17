# Single source of truth for the pinned OpenReplay checkout. The Go backend and
# the dashboard SPA build from this, and the NixOS module reads the schema SQL
# and Python API out of it — so the upstream version and hash are pinned in
# exactly one place. `.version` is exposed via passthru so consumers can inherit
# it (buildGoModule/mkDerivation `version`) instead of re-declaring the tag.
{ fetchFromGitHub }:
let
  version = "1.27.0";
in
(fetchFromGitHub {
  owner = "openreplay";
  repo = "openreplay";
  tag = "v${version}";
  hash = "sha256-EQKA3/mSGePfhvpjqff9HwXJG2e5wpSf86fK2f3yi8s=";
}).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit version;
    };
  })
