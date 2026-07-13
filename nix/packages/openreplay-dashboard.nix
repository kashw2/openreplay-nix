# OpenReplay's dashboard SPA, built natively with Yarn Berry + Parcel — no
# Docker. We use the project's vendored Yarn (.yarn/releases/yarn-4.7.0.cjs)
# for the offline install rather than nixpkgs' yarnBerryConfigHook, because the
# hook's plugin trips over the builtin compat patches (fsevents/resolve/ts) in
# this lockfile. The fetched offline cache still comes from fetchYarnBerryDeps.
# Output is the static site the gateway nginx serves at /. The SPA calls its API
# same-origin (location.origin + /api), so no API URL is baked in.
{
  lib,
  stdenv,
  yarn-berry_4,
  nodejs_24,
  yarn,
  # frontend/ lives inside the single pinned OpenReplay checkout (see
  # openreplay-src.nix), so the source and version are pinned in one place.
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
    # Platform-specific optional deps (darwin/win/musl binaries) have no
    # checksum in the v8 lockfile; their hashes are supplied here. Regenerate
    # with: yarn-berry_4.yarn-berry-fetcher missing-hashes frontend/yarn.lock
    missingHashes = ./openreplay-dashboard-missing-hashes.json;
    hash = "sha256-JkVJDmqWPlXXT2S2Ct9Dmp2pKhnMc4vjqo4/3xOdy2E=";
  };

  nativeBuildInputs = [ nodejs_24 ];

  env = {
    # Parcel needs a large heap (matches upstream frontend/Dockerfile).
    NODE_OPTIONS = "--max-old-space-size=10240";
    # Hermetic Yarn Berry install: no telemetry, no shared global cache, no
    # network. HOME and YARN_CACHE_FOLDER stay in configurePhase since they
    # depend on runtime paths ($PWD / a fresh mktemp dir).
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
