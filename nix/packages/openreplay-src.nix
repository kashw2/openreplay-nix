# Single source of truth for the pinned OpenReplay checkout: every package builds
# from this and the module reads schema SQL / Python API out of it, so the version
# and hash are pinned in one place. `.version` is exposed via passthru so consumers
# inherit it instead of re-declaring the tag.
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
