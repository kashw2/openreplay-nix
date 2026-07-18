# `@openreplay/sourcemap-uploader` CLI — build-time companion to sourcemapreader.
# App teams run it in CI to push JS sourcemaps to this instance's API (stored in
# the `sourcemaps` bucket the reader consumes), so error stack traces symbolicate.
# Packaged from the pinned checkout to track the server version. Plain Node CLI, no
# build step.
{
  lib,
  runCommand,
  buildNpmPackage,
  openreplay-src,
}:
buildNpmPackage (finalAttrs: {
  pname = "openreplay-sourcemap-uploader";
  inherit (openreplay-src) version;

  src = openreplay-src + "/sourcemap-uploader";

  npmDepsHash = "sha256-FLxlDz3BVNkISvGEhpCPVvpNRjboo9CvcQtynckfVqA=";

  # Plain Node CLI — the only script is `lint`; there is no build to run.
  dontNpmBuild = true;

  # glob-promise@6 peer-deps glob@^8 but the package pins glob@^13; without this
  # npm tries to resolve the peer from the offline registry and fails (ENOTCACHED).
  npmFlags = [ "--legacy-peer-deps" ];

  # The scoped name nests npm's string bin under bin/@openreplay/; add a flat
  # launcher so `nix run` / mainProgram resolve.
  postInstall = ''
    ln -s "@openreplay/sourcemap-uploader" "$out/bin/openreplay-sourcemap-uploader"
  '';

  # Smoke test: the CLI's --help must load and exit cleanly.
  passthru.tests.smoke = runCommand "openreplay-sourcemap-uploader-smoke" { } ''
    ${lib.getExe finalAttrs.finalPackage} --help > /dev/null
    touch $out
  '';

  meta.mainProgram = "openreplay-sourcemap-uploader";
})
