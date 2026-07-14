# OpenReplay's "sourcemapreader" service — the Node.js/Express server the
# dashboard API calls to symbolicate JS stack traces: it fetches uploaded
# sourcemaps from object storage and maps minified frames back to source.
# Built natively from the pinned checkout. It has no build step, so we install
# the package + its deps and wrap `node server.js` as the launcher.
#
# Upstream's build.sh copies the shared `assist/utils` tree into the service as
# `utils/` (server.js require()s ./utils/{HeapSnapshot,health,helper}); that
# directory is gitignored inside sourcemapreader/, so we reproduce the copy from
# the same pinned checkout in postPatch.
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

  # server.js pulls its health/heap/logging helpers from ./utils, which upstream
  # populates from the shared assist/utils tree at image-build time. We copy it
  # into the installed module (not the build dir): sourcemapreader's .gitignore
  # lists `utils`, and buildNpmPackage's install honours it via npm-pack
  # semantics, so a build-tree copy would be dropped from $out.
  postInstall = ''
    module="$out/lib/node_modules/sourcemapreader"
    cp -R ${openreplay-src}/assist/utils "$module/utils"

    # source-map symbolication needs its mappings.wasm; upstream downloads it from
    # unpkg at image-build time, but the npm package already ships it. Pin it to a
    # stable path and bake MAPPING_WASM into the wrapper so the launcher doesn't
    # depend on npm's (unstable) hoisting layout.
    wasm="$(find "$module" -path '*source-map/lib/mappings.wasm' | head -n1)"
    [ -n "$wasm" ] || { echo "mappings.wasm not found in source-map dependency" >&2; exit 1; }
    makeWrapper ${lib.getExe nodejs_24} $out/bin/openreplay-sourcemapreader \
      --add-flags "$module/server.js" \
      --set MAPPING_WASM "$wasm"
  '';

  meta.mainProgram = "openreplay-sourcemapreader";
}
