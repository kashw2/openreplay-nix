# `@openreplay/sourcemap-uploader` CLI: app teams run it in CI to push JS sourcemaps to
# this instance's API (the `sourcemaps` bucket the reader consumes). Packaged from the
# pinned checkout to track the server version. No build step.
{
  lib,
  buildNpmPackage,
  openreplay-src,
}:
buildNpmPackage {
  pname = "openreplay-sourcemap-uploader";
  inherit (openreplay-src) version;

  src = openreplay-src + "/sourcemap-uploader";

  npmDepsHash = "sha256-FLxlDz3BVNkISvGEhpCPVvpNRjboo9CvcQtynckfVqA=";

  # Plain Node CLI — the only script is `lint`; there is no build to run.
  dontNpmBuild = true;

  # glob-promise@6 peer-deps glob@^8 but the package pins glob@^13; npm would try the
  # offline registry and fail (ENOTCACHED).
  npmFlags = [ "--legacy-peer-deps" ];

  # The scoped name nests npm's string bin under bin/@openreplay/; add a flat
  # launcher so `nix run` / mainProgram resolve.
  postInstall = ''
    ln -s "@openreplay/sourcemap-uploader" "$out/bin/openreplay-sourcemap-uploader"
  '';

  meta = {
    description = "OpenReplay sourcemap-uploader — CLI that pushes JS sourcemaps to an OpenReplay instance";
    homepage = "https://github.com/openreplay/openreplay";
    license = lib.licenses.mit;
    mainProgram = "openreplay-sourcemap-uploader";
    platforms = lib.platforms.linux;
  };
}
