# OpenReplay's `@openreplay/sourcemap-uploader` CLI — the build-time companion to
# the sourcemapreader service. App teams run it in CI to push their JS sourcemaps
# to this OpenReplay instance's API (which stores them in the `sourcemaps` bucket
# the sourcemapreader reads), so minified error stack traces symbolicate back to
# original source. Packaged from the pinned checkout so the CLI version tracks the
# deployed server. Plain Node CLI (`bin: cli.js`, shebang present) — no build step.
{
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

  # glob-promise@6 declares a peer dep on glob@^8, but the package pins glob@^13;
  # without this npm tries to resolve the peer from the (offline) registry and
  # fails with ENOTCACHED. The pinned glob@13 is what the CLI actually uses.
  npmFlags = [ "--legacy-peer-deps" ];

  # The scoped package name (`@openreplay/sourcemap-uploader`) makes npm install
  # the string bin under bin/@openreplay/sourcemap-uploader. Expose a flat,
  # discoverable launcher so `nix run` / mainProgram resolve.
  postInstall = ''
    ln -s "@openreplay/sourcemap-uploader" "$out/bin/openreplay-sourcemap-uploader"
  '';

  meta.mainProgram = "openreplay-sourcemap-uploader";
}
