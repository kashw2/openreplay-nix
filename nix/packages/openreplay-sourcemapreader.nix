# OpenReplay's "sourcemapreader": the Node/Express server the dashboard API calls to
# symbolicate JS stack traces. No build step.
#
# server.js require()s ./utils/{HeapSnapshot,health,helper}, which upstream's build.sh
# copies from the shared assist/utils tree; that dir is gitignored, so we copy it too.
{
  lib,
  buildNpmPackage,
  nodejs_24,
  makeWrapper,
  openreplay-src,
}:
buildNpmPackage {
  pname = "openreplay-sourcemapreader";
  inherit (openreplay-src) version;

  src = openreplay-src + "/sourcemapreader";

  npmDepsHash = "sha256-uSSUo2hZI87DN6znti6w/ZuUy2aGbVpk2927O5IEdrI=";

  # Plain Node service — no bundler/build script to run.
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  # Copy into the *installed* module, not the build dir: `utils` is gitignored and
  # buildNpmPackage's install honours that, so a build-tree copy would be dropped.
  postInstall = ''
    module="$out/lib/node_modules/sourcemapreader"
    cp -R ${openreplay-src}/assist/utils "$module/utils"

    # source-map needs mappings.wasm. Bake MAPPING_WASM in so the launcher doesn't
    # depend on npm's hoisting layout.
    wasm="$(find "$module" -path '*source-map/lib/mappings.wasm' | head -n1)"
    [ -n "$wasm" ] || { echo "mappings.wasm not found in source-map dependency" >&2; exit 1; }
    makeWrapper ${lib.getExe nodejs_24} $out/bin/openreplay-sourcemapreader \
      --add-flags "$module/server.js" \
      --set MAPPING_WASM "$wasm"
  '';

  meta = {
    description = "OpenReplay sourcemapreader — symbolicates JS stack traces from uploaded sourcemaps";
    homepage = "https://github.com/openreplay/openreplay";
    license = lib.licenses.mit;
    mainProgram = "openreplay-sourcemapreader";
    platforms = lib.platforms.linux;
  };
}
