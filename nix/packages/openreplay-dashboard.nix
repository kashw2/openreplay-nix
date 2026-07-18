{
  lib,
  stdenv,
  yarn-berry_4,
  nodejs_24,
  yarn,
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
    YARN_ENABLE_GLOBAL_CACHE = "false";
    YARN_ENABLE_NETWORK = "false";
  };

  # Frontend source fixes — see each patch header for the full rationale.
  patches = [
    ./openreplay-dashboard-player-css.patch
    ./openreplay-dashboard-assist-confirm.patch
  ];

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

  meta = {
    description = "OpenReplay dashboard — the frontend web UI (static build output)";
    homepage = "https://github.com/openreplay/openreplay";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
