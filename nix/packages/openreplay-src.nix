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
  # tag = "v${version}";
  rev = "a83ca70ce81162c228a11d33fd28a0f0fc547221";
  hash = "sha256-rvdNEf1FUxqnLIPIFLdNF8+IPTa6KQEMOph1k+kCZa4=";
}).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit version;
    };
  })
