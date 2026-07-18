# OpenReplay's alerts scheduler — the same chalice codebase as openreplay-chalice,
# but its uvicorn entrypoint is app_alerts:app (an APScheduler loop, no
# authenticated HTTP surface). Like the API it runs from the pinned source's api/
# against a bundled Python env, copied to a writable workdir on each start.
# Extra args are forwarded to uvicorn; runtime config comes from the environment.
{
  lib,
  runCommand,
  writeShellApplication,
  coreutils,
  openreplay-src,
  pythonEnv,
}:
let
  pkg = writeShellApplication {
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
  };
in
pkg.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    # Smoke test: the wrapped uvicorn launches from the Python env and prints help.
    tests.smoke = runCommand "openreplay-alerts-smoke" { } ''
      ${lib.getExe pkg} --help > /dev/null
      touch $out
    '';
  };
})
