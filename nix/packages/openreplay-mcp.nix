# OpenReplay's stdio MCP server (`mcp_app`). The server bundle is always built and
# self-contained (runtime closure = node + bundle). The interactive UI
# (dist/index.html) is gated on `withPlayer`:
#   * null (default) → server only. Tools still return data as text; MCP-UI hosts
#     just have no panel to render.
#   * <openreplay-player> → also build the UI (vite inlines the player source).
{
  lib,
  stdenv,
  fetchYarnDeps,
  fixup-yarn-lock,
  yarn,
  nodejs_24,
  makeWrapper,
  openreplay-src,
  withPlayer ? null,
}:
let
  mcpSrc = openreplay-src + "/mcp_app";
in
stdenv.mkDerivation {
  pname = "openreplay-mcp";
  inherit (openreplay-src) version;

  src = mcpSrc;

  # Drop the unused `file:../player` dep + fix the vite alias to ../player.
  patches = [ ./openreplay-mcp-decouple-player.patch ];

  nativeBuildInputs = [
    yarn
    fixup-yarn-lock
    nodejs_24
    makeWrapper
  ];

  offlineCache = fetchYarnDeps {
    yarnLock = mcpSrc + "/yarn.lock";
    hash = "sha256-pwjqNHamCaswR98XXWn8UR+pudWJJc3xutFVkiB4S5M=";
  };

  buildPhase = ''
    runHook preBuild
    export HOME="$(mktemp -d)"

    ${lib.optionalString (withPlayer != null) ''
      # Player as the ../player sibling the vite alias resolves.
      cp -r --no-preserve=mode,ownership ${withPlayer} ../player
    ''}

    fixup-yarn-lock yarn.lock
    yarn config --offline set yarn-offline-mirror "$offlineCache"
    yarn install --offline --frozen-lockfile --ignore-scripts --ignore-engines
    patchShebangs node_modules

    ${lib.optionalString (withPlayer != null) ''
      # UI → dist/index.html.
      yarn --offline build:ui
    ''}
    node_modules/.bin/esbuild server.ts \
      --bundle --platform=node --format=esm --target=node20 \
      --outfile=dist-server/server.mjs

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    app="$out/lib/openreplay-mcp"
    mkdir -p "$app"
    cp -r dist-server "$app/dist-server"
    ${lib.optionalString (withPlayer != null) ''cp -r dist "$app/dist"''}

    makeWrapper ${lib.getExe nodejs_24} "$out/bin/openreplay-mcp" \
      --add-flags "$app/dist-server/server.mjs"
    runHook postInstall
  '';

  meta = {
    description =
      "OpenReplay MCP server — browse sessions, charts, and replays from an MCP host"
      + lib.optionalString (withPlayer != null) " (with interactive UI)";
    homepage = "https://docs.openreplay.com/en/mcp/";
    license = [ lib.licenses.mit ] ++ lib.optional (withPlayer != null) lib.licenses.agpl3Only;
    mainProgram = "openreplay-mcp";
    platforms = lib.platforms.linux;
  };
}
