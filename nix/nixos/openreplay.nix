{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.openreplay;

  # ClickHouse's Go/Python clients scan the tz database at startup; NixOS has no
  # /usr/share/zoneinfo, so without TZDIR pointed at nixpkgs tzdata they fail
  # with "Could not determine local time zone".
  tzDir = "${pkgs.tzdata}/share/zoneinfo";

  # Redis-Streams "topics" (OSS queues through Redis, not Kafka) — upstream
  # Dockerfile defaults, marked required by the config structs so passed explicitly.
  topics = {
    TOPIC_RAW_WEB = "raw";
    TOPIC_RAW_IOS = "raw-ios";
    TOPIC_RAW_IMAGES = "raw-images";
    TOPIC_RAW_ASSETS = "raw-assets";
    TOPIC_RAW_ANALYTICS = "raw-analytics";
    TOPIC_ANALYTICS = "analytics";
    TOPIC_CACHE = "cache";
    TOPIC_TRIGGER = "trigger";
    TOPIC_MOBILE_TRIGGER = "mobile-trigger";
    TOPIC_CANVAS_IMAGES = "canvas-images";
    TOPIC_CANVAS_TRIGGER = "canvas-trigger";
    TOPIC_STORAGE_FAILOVER = "storage-failover";
  };

  # Non-secret object-storage env shared by the services that touch S3.
  objectStorage = {
    CLOUD = "aws";
    AWS_REGION = cfg.s3.region;
    AWS_ACCESS_KEY_ID = cfg.s3.accessKey;
    AWS_ENDPOINT = cfg.s3.endpoint;
    AWS_SKIP_SSL_VALIDATION = lib.boolToString cfg.s3.disableSslVerify;
    USE_S3_TAGS = "false";
  };

  # APIs build the live-session URL as sprintf(ASSIST_URL, ASSIST_KEY), so the %s
  # placeholder is required (matches upstream chalice/api env).
  assistUrl = "http://${cfg.listenAddress}:${toString cfg.assist.port}/assist/%s";
  # systemd expands %-specifiers in Environment= values, eating the %s above;
  # double it so the process receives a literal %s.
  assistUrlEnv = lib.replaceStrings [ "%" ] [ "%%" ] assistUrl;

  # SMTP env shared by the two services that send mail (the Python dashboard API
  # and the alerts scheduler). Read via python-decouple. A null host leaves email
  # unconfigured (no EMAIL_* emitted, so upstream's empty env.default disables
  # sending). EMAIL_PASSWORD is a secret, carried through allSecrets/LoadCredential.
  smtpEnv = lib.optionalAttrs (cfg.smtp.host != null) {
    EMAIL_FROM = cfg.smtp.from;
    EMAIL_HOST = cfg.smtp.host;
    EMAIL_PORT = toString cfg.smtp.port;
    EMAIL_USER = lib.optionalString (cfg.smtp.user != null) cfg.smtp.user;
    EMAIL_USE_TLS = lib.boolToString cfg.smtp.useTls;
    EMAIL_USE_SSL = lib.boolToString cfg.smtp.useSsl;
    EMAIL_SSL_CERT = lib.optionalString (cfg.smtp.sslCert != null) cfg.smtp.sslCert;
    EMAIL_SSL_KEY = lib.optionalString (cfg.smtp.sslKey != null) cfg.smtp.sslKey;
  };

  # Secret handling: each secret has a plain `xxx` and an `xxxFile` option. A *File
  # loads via systemd LoadCredential (never hits the store); a plain value goes via
  # Environment= (which does — the documented tradeoff). DSN passwords (PG/Redis/CH)
  # are assembled at runtime from these vars.
  allSecrets = {
    OR_PG_PASSWORD = {
      plain = cfg.postgres.password;
      file = cfg.postgres.passwordFile;
    };
    OR_REDIS_PASSWORD = {
      plain = cfg.redis.password;
      file = cfg.redis.passwordFile;
    };
    OR_CH_PASSWORD = {
      plain = cfg.clickhouse.password;
      file = cfg.clickhouse.passwordFile;
    };
    AWS_SECRET_ACCESS_KEY = {
      plain = cfg.s3.secretKey;
      file = cfg.s3.secretKeyFile;
    };
    TOKEN_SECRET = {
      plain = cfg.secrets.tokenSecret;
      file = cfg.secrets.tokenSecretFile;
    };
    JWT_SECRET = {
      plain = cfg.secrets.jwtSecret;
      file = cfg.secrets.jwtSecretFile;
    };
    JWT_REFRESH_SECRET = {
      plain = cfg.secrets.jwtRefreshSecret;
      file = cfg.secrets.jwtRefreshSecretFile;
    };
    JWT_SPOT_SECRET = {
      plain = cfg.secrets.jwtSpotSecret;
      file = cfg.secrets.jwtSpotSecretFile;
    };
    JWT_SPOT_REFRESH_SECRET = {
      plain = cfg.secrets.jwtSpotRefreshSecret;
      file = cfg.secrets.jwtSpotRefreshSecretFile;
    };
    ASSIST_JWT_SECRET = {
      plain = cfg.secrets.assistJwtSecret;
      file = cfg.secrets.assistJwtSecretFile;
    };
    EMAIL_PASSWORD = {
      plain = cfg.smtp.password;
      file = cfg.smtp.passwordFile;
    };
  };

  # LoadCredential id for an env var (JWT_SECRET -> jwt-secret).
  credName = env: lib.toLower (lib.replaceStrings [ "_" ] [ "-" ] env);

  # Resolve the secret env names a process needs into LoadCredential entries, the
  # shell preamble that exports the file-based ones, and plain Environment entries.
  resolveSecrets =
    needed:
    let
      specs = lib.filterAttrs (n: _: builtins.elem n needed) allSecrets;
      files = lib.filterAttrs (_: v: v.file != null) specs;
      plains = lib.filterAttrs (_: v: v.file == null && v.plain != null) specs;
    in
    {
      loadCredential = lib.mapAttrsToList (n: v: "${credName n}:${v.file}") files;
      preamble = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (n: _: ''export ${n}="$(cat "$CREDENTIALS_DIRECTORY/${credName n}")"'') files
      );
      environment = lib.mapAttrs (_: v: v.plain) plains;
    };

  # Runtime DSN assembly: read the OR_*_PASSWORD shell vars (from a credential file
  # or Environment) and build the connection strings, so a file-based password is
  # never serialised into the unit/store.
  dsnPreamble =
    {
      clickhouse ? false,
    }:
    ''
      if [ -n "''${OR_PG_PASSWORD:-}" ]; then
        export POSTGRES_STRING="postgres://${cfg.postgres.user}:$OR_PG_PASSWORD@${cfg.postgres.host}:${toString cfg.postgres.port}/${cfg.postgres.database}"
      else
        export POSTGRES_STRING="postgres://${cfg.postgres.user}@${cfg.postgres.host}:${toString cfg.postgres.port}/${cfg.postgres.database}"
      fi
      if [ -n "''${OR_REDIS_PASSWORD:-}" ]; then
        export REDIS_STRING="redis://:$OR_REDIS_PASSWORD@${cfg.redis.host}:${toString cfg.redis.port}"
      else
        export REDIS_STRING="redis://${cfg.redis.host}:${toString cfg.redis.port}"
      fi
    ''
    + lib.optionalString clickhouse ''
      if [ -n "''${OR_CH_PASSWORD:-}" ]; then
        export CLICKHOUSE_STRING="tcp://${cfg.clickhouse.username}:$OR_CH_PASSWORD@${cfg.clickhouse.host}:${toString cfg.clickhouse.tcpPort}/${cfg.clickhouse.database}"
      else
        export CLICKHOUSE_STRING="tcp://${cfg.clickhouse.host}:${toString cfg.clickhouse.tcpPort}/${cfg.clickhouse.database}"
      fi
      export CLICKHOUSE_HTTP_STRING="http://${cfg.clickhouse.host}:${toString cfg.clickhouse.httpPort}/${cfg.clickhouse.database}"
      export CLICKHOUSE_DATABASE="${cfg.clickhouse.database}"
    '';

  # Init one-shots every service waits on.
  initUnits =
    lib.optionals cfg.initSchema [
      "openreplay-pg-init.service"
      "openreplay-ch-init.service"
    ]
    ++ lib.optional cfg.initBuckets "openreplay-buckets.service";

  # Build a systemd service for one process from a wrapped command.
  mkService =
    {
      description,
      command,
      environment ? { },
      secretsNeeded ? [ ],
      extraServiceConfig ? { },
    }:
    let
      sec = resolveSecrets secretsNeeded;
    in
    {
      inherit description;
      after = [ "network-online.target" ] ++ initUnits;
      wants = [ "network-online.target" ];
      requires = initUnits;
      wantedBy = [ "multi-user.target" ];
      environment = {
        TZ = "UTC";
        TZDIR = tzDir;
      }
      // environment
      // sec.environment;
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "openreplay";
        WorkingDirectory = cfg.stateDir;
        Restart = "on-failure";
        RestartSec = 5;
        ExecStart = lib.getExe command;
      }
      // lib.optionalAttrs (sec.loadCredential != [ ]) { LoadCredential = sec.loadCredential; }
      // extraServiceConfig;
    };

  # A Go backend worker: assemble DSNs + secrets, ensure the FS scratch dir
  # exists, then exec the binary.
  goService =
    {
      name,
      port,
      metricsPort,
      environment ? { },
      secretsNeeded ? [ ],
      clickhouse ? false,
      objectStore ? false,
    }:
    mkService {
      description = "OpenReplay ${name} service";
      inherit secretsNeeded;
      environment = {
        SERVICE_NAME = name;
        HTTP_HOST = cfg.listenAddress;
        HTTP_PORT = toString port;
        METRICS_PORT = toString metricsPort;
        LOG_QUEUE_STATS_INTERVAL_SEC = "60";
        REDIS_STREAMS_MAX_LEN = "10000";
        HOSTNAME = "openreplay-${name}";
      }
      // topics
      // lib.optionalAttrs objectStore objectStorage
      // environment;
      command = pkgs.writeShellApplication {
        name = "openreplay-${name}";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          ${(resolveSecrets secretsNeeded).preamble}
          ${dsnPreamble { inherit clickhouse; }}
          [ -n "''${FS_DIR:-}" ] && mkdir -p "$FS_DIR" || true
          # Named binary inside the Go backend package (cmd/http -> "http").
          exec ${lib.getExe' cfg.package name}
        '';
      };
    };
in
{
  options.services.openreplay = {
    enable = lib.mkEnableOption "the OpenReplay session-replay services";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.openreplay-backend;
      description = "The Go backend package (also provides the pinned source via `.src`).";
    };
    dashboard = {
      package = lib.mkOption {
        type = lib.types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.openreplay-dashboard;
        description = "The built dashboard SPA (static site).";
      };
      root = lib.mkOption {
        type = lib.types.path;
        readOnly = true;
        default = cfg.dashboard.package;
        description = ''
          The static dashboard SPA root. Point your reverse proxy's document root
          at this; this module does not serve it.
        '';
      };
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "openreplay";
      description = "User the services run as.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "openreplay";
      description = "Group the services run as.";
    };
    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/openreplay";
      description = "State directory (FS scratch, shared blob dir, API working copy).";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the service HTTP endpoints bind to (front with your own proxy).";
    };
    healthHost = lib.mkOption {
      type = lib.types.str;
      default = cfg.listenAddress;
      description = ''
        Host the dashboard API's onboarding health-check probes each backend on
        (HEALTH_HOST). Defaults to the listen address; the services expose their
        /health on this host at their own `metricsPort`, so no Kubernetes DNS is
        needed on a single-host deploy.
      '';
    };
    siteUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost";
      description = "Public base URL the dashboard is served from (SITE_URL).";
    };
    assetsOrigin = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.siteUrl}/sessions-assets";
      description = ''
        Origin recorded assets are served from (ASSETS_ORIGIN). The sink/assets
        workers rewrite cachable resources (external CSS and @font-face files) in
        the recorded DOM to `<assetsOrigin>/<url-encoded-original>` and cache the
        bytes into the `sessions-assets` bucket. So this MUST include the
        `/sessions-assets` path (matching upstream's docker-compose/helm) — the
        reverse proxy routes that path to the object store. Pointing it at the
        bare site (no path) makes the rewritten stylesheet URLs resolve to the
        dashboard's SPA fallback (index.html), so the player fetches HTML in place
        of every stylesheet and replays render unstyled while live cobrowse — which
        streams the live CSSOM and never touches this origin — looks fine.
      '';
    };
    assistKey = lib.mkOption {
      type = lib.types.str;
      default = "openreplaydev";
      description = ''
        Shared path segment for the assist socket (/assist/<key>), used by the
        assist server and the dashboard/API. Not a secret.
      '';
    };

    # SMTP used by the dashboard API (invites, password resets) and the alerts
    # scheduler (alert/weekly-report emails). Leave `host` empty to disable email.
    smtp = {
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "smtp.example.com";
        description = "SMTP server host (EMAIL_HOST). Null (the default) disables all email.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 587;
        description = "SMTP server port (EMAIL_PORT).";
      };
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "SMTP login user (EMAIL_USER). Null skips authentication.";
      };
      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "SMTP login password (EMAIL_PASSWORD; plain, ends up in the Nix store).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Runtime path to a file holding the SMTP password (kept out of the store).";
      };
      from = lib.mkOption {
        type = lib.types.str;
        default = "OpenReplay <do-not-reply@openreplay.com>";
        description = "From header on outgoing mail (EMAIL_FROM).";
      };
      useTls = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use STARTTLS (EMAIL_USE_TLS). Ignored when useSsl is true.";
      };
      useSsl = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Use implicit TLS / SMTPS (EMAIL_USE_SSL). Takes precedence over useTls.";
      };
      sslCert = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional client-certificate path for SSL mode (EMAIL_SSL_CERT).";
      };
      sslKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional client-certificate key path for SSL mode (EMAIL_SSL_KEY).";
      };
    };

    initSchema = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the idempotent one-shot units that apply the Postgres and ClickHouse
        schema (OpenReplay does not apply its own schema).
      '';
    };
    initBuckets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the one-shot unit that creates the object-storage buckets.";
    };

    retention = {
      days = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 90;
        description = ''
          Data-retention window in days. OpenReplay OSS ships no time-based
          expiry — session metadata and events are kept indefinitely (only
          soft-deleted rows expire after a day), and replay blobs accumulate in
          the object store. Null (the default) preserves that behaviour.

          When set, the one-shot `openreplay-retention` unit applies a
          time-based ClickHouse `TTL` to the session (`experimental.sessions`)
          and event (`product_analytics.events`) tables so rows older than the
          window are dropped, and — when `initBuckets` is also on — the buckets
          one-shot adds an object-store lifecycle rule expiring the replay blobs
          in the session buckets (`mobs`, `sessions-assets`,
          `sessions-mobile-assets`) after the same window.

          The ClickHouse TTL applies unconditionally; the object-store expiry
          requires the S3 backend to honour bucket lifecycle rules (SeaweedFS
          and MinIO do). Both are idempotent and reconciled on every rebuild.
        '';
      };
    };

    http = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8100;
        description = "Ingest (http) service port.";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8120;
        description = "http service /metrics + /health port.";
      };
    };
    sink = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8101;
        description = "sink service health port.";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8121;
        description = "sink service /metrics + /health port.";
      };
    };
    db = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8102;
        description = "db service health port.";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8122;
        description = "db service /metrics + /health port.";
      };
    };
    ender = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8103;
        description = "ender service health port.";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8132;
        description = "ender service /metrics + /health port.";
      };
    };
    storage = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8104;
        description = "storage service health port.";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8124;
        description = "storage service /metrics + /health port.";
      };
    };
    assets = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8105;
        description = "assets service port.";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8125;
        description = "assets service /metrics + /health port.";
      };
    };
    heuristics = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8109;
        description = "heuristics service health port.";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8126;
        description = "heuristics service /metrics + /health port.";
      };
    };
    integrations = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8110;
        description = "integrations service HTTP port (proxy /integrations here).";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8127;
        description = "integrations service /metrics + /health port.";
      };
    };
    canvases = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8114;
        description = "canvases service port (web canvas uploads at /v1/web/images).";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8128;
        description = "canvases service /metrics + /health port.";
      };
    };
    images = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8115;
        description = "images service port (mobile screenshot uploads at /v1/mobile/images).";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8129;
        description = "images service /metrics + /health port.";
      };
    };
    spot = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8116;
        description = "spot service port (Spot recorder REST API; proxy /spot here).";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8130;
        description = "spot service /metrics + /health port.";
      };
    };

    # Go "v2" API (session search etc.); also shares the backend `package`.
    # Named `api` to match upstream (backend/cmd/api, SERVICE_NAME=api).
    api = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8106;
        description = "Go \"v2\" API port (session search, served at /v2/api).";
      };
      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 8131;
        description = "api service /metrics + /health port.";
      };
    };

    # Python dashboard REST API (chalice; FastAPI/uvicorn).
    chalice = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8000;
        description = "Python dashboard REST API port (served at /api).";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.openreplay-chalice;
        description = "The chalice dashboard REST API package (uvicorn app:app).";
      };
    };

    # Assist: live sessions / co-browsing (Node + socket.io).
    assist = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8107;
        description = "Assist (live sessions) socket.io port; proxy /assist + /ws-assist here.";
      };
      healthPort = lib.mkOption {
        type = lib.types.port;
        default = 8108;
        description = "Assist health/metrics port.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.openreplay-assist;
        description = "The assist server package (live sessions / co-browsing).";
      };
    };

    # sourcemapreader: JS stack-trace symbolication (Node/Express).
    sourcemapreader = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8111;
        description = "sourcemapreader service port (queried by the dashboard API).";
      };
      healthPort = lib.mkOption {
        type = lib.types.port;
        default = 8112;
        description = "sourcemapreader health port.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.openreplay-sourcemapreader;
        description = "The sourcemapreader server package (JS stack-trace symbolication).";
      };
    };

    # alerts: notification scheduler (chalice codebase, uvicorn).
    alerts = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 8113;
        description = "alerts scheduler health/listen port.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.openreplay-alerts;
        description = "The alerts scheduler package (uvicorn app_alerts:app).";
      };
    };

    postgres = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Postgres host.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "Postgres port.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "postgres";
        description = "Postgres user.";
      };
      database = lib.mkOption {
        type = lib.types.str;
        default = "openreplay";
        description = "Postgres database name.";
      };
      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Postgres password (plain; ends up in the Nix store).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Runtime path to a file holding the Postgres password (kept out of the store).";
      };
      createDatabase = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Have the pg-init unit create the database if it does not exist (needs privileges).";
      };
    };

    clickhouse = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "ClickHouse host.";
      };
      tcpPort = lib.mkOption {
        type = lib.types.port;
        default = 9000;
        description = "ClickHouse native TCP port.";
      };
      httpPort = lib.mkOption {
        type = lib.types.port;
        default = 8123;
        description = "ClickHouse HTTP port (used by the Python API).";
      };
      database = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "ClickHouse database.";
      };
      username = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "ClickHouse user.";
      };
      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ClickHouse password (plain; ends up in the Nix store).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Runtime path to a file holding the ClickHouse password.";
      };
    };

    redis = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Redis host.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 6379;
        description = "Redis port.";
      };
      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Redis password (plain; ends up in the Nix store).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Runtime path to a file holding the Redis password.";
      };
    };

    s3 = {
      endpoint = lib.mkOption {
        type = lib.types.str;
        example = "https://s3.us-east-1.amazonaws.com";
        description = ''
          Internal S3-compatible endpoint URL. Used by the ingest/storage
          workers and for server-side object operations — it only needs to be
          reachable from this host, so it is typically a loopback address.
        '';
      };
      publicEndpoint = lib.mkOption {
        type = lib.types.str;
        default = cfg.siteUrl;
        description = ''
          Browser-facing S3 endpoint used to *presign* session-replay asset URLs
          — the DOM "mob" files the player downloads, canvas frames, and
          sourcemaps. These presigned URLs are fetched directly by the user's
          browser, so this must be an origin the browser can reach, and your
          reverse proxy must route the bucket paths (/mobs, /sessions-assets, …)
          to the object store while forwarding the original Host header
          unchanged (SigV4 signs the host, so a rewritten Host fails validation).

          Defaults to the bare siteUrl — NOT assetsOrigin. boto3 appends the
          bucket to this endpoint (`<publicEndpoint>/mobs/<key>`), so it must be
          the site root; assetsOrigin carries a `/sessions-assets` path that would
          mis-route the presigned bucket paths. Leaving this equal to `endpoint`
          — e.g. a loopback address — only works when the browser runs on this
          same host (a local dev stack); on a real deployment the presigned URLs
          would point at an address the browser cannot reach and replays render
          blank.
        '';
      };
      region = lib.mkOption {
        type = lib.types.str;
        default = "us-east-1";
        description = "S3 region.";
      };
      accessKey = lib.mkOption {
        type = lib.types.str;
        description = "S3 access key id (not secret).";
      };
      secretKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "S3 secret access key (plain; ends up in the Nix store).";
      };
      secretKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Runtime path to a file holding the S3 secret access key.";
      };
      disableSslVerify = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Skip S3 TLS verification (self-signed dev endpoints).";
      };
      buckets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "mobs"
          "sessions-assets"
          "static"
          "sourcemaps"
          "sessions-mobile-assets"
          "uxtesting-records"
          "records"
          "spots"
        ];
        description = "Buckets the init unit creates.";
      };
    };

    secrets =
      let
        secretOpt = desc: {
          plain = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "${desc} (plain; ends up in the Nix store).";
          };
          file = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Runtime path to a file holding the ${desc} (kept out of the store).";
          };
        };
      in
      {
        tokenSecret = (secretOpt "tracker token secret").plain;
        tokenSecretFile = (secretOpt "tracker token secret").file;
        jwtSecret = (secretOpt "dashboard JWT secret").plain;
        jwtSecretFile = (secretOpt "dashboard JWT secret").file;
        jwtRefreshSecret = (secretOpt "dashboard JWT refresh secret").plain;
        jwtRefreshSecretFile = (secretOpt "dashboard JWT refresh secret").file;
        jwtSpotSecret = (secretOpt "Spot JWT secret").plain;
        jwtSpotSecretFile = (secretOpt "Spot JWT secret").file;
        jwtSpotRefreshSecret = (secretOpt "Spot JWT refresh secret").plain;
        jwtSpotRefreshSecretFile = (secretOpt "Spot JWT refresh secret").file;
        assistJwtSecret = (secretOpt "assist JWT secret").plain;
        assistJwtSecretFile = (secretOpt "assist JWT secret").file;
      };

    dataFiles = {
      uaparser = lib.mkOption {
        type = lib.types.path;
        default = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/ua-parser/uap-core/v0.18.0/regexes.yaml";
          hash = "sha256-J0w3dO0Ma6yiJhl9L5eL/AYhcgFxiVR1o3dfC5+VSbo=";
        };
        description = "UAParser regexes file (UAPARSER_FILE); required by the http service.";
      };
      maxmind = lib.mkOption {
        type = lib.types.path;
        default = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/maxmind/MaxMind-DB/main/test-data/GeoLite2-City-Test.mmdb";
          hash = "sha256-+TZwK1HctslLKG13pvGCwxoWAbr0sn6OiWk03rQfSfI=";
        };
        description = ''
          MaxMind City DB (MAXMINDDB_FILE); required by the http service. The
          default is upstream *test* data — geo enrichment is sample-accurate
          only. Point this at a real GeoLite2-City.mmdb for production.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.s3.endpoint != "";
        message = "services.openreplay.s3.endpoint must be set.";
      }
      {
        assertion = cfg.s3.accessKey != "";
        message = "services.openreplay.s3.accessKey must be set.";
      }
      {
        assertion = !(cfg.postgres.password != null && cfg.postgres.passwordFile != null);
        message = "Set only one of services.openreplay.postgres.password / passwordFile.";
      }
      {
        assertion = !(cfg.s3.secretKey != null && cfg.s3.secretKeyFile != null);
        message = "Set only one of services.openreplay.s3.secretKey / secretKeyFile.";
      }
      {
        assertion = !(cfg.smtp.password != null && cfg.smtp.passwordFile != null);
        message = "Set only one of services.openreplay.smtp.password / passwordFile.";
      }
    ];

    users.users = lib.mkIf (cfg.user == "openreplay") {
      openreplay = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.stateDir;
      };
    };
    users.groups = lib.mkIf (cfg.group == "openreplay") { openreplay = { }; };

    systemd.services = lib.mkMerge [
      # one-shot: Postgres extensions + schema
      (lib.mkIf cfg.initSchema {
        openreplay-pg-init = {
          description = "OpenReplay Postgres schema init";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig =
            let
              sec = resolveSecrets [ "OR_PG_PASSWORD" ];
            in
            {
              Type = "oneshot";
              RemainAfterExit = true;
              User = cfg.user;
              Group = cfg.group;
            }
            // lib.optionalAttrs (sec.loadCredential != [ ]) { LoadCredential = sec.loadCredential; }
            // lib.optionalAttrs (sec.environment != { }) {
              Environment = lib.mapAttrsToList (n: v: "${n}=${v}") sec.environment;
            };
          script =
            let
              sec = resolveSecrets [ "OR_PG_PASSWORD" ];
            in
            ''
              ${sec.preamble}
              export PGPASSWORD="''${OR_PG_PASSWORD:-}"
              export PGHOST=${cfg.postgres.host} PGPORT=${toString cfg.postgres.port} PGUSER=${cfg.postgres.user}
              ${lib.optionalString cfg.postgres.createDatabase ''
                if ! psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${cfg.postgres.database}'" | grep -q 1; then
                  psql -d postgres -c "CREATE DATABASE ${cfg.postgres.database}"
                fi
              ''}
              export PGDATABASE=${cfg.postgres.database}
              psql -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS pgcrypto;'
              if [ -z "$(psql -tAc "SELECT to_regclass('public.tenants')")" ]; then
                psql -v ON_ERROR_STOP=1 -f ${cfg.package.src}/scripts/schema/db/init_dbs/postgresql/init_schema.sql
              else
                echo "openreplay: postgres schema already present, skipping"
              fi
            '';
          path = [ pkgs.postgresql ];
        };
      })

      # one-shot: ClickHouse databases + schema
      (lib.mkIf cfg.initSchema {
        openreplay-ch-init = {
          description = "OpenReplay ClickHouse schema init";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig =
            let
              sec = resolveSecrets [ "OR_CH_PASSWORD" ];
            in
            {
              Type = "oneshot";
              RemainAfterExit = true;
              User = cfg.user;
              Group = cfg.group;
              Environment = [ "TZDIR=${tzDir}" ] ++ lib.mapAttrsToList (n: v: "${n}=${v}") sec.environment;
            }
            // lib.optionalAttrs (sec.loadCredential != [ ]) { LoadCredential = sec.loadCredential; };
          script =
            let
              sec = resolveSecrets [ "OR_CH_PASSWORD" ];
            in
            ''
              ${sec.preamble}
              args=(--host ${cfg.clickhouse.host} --port ${toString cfg.clickhouse.tcpPort} --user ${cfg.clickhouse.username})
              if [ -n "''${OR_CH_PASSWORD:-}" ]; then
                args+=(--password "$OR_CH_PASSWORD")
              fi
              # The upstream create script isn't safe to re-run; apply it only once,
              # keyed on the `experimental` database it creates.
              if [ "$(clickhouse-client "''${args[@]}" --query "EXISTS DATABASE experimental")" = "1" ]; then
                echo "openreplay: clickhouse schema already present, skipping"
              else
                clickhouse-client "''${args[@]}" --multiquery < ${cfg.package.src}/scripts/schema/db/init_dbs/clickhouse/create/init_schema.sql
              fi
            '';
          path = [ pkgs.clickhouse ];
        };
      })

      # one-shot: ClickHouse data-retention TTLs. OSS keeps session/event data
      # indefinitely; a configured window applies a time-based TTL so ClickHouse
      # drops older rows. MODIFY TTL replaces the table's TTL — idempotent, reconciled
      # each rebuild. Object-store blob expiry is in the buckets one-shot.
      (lib.mkIf (cfg.retention.days != null && cfg.initSchema) {
        openreplay-retention = {
          description = "OpenReplay ClickHouse data-retention TTLs";
          after = [
            "network-online.target"
            "openreplay-ch-init.service"
          ];
          wants = [ "network-online.target" ];
          requires = [ "openreplay-ch-init.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig =
            let
              sec = resolveSecrets [ "OR_CH_PASSWORD" ];
            in
            {
              Type = "oneshot";
              RemainAfterExit = true;
              User = cfg.user;
              Group = cfg.group;
              Environment = [ "TZDIR=${tzDir}" ] ++ lib.mapAttrsToList (n: v: "${n}=${v}") sec.environment;
            }
            // lib.optionalAttrs (sec.loadCredential != [ ]) { LoadCredential = sec.loadCredential; };
          script =
            let
              sec = resolveSecrets [ "OR_CH_PASSWORD" ];
              d = toString cfg.retention.days;
            in
            ''
              ${sec.preamble}
              args=(--host ${cfg.clickhouse.host} --port ${toString cfg.clickhouse.tcpPort} --user ${cfg.clickhouse.username})
              if [ -n "''${OR_CH_PASSWORD:-}" ]; then
                args+=(--password "$OR_CH_PASSWORD")
              fi
              # Sessions expire on their `datetime`; events expire on `created_at`
              # (a DateTime64, cast to DateTime) while preserving the upstream
              # soft-delete purge as a second TTL clause.
              clickhouse-client "''${args[@]}" --query \
                "ALTER TABLE experimental.sessions MODIFY TTL datetime + INTERVAL ${d} DAY"
              clickhouse-client "''${args[@]}" --query \
                "ALTER TABLE product_analytics.events MODIFY TTL toDateTime(created_at) + INTERVAL ${d} DAY, _deleted_at + INTERVAL 1 DAY DELETE WHERE _deleted_at != '1970-01-01 00:00:00'"
              echo "openreplay: clickhouse retention TTL set to ${d} days"
            '';
          path = [ pkgs.clickhouse ];
        };
      })

      # one-shot: object-storage buckets
      (lib.mkIf cfg.initBuckets {
        openreplay-buckets = {
          description = "OpenReplay object-storage bucket init";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig =
            let
              sec = resolveSecrets [ "AWS_SECRET_ACCESS_KEY" ];
            in
            {
              Type = "oneshot";
              RemainAfterExit = true;
              User = cfg.user;
              Group = cfg.group;
              # mc writes its config under $HOME (the openreplay user's home is
              # the state dir, which this one-shot does not own). Give it a
              # private, writable, ephemeral config dir instead.
              RuntimeDirectory = "openreplay-buckets";
            }
            // lib.optionalAttrs (sec.loadCredential != [ ]) { LoadCredential = sec.loadCredential; }
            // lib.optionalAttrs (sec.environment != { }) {
              Environment = lib.mapAttrsToList (n: v: "${n}=${v}") sec.environment;
            };
          script =
            let
              sec = resolveSecrets [ "AWS_SECRET_ACCESS_KEY" ];
              assetsPolicy = pkgs.writeText "sessions-assets-anon-download.json" (
                builtins.toJSON {
                  Version = "2012-10-17";
                  Statement = [
                    {
                      Effect = "Allow";
                      Principal = "*";
                      Action = [ "s3:GetObject" ];
                      Resource = [ "arn:aws:s3:::sessions-assets/*" ];
                    }
                  ];
                }
              );
              # Replay-blob buckets that a retention window should expire (only
              # those actually being created). `mc ilm import` replaces the whole
              # lifecycle config, so re-running reconciles rather than duplicates.
              retentionBuckets = builtins.filter (b: builtins.elem b cfg.s3.buckets) [
                "mobs"
                "sessions-assets"
                "sessions-mobile-assets"
              ];
              retentionLifecycle = pkgs.writeText "openreplay-retention-lifecycle.json" (
                builtins.toJSON {
                  Rules = [
                    {
                      ID = "openreplay-retention";
                      Status = "Enabled";
                      Filter = { };
                      Expiration.Days = cfg.retention.days;
                    }
                  ];
                }
              );
            in
            ''
              ${sec.preamble}
              export MC_CONFIG_DIR="$RUNTIME_DIRECTORY"
              mc alias set local ${cfg.s3.endpoint} ${cfg.s3.accessKey} "$AWS_SECRET_ACCESS_KEY"
              for b in ${lib.concatStringsSep " " cfg.s3.buckets}; do
                mc mb -p "local/$b"
              done
              mc anonymous set-json ${assetsPolicy} local/sessions-assets
              ${lib.optionalString (cfg.retention.days != null) ''
                # Expire replay blobs after the retention window. Best-effort: warn
                # (don't fail bucket init) if the object store can't store lifecycle
                # rules — the ClickHouse TTL still bounds discoverable session data.
                for b in ${lib.concatStringsSep " " retentionBuckets}; do
                  mc ilm import "local/$b" < ${retentionLifecycle} \
                    || echo "openreplay: warning: lifecycle expiry not applied to $b (S3 backend may not support lifecycle rules)" >&2
                done
              ''}
            '';
          path = [ pkgs.minio-client ];
        };
      })

      # ingestion pipeline (Redis Streams)
      {
        openreplay-http = goService {
          name = "http";
          port = cfg.http.port;
          metricsPort = cfg.http.metricsPort;
          objectStore = true;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
            "TOKEN_SECRET"
            "JWT_SECRET"
            "JWT_SPOT_SECRET"
          ];
          environment = {
            BUCKET_NAME = "uxtesting-records";
            BEACON_SIZE_LIMIT = "1000000";
            UAPARSER_FILE = "${cfg.dataFiles.uaparser}";
            MAXMINDDB_FILE = "${cfg.dataFiles.maxmind}";
            USE_CORS = "true";
          };
        };

        openreplay-sink = goService {
          name = "sink";
          port = cfg.sink.port;
          metricsPort = cfg.sink.metricsPort;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
          ];
          environment = {
            FS_DIR = "${cfg.stateDir}/blobs";
            FS_ULIMIT = "1000";
            GROUP_SINK = "sink";
            CACHE_ASSETS = "true";
            ASSETS_ORIGIN = cfg.assetsOrigin;
          };
        };

        openreplay-db = goService {
          name = "db";
          port = cfg.db.port;
          metricsPort = cfg.db.metricsPort;
          clickhouse = true;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "OR_CH_PASSWORD"
          ];
          environment = {
            GROUP_DB = "db";
            GROUP_ANALYTICS = "analytics";
            DB_BATCH_QUEUE_LIMIT = "10000";
            DB_BATCH_SIZE_LIMIT = "20000";
          };
        };

        openreplay-ender = goService {
          name = "ender";
          port = cfg.ender.port;
          metricsPort = cfg.ender.metricsPort;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
          ];
          environment = {
            GROUP_ENDER = "ender";
            GROUP_CLEANUP = "cleaner";
            PARTITIONS_NUMBER = "16";
          };
        };

        openreplay-storage = goService {
          name = "storage";
          port = cfg.storage.port;
          metricsPort = cfg.storage.metricsPort;
          objectStore = true;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
          ];
          environment = {
            FS_DIR = "${cfg.stateDir}/blobs";
            GROUP_STORAGE = "storage";
            BUCKET_NAME = "mobs";
          };
        };

        openreplay-assets = goService {
          name = "assets";
          port = cfg.assets.port;
          metricsPort = cfg.assets.metricsPort;
          objectStore = true;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
          ];
          environment = {
            GROUP_CACHE = "cache";
            CACHE_ASSETS = "true";
            ASSETS_ORIGIN = cfg.assetsOrigin;
            ASSETS_SIZE_LIMIT = "10000000";
            BUCKET_NAME = "sessions-assets";
          };
        };

        # Derives events/issues (clicks, inputs, dead clicks, …) from the raw
        # message stream. A pure Redis-Streams consumer (no TCP listener beyond
        # its health handler), like sink/db/ender/storage.
        openreplay-heuristics = goService {
          name = "heuristics";
          port = cfg.heuristics.port;
          metricsPort = cfg.heuristics.metricsPort;
          secretsNeeded = [ "OR_REDIS_PASSWORD" ];
          environment = {
            GROUP_HEURISTICS = "heuristics";
          };
        };

        # Archives per-session <canvas> snapshots for replay. The web tracker POSTs
        # canvas frames to /v1/web/images (route /ingest/v1/web/images here), which
        # the service produces to the canvas-image stream and then consumes, along
        # with the canvas-trigger stream (session-end from ender), buffering under
        # FS_DIR/CANVAS_DIR before packing+uploading to the mobs bucket. Both topics
        # are already in `topics` and ender emits the trigger. FS_DIR is the shared
        # blobs dir (the service manages its own canvas/ subtree).
        openreplay-canvases = goService {
          name = "canvases";
          port = cfg.canvases.port;
          metricsPort = cfg.canvases.metricsPort;
          objectStore = true;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
            "TOKEN_SECRET"
          ];
          environment = {
            FS_DIR = "${cfg.stateDir}/blobs";
            CANVAS_DIR = "canvas";
            GROUP_CANVAS_IMAGE = "canvas-image";
            BUCKET_NAME = "mobs";
          };
        };

        # Mobile (iOS/Android) replay screenshots. The SDK POSTs batches to
        # /v1/mobile/images (route /ingest/v1/mobile/images here, stripping /ingest);
        # the service also consumes the raw-images stream and uploads packed
        # screenshots to the mobs bucket. FS_DIR is the shared blobs dir
        # (screenshots/ subtree via SCREENSHOTS_DIR).
        openreplay-images = goService {
          name = "images";
          port = cfg.images.port;
          metricsPort = cfg.images.metricsPort;
          objectStore = true;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
            "TOKEN_SECRET"
          ];
          environment = {
            FS_DIR = "${cfg.stateDir}/blobs";
            SCREENSHOTS_DIR = "screenshots";
            GROUP_IMAGE_STORAGE = "image-storage";
            BUCKET_NAME = "mobs";
          };
        };

        # OpenReplay Spot: the browser-extension screen recorder (bug-report videos),
        # distinct from session replay. Serves an authenticated REST API (/v1/spots,
        # /spots/…) — proxy /spot/ here, stripping the prefix (serves at NoPrefix).
        # Auth uses the dashboard JWT + the Spot JWT; those, the spots.* schema, and
        # the spots bucket already exist. FS_DIR is the shared blobs dir (SPOTS_DIR).
        openreplay-spot = goService {
          name = "spot";
          port = cfg.spot.port;
          metricsPort = cfg.spot.metricsPort;
          objectStore = true;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
            "JWT_SECRET"
            "JWT_SPOT_SECRET"
          ];
          environment = {
            FS_DIR = "${cfg.stateDir}/blobs";
            SPOTS_DIR = "spots";
            BUCKET_NAME = "spots";
          };
        };

        # HTTP service for third-party log integrations (Sentry, Datadog, …);
        # proxied at /integrations. Binds a TCP port; touches PG, Redis, object store.
        openreplay-integrations = goService {
          name = "integrations";
          port = cfg.integrations.port;
          metricsPort = cfg.integrations.metricsPort;
          objectStore = true;
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
            "TOKEN_SECRET"
            "JWT_SECRET"
          ];
          environment = {
            BUCKET_NAME = "mobs";
          };
        };

        # Go "v2" API (dashboard session search etc.)
        openreplay-api = mkService {
          description = "OpenReplay Go v2 API";
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "OR_CH_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
            "JWT_SECRET"
            "JWT_SPOT_SECRET"
            "ASSIST_JWT_SECRET"
          ];
          environment =
            objectStorage
            // topics
            // {
              SERVICE_NAME = "api";
              HOSTNAME = "openreplay-api";
              REDIS_STREAMS_MAX_LEN = "10000";
              HTTP_HOST = cfg.listenAddress;
              HTTP_PORT = toString cfg.api.port;
              METRICS_PORT = toString cfg.api.metricsPort;
              JWT_ISSUER = "OpenReplay-oss";
              BUCKET_NAME = "mobs";
              # Presigns the replay DOM ("mob") URLs the player fetches from the
              # browser, so it must sign against the browser-reachable origin, not
              # the loopback `endpoint` other workers use. Overrides objectStorage's.
              AWS_ENDPOINT = cfg.s3.publicEndpoint;
              FS_DIR = "${cfg.stateDir}/api";
              # Live sessions: query the assist server at sprintf(ASSIST_URL, ASSIST_KEY).
              ASSIST_URL = assistUrlEnv;
              ASSIST_KEY = cfg.assistKey;
            };
          command = pkgs.writeShellApplication {
            name = "openreplay-api";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              ${(resolveSecrets [
                "OR_PG_PASSWORD"
                "OR_REDIS_PASSWORD"
                "OR_CH_PASSWORD"
                "AWS_SECRET_ACCESS_KEY"
                "JWT_SECRET"
                "JWT_SPOT_SECRET"
                "ASSIST_JWT_SECRET"
              ]).preamble
              }
              ${dsnPreamble { clickhouse = true; }}
              mkdir -p "$FS_DIR"
              exec ${lib.getExe' cfg.package "api"}
            '';
          };
        };

        # Python dashboard REST API (chalice; FastAPI/uvicorn)
        openreplay-chalice = mkService {
          description = "OpenReplay Python dashboard API (chalice)";
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "OR_CH_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
            "JWT_SECRET"
            "JWT_REFRESH_SECRET"
            "JWT_SPOT_SECRET"
            "JWT_SPOT_REFRESH_SECRET"
            "ASSIST_JWT_SECRET"
            "EMAIL_PASSWORD"
          ];
          environment = {
            pg_host = cfg.postgres.host;
            pg_port = toString cfg.postgres.port;
            pg_dbname = cfg.postgres.database;
            pg_user = cfg.postgres.user;
            ch_host = cfg.clickhouse.host;
            ch_port = toString cfg.clickhouse.tcpPort;
            ch_port_http = toString cfg.clickhouse.httpPort;
            ch_user = cfg.clickhouse.username;
            # Kept internal: chalice presigns via boto3, whose default addressing is
            # virtual-hosted (https://<bucket>.host/…), which the gateway's path-based
            # bucket routing doesn't serve. It only presigns supplementary assets
            # (canvas frames, sourcemaps), not the replay DOM, so internal is fine;
            # the browser-facing DOM presigning is on the Go API (path style).
            S3_HOST = cfg.s3.endpoint;
            S3_KEY = cfg.s3.accessKey;
            S3_DISABLE_SSL_VERIFY = lib.boolToString cfg.s3.disableSslVerify;
            sessions_bucket = "mobs";
            js_cache_bucket = "sessions-assets";
            sourcemaps_bucket = "sourcemaps";
            sessions_region = cfg.s3.region;
            SITE_URL = cfg.siteUrl;
            LISTEN_PORT = toString cfg.chalice.port;
            HEALTH_HOST = cfg.healthHost;
            ASSIST_URL = assistUrlEnv;
            ASSIST_KEY = cfg.assistKey;
            # Symbolication: chalice formats this with SMR_KEY (default "smr") ->
            # http://host:port/smr/sourcemaps, matching the sourcemapreader route.
            # The literal {} is Python str.format (not shell/systemd), passed through.
            sourcemaps_reader = "http://${cfg.listenAddress}:${toString cfg.sourcemapreader.port}/{}/sourcemaps";
          }
          // smtpEnv;
          command = pkgs.writeShellApplication {
            name = "openreplay-pyapi";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              ${(resolveSecrets [
                "OR_PG_PASSWORD"
                "OR_REDIS_PASSWORD"
                "OR_CH_PASSWORD"
                "AWS_SECRET_ACCESS_KEY"
                "JWT_SECRET"
                "JWT_REFRESH_SECRET"
                "JWT_SPOT_SECRET"
                "JWT_SPOT_REFRESH_SECRET"
                "ASSIST_JWT_SECRET"
                "EMAIL_PASSWORD"
              ]).preamble
              }
              # The Python API reads these under its own names (python-decouple).
              export pg_password="''${OR_PG_PASSWORD:-}"
              export ch_password="''${OR_CH_PASSWORD:-}"
              export S3_SECRET="''${AWS_SECRET_ACCESS_KEY:-}"
              ${dsnPreamble { }}
              exec ${lib.getExe cfg.chalice.package} --host ${cfg.listenAddress} --port ${toString cfg.chalice.port} --proxy-headers --log-level warning
            '';
          };
        };

        # assist: live sessions / co-browsing (Node + socket.io). Proxy /ws-assist/
        # (socket.io WebSocket upgrade, strip prefix -> /socket) and
        # /assist/ (REST). WebRTC media is peer-to-peer between agent and visitor.
        openreplay-assist = mkService {
          description = "OpenReplay assist server (live sessions / co-browsing)";
          secretsNeeded = [ "ASSIST_JWT_SECRET" ];
          environment = {
            SERVICE_NAME = "assist";
            LISTEN_HOST = cfg.listenAddress;
            LISTEN_PORT = toString cfg.assist.port;
            HEALTH_PORT = toString cfg.assist.healthPort;
            ASSIST_KEY = cfg.assistKey;
            PREFIX = "/assist";
            # Single instance — no redis coordination (matches upstream assist.env).
            redis = "false";
            MAXMINDDB_FILE = "${cfg.dataFiles.maxmind}";
          };
          command = pkgs.writeShellApplication {
            name = "openreplay-assist-run";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              ${(resolveSecrets [ "ASSIST_JWT_SECRET" ]).preamble}
              exec ${lib.getExe cfg.assist.package}
            '';
          };
        };

        # sourcemapreader: JS stack-trace symbolication (Node/Express). Called by the
        # chalice API to map minified frames back to source via the
        # sourcemaps bucket. Internal only — not fronted by the proxy.
        openreplay-sourcemapreader = mkService {
          description = "OpenReplay sourcemapreader (stack-trace symbolication)";
          secretsNeeded = [ "AWS_SECRET_ACCESS_KEY" ];
          environment = {
            SERVICE_NAME = "sourcemaps-reader";
            SMR_HOST = cfg.listenAddress;
            SMR_PORT = toString cfg.sourcemapreader.port;
            # health.js binds its own listener on LISTEN_HOST:HEALTH_PORT.
            LISTEN_HOST = cfg.listenAddress;
            HEALTH_PORT = toString cfg.sourcemapreader.healthPort;
            S3_HOST = cfg.s3.endpoint;
            S3_KEY = cfg.s3.accessKey;
            AWS_REGION = cfg.s3.region;
          };
          command = pkgs.writeShellApplication {
            name = "openreplay-sourcemapreader-run";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              ${(resolveSecrets [ "AWS_SECRET_ACCESS_KEY" ]).preamble}
              # The Node service reads the S3 secret from S3_SECRET.
              export S3_SECRET="''${AWS_SECRET_ACCESS_KEY:-}"
              exec ${lib.getExe cfg.sourcemapreader.package}
            '';
          };
        };

        # alerts: notification scheduler (chalice codebase, uvicorn). Runs
        # app_alerts:app — an APScheduler loop, no authenticated HTTP surface;
        # shares the chalice Python env and DB config. CH_POOL=false /
        # ASSIST_KEY=ignore match upstream's alerts entrypoint.
        openreplay-alerts = mkService {
          description = "OpenReplay alerts scheduler";
          secretsNeeded = [
            "OR_PG_PASSWORD"
            "OR_REDIS_PASSWORD"
            "OR_CH_PASSWORD"
            "AWS_SECRET_ACCESS_KEY"
            "JWT_SECRET"
            "JWT_REFRESH_SECRET"
            "JWT_SPOT_SECRET"
            "JWT_SPOT_REFRESH_SECRET"
            "ASSIST_JWT_SECRET"
            "EMAIL_PASSWORD"
          ];
          environment = {
            pg_host = cfg.postgres.host;
            pg_port = toString cfg.postgres.port;
            pg_dbname = cfg.postgres.database;
            pg_user = cfg.postgres.user;
            ch_host = cfg.clickhouse.host;
            ch_port = toString cfg.clickhouse.tcpPort;
            ch_port_http = toString cfg.clickhouse.httpPort;
            ch_user = cfg.clickhouse.username;
            CH_POOL = "false";
            S3_HOST = cfg.s3.endpoint;
            S3_KEY = cfg.s3.accessKey;
            S3_DISABLE_SSL_VERIFY = lib.boolToString cfg.s3.disableSslVerify;
            sessions_bucket = "mobs";
            js_cache_bucket = "sessions-assets";
            sourcemaps_bucket = "sourcemaps";
            sessions_region = cfg.s3.region;
            SITE_URL = cfg.siteUrl;
            LISTEN_PORT = toString cfg.alerts.port;
            ASSIST_KEY = "ignore";
          }
          // smtpEnv;
          command = pkgs.writeShellApplication {
            name = "openreplay-alerts-run";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              ${(resolveSecrets [
                "OR_PG_PASSWORD"
                "OR_REDIS_PASSWORD"
                "OR_CH_PASSWORD"
                "AWS_SECRET_ACCESS_KEY"
                "JWT_SECRET"
                "JWT_REFRESH_SECRET"
                "JWT_SPOT_SECRET"
                "JWT_SPOT_REFRESH_SECRET"
                "ASSIST_JWT_SECRET"
                "EMAIL_PASSWORD"
              ]).preamble
              }
              export pg_password="''${OR_PG_PASSWORD:-}"
              export ch_password="''${OR_CH_PASSWORD:-}"
              export S3_SECRET="''${AWS_SECRET_ACCESS_KEY:-}"
              ${dsnPreamble { }}
              exec ${lib.getExe cfg.alerts.package} --host ${cfg.listenAddress} --port ${toString cfg.alerts.port} --log-level warning
            '';
          };
        };
      }
    ];
  };
}
