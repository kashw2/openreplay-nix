# OpenReplay's alerts scheduler: the openreplay-chalice codebase under a different uvicorn entrypoint (app_alerts:app, an APScheduler loop with no HTTP surface). Runs from the
# pinned source's api/, copied to a writable workdir on each start.
{
  lib,
  writeShellApplication,
  coreutils,
  openreplay-src,
  pythonEnv,
}:
writeShellApplication {
  name = "openreplay-alerts";
  runtimeInputs = [
    pythonEnv
    coreutils
  ];
  text = ''
    work="''${TMPDIR:-/tmp}/openreplay-alerts-work"
    rm -rf "$work" && mkdir -p "$work" && chmod 700 "$work"
    cp -r ${openreplay-src}/api/. "$work/" && chmod -R u+w "$work"
    cd "$work"
    [ -f env.default ] && mv -f env.default .env
    exec uvicorn app_alerts:app "$@"
  '';

  meta = {
    description = "OpenReplay alerts scheduler — APScheduler loop over the chalice codebase";
    homepage = "https://github.com/openreplay/openreplay";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
