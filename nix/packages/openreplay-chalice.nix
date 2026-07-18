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
  openreplay-src,
  pythonEnv,
}:
writeShellApplication {
  name = "openreplay-chalice";
  runtimeInputs = [
    pythonEnv
    coreutils
  ];
  text = ''
    work="''${TMPDIR:-/tmp}/openreplay-chalice-work"
    rm -rf "$work" && mkdir -p "$work" && chmod 700 "$work"
    cp -r ${openreplay-src}/api/. "$work/" && chmod -R u+w "$work"
    cd "$work"
    [ -f env.default ] && mv -f env.default .env
    exec uvicorn app:app "$@"
  '';

  meta = {
    description = "OpenReplay dashboard REST API (chalice/FastAPI on uvicorn)";
    homepage = "https://github.com/openreplay/openreplay";
    license = lib.licenses.agpl3Only;
    mainProgram = "openreplay-chalice";
    platforms = lib.platforms.linux;
  };
}
