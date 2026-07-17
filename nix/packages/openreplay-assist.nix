# OpenReplay's "assist" service: the Node.js + socket.io signalling server for live
# sessions / co-browsing (WebRTC media is peer-to-peer; this only brokers it). No
# build step — install deps and wrap `node server.js`.
{
  lib,
  buildNpmPackage,
  nodejs_24,
  makeWrapper,
  openreplay-src,
}:
buildNpmPackage {
  pname = "openreplay-assist";
  inherit (openreplay-src) version;

  src = openreplay-src + "/assist";

  npmDepsHash = "sha256-NDB4LpekLD/cFvDpX3tXkXjlCX06qegMl5fgo0BbY7Q=";

  # Plain Node service — no bundler/build script to run.
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    makeWrapper ${lib.getExe nodejs_24} $out/bin/openreplay-assist \
      --add-flags $out/lib/node_modules/assist-server/server.js
  '';

  meta.mainProgram = "openreplay-assist";
}
