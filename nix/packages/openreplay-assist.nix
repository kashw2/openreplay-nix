# OpenReplay's "assist" service — the Node.js + socket.io signalling server that
# powers live sessions and co-browsing (WebRTC media stays peer-to-peer between the
# agent's and visitor's browsers; this only brokers the connection). Built natively
# from the pinned checkout. It has no build step, so we install the package + its
# deps and wrap `node server.js` as the launcher.
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
