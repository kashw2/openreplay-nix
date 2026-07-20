# OpenReplay's chalice dashboard REST API (FastAPI on uvicorn, app:app), run from
# the pinned source's api/ against a bundled Python env. uvicorn needs a writable
# workdir holding the app + .env, so the source is copied out of the read-only
# store on each start. Extra args are forwarded to uvicorn, so callers pass
# --host/--port/flags; runtime config is read from the process environment
# (python-decouple).
{
  lib,
  writeShellApplication,
  coreutils,
  applyPatches,
  openreplay-src,
  pythonEnv,
}:
let
  patchedApi = applyPatches {
    name = "openreplay-api-baremetal-health";
    src = openreplay-src + "/api";
    patches = [ ./openreplay-chalice-baremetal-health.patch ];
  };
in
writeShellApplication {
  name = "openreplay-chalice";
  runtimeInputs = [
    pythonEnv
    coreutils
  ];
  text = ''
    work="''${TMPDIR:-/tmp}/openreplay-chalice-work"
    rm -rf "$work" && mkdir -p "$work" && chmod 700 "$work"
    cp -r ${patchedApi}/. "$work/" && chmod -R u+w "$work"
    cd "$work"
    [ -f env.default ] && mv -f env.default .env
    exec uvicorn app:app "$@"
  '';

  meta = {
    description = "OpenReplay chalice dashboard REST API (FastAPI on uvicorn)";
    homepage = "https://github.com/openreplay/openreplay";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
