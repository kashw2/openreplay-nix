# OpenReplay's dashboard SPA (Yarn Berry + Parcel, no Docker). Uses the vendored
# Yarn (.yarn/releases/yarn-4.7.0.cjs) for the offline install, not nixpkgs'
# yarnBerryConfigHook, whose plugin trips over this lockfile's builtin compat
# patches (fsevents/resolve/ts); the offline cache still comes from
# fetchYarnBerryDeps. Output is the static site nginx serves at /; the SPA calls
# its API same-origin (location.origin + /api), so no API URL is baked in.
{
  lib,
  stdenv,
  yarn-berry_4,
  nodejs_24,
  yarn,
  # frontend/ lives in the pinned checkout (openreplay-src.nix) — one pin.
  openreplay-src,
}:
let
  src = openreplay-src + "/frontend";
in
stdenv.mkDerivation {
  pname = "openreplay-dashboard";
  inherit (openreplay-src) version;
  inherit src;

  offlineCache = yarn-berry_4.fetchYarnBerryDeps {
    inherit src;
    # Platform-specific optional deps (darwin/win/musl) lack a checksum in the v8
    # lockfile; regenerate with: yarn-berry_4.yarn-berry-fetcher missing-hashes frontend/yarn.lock
    missingHashes = ./openreplay-dashboard-missing-hashes.json;
    hash = "sha256-JkVJDmqWPlXXT2S2Ct9Dmp2pKhnMc4vjqo4/3xOdy2E=";
  };

  nativeBuildInputs = [ nodejs_24 ];

  env = {
    # Parcel needs a large heap (matches upstream frontend/Dockerfile).
    NODE_OPTIONS = "--max-old-space-size=10240";
    # Hermetic install: no telemetry/global-cache/network. HOME and
    # YARN_CACHE_FOLDER are set in configurePhase (they need runtime paths).
    YARN_ENABLE_TELEMETRY = "false";
    YARN_ENABLE_GLOBAL_CACHE = "false";
    YARN_ENABLE_NETWORK = "false";
  };

  # Player CSS-rewrite fix — see the patch header for the full rationale.
  patches = [ ./openreplay-dashboard-player-css.patch ];

  configurePhase = ''
    runHook preConfigure
    export HOME="$(mktemp -d)"
    mkdir -p .yarn/cache
    cp -r --reflink=auto "$offlineCache"/cache/. .yarn/cache/
    chmod -R u+w .yarn/cache
    export YARN_CACHE_FOLDER="$PWD/.yarn/cache"
    # skip-build: don't run postinstall scripts (cypress downloads a binary
    # over the network; native modules use their prebuilt binaries at runtime).
    node .yarn/releases/yarn-4.7.0.cjs install --immutable --mode=skip-build
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    # Upstream Dockerfile seeds build-time env from .env.sample.
    [ -f .env.sample ] && cp .env.sample .env || true
    ${lib.getExe yarn} build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r public $out
    runHook postInstall
  '';
}
