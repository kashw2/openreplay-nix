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
  hash = "sha256-Y0iDGb1m/b0OWdNjxdiqp7zGr4H1KoN4wTlRiCZ9ezc=";
}).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit version;
    };
  })
