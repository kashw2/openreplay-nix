# `@openreplay/player`: session-replay engine, consumed from source by bundlers
# (nothing to compile). Publishes src + installed node_modules so a consumer can
# resolve the player's bare imports. Pass to openreplay-mcp's `withPlayer`.
{
  lib,
  stdenv,
  fetchYarnDeps,
  fixup-yarn-lock,
  yarn,
  nodejs_24,
  openreplay-src,
}:
let
  src = openreplay-src + "/player";
in
stdenv.mkDerivation {
  pname = "openreplay-player";
  inherit (openreplay-src) version;
  inherit src;

  nativeBuildInputs = [
    yarn
    fixup-yarn-lock
    nodejs_24
  ];

  offlineCache = fetchYarnDeps {
    yarnLock = src + "/yarn.lock";
    hash = "sha256-+wNEo0qviffgX7bf7UphdjHseiwrKJwhWe9I0S8Y9cU=";
  };

  configurePhase = ''
    runHook preConfigure
    export HOME="$(mktemp -d)"
    fixup-yarn-lock yarn.lock
    yarn config --offline set yarn-offline-mirror "$offlineCache"
    yarn install --offline --frozen-lockfile --ignore-scripts --ignore-engines
    patchShebangs node_modules
    runHook postConfigure
  '';

  # Source package — nothing to build.
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r package.json tsconfig.json src node_modules "$out/"
    runHook postInstall
  '';

  meta = {
    description = "OpenReplay session-replay player (source + deps) — build input for the MCP app UI";
    homepage = "https://github.com/openreplay/openreplay";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
