# OpenReplay's "sourcemapreader": the Node/Express server the dashboard API calls
# to symbolicate JS stack traces — fetches uploaded sourcemaps from object storage
# and maps minified frames back to source. No build step: install deps and wrap
# `node server.js`.
#
# server.js require()s ./utils/{HeapSnapshot,health,helper}, which upstream's
# build.sh copies from the shared assist/utils tree; that dir is gitignored under
# sourcemapreader/, so we reproduce the copy from the pinned checkout.
{
  lib,
  runCommand,
  buildNpmPackage,
  nodejs_24,
  makeWrapper,
  openreplay-src,
}:
buildNpmPackage (finalAttrs: {
  pname = "openreplay-sourcemapreader";
  inherit (openreplay-src) version;

  src = openreplay-src + "/sourcemapreader";

  npmDepsHash = "sha256-uSSUo2hZI87DN6znti6w/ZuUy2aGbVpk2927O5IEdrI=";

  # Plain Node service — no bundler/build script to run.
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  # Copy assist/utils into the *installed* module, not the build dir:
  # sourcemapreader's .gitignore lists `utils`, and buildNpmPackage's install
  # honours it (npm-pack semantics), so a build-tree copy would be dropped from $out.
  postInstall = ''
    module="$out/lib/node_modules/sourcemapreader"
    cp -R ${openreplay-src}/assist/utils "$module/utils"

    # source-map needs mappings.wasm (shipped in the npm package). Pin it and bake
    # MAPPING_WASM into the wrapper so the launcher doesn't rely on npm's
    # (unstable) hoisting layout.
    wasm="$(find "$module" -path '*source-map/lib/mappings.wasm' | head -n1)"
    [ -n "$wasm" ] || { echo "mappings.wasm not found in source-map dependency" >&2; exit 1; }
    makeWrapper ${lib.getExe nodejs_24} $out/bin/openreplay-sourcemapreader \
      --add-flags "$module/server.js" \
      --set MAPPING_WASM "$wasm"
  '';

  # Smoke test: the server starts and initialises source-map's mappings.wasm
  # (the bit the custom postInstall wires up), then we stop it.
  passthru.tests.smoke = runCommand "openreplay-sourcemapreader-smoke" { } ''
    "${lib.getExe finalAttrs.finalPackage}" > log 2>&1 &
    pid=$!
    for _ in $(seq 1 60); do
      grep -q "SR App listening" log && break
      sleep 1
    done
    kill "$pid" 2>/dev/null || true
    grep -q "SR App listening" log
    touch $out
  '';

  meta.mainProgram = "openreplay-sourcemapreader";
})
