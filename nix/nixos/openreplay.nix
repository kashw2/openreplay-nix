{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.openreplay;

  # ClickHouse clients need TZDIR: NixOS has no /usr/share/zoneinfo.
  tzDir = "${pkgs.tzdata}/share/zoneinfo";

  # Redis-Streams topics (no Kafka in OSS); upstream defaults, required by the structs.
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

  # APIs build the URL as sprintf(ASSIST_URL, ASSIST_KEY), so the %s is required.
  assistUrl = "http://${cfg.listenAddress}:${toString cfg.assist.port}/assist/%s";
  # systemd eats %-specifiers in Environment=, so double it to pass a literal %s.
  assistUrlEnv = lib.replaceStrings [ "%" ] [ "%%" ] assistUrl;

  # Shared by the chalice API and the alerts scheduler (python-decouple). A null host emits no EMAIL_*, which disables sending upstream.
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

  # Every secret is a path to a file holding it (sops-nix, agenix, systemd-creds): loaded via LoadCredential, exported from $CREDENTIALS_DIRECTORY, never in the store.
  allSecrets = {
    OR_PG_PASSWORD = cfg.postgres.passwordFile;
    OR_REDIS_PASSWORD = cfg.redis.passwordFile;
    OR_CH_PASSWORD = cfg.clickhouse.passwordFile;
    AWS_SECRET_ACCESS_KEY = cfg.s3.secretKeyFile;
    TOKEN_SECRET = cfg.secrets.tokenSecretFile;
    JWT_SECRET = cfg.secrets.jwtSecretFile;
    JWT_REFRESH_SECRET = cfg.secrets.jwtRefreshSecretFile;
    JWT_SPOT_SECRET = cfg.secrets.jwtSpotSecretFile;
    JWT_SPOT_REFRESH_SECRET = cfg.secrets.jwtSpotRefreshSecretFile;
    ASSIST_JWT_SECRET = cfg.secrets.assistJwtSecretFile;
    EMAIL_PASSWORD = cfg.smtp.passwordFile;
  };

  # LoadCredential id for an env var (JWT_SECRET -> jwt-secret).
  credName = env: lib.toLower (lib.replaceStrings [ "_" ] [ "-" ] env);

  # LoadCredential entries + the preamble exporting them. Unset (null) secrets are absent.
  resolveSecrets =
    needed:
    let
      files = lib.filterAttrs (n: v: builtins.elem n needed && v != null) allSecrets;
    in
    {
      loadCredential = lib.mapAttrsToList (n: v: "${credName n}:${v}") files;
      # Assign then export: `export x="$(...)"` masks the exit status (SC2155).
      preamble = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (n: _: ''
          ${n}="$(cat "$CREDENTIALS_DIRECTORY/${credName n}")"
          export ${n}
        '') files
      );
    };

  # Build DSNs at runtime from the exported OR_*_PASSWORD vars, never in the unit.
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

  # Ports for the Go services; feeds both the options and the units so they can't drift. `desc` completes "… port." in the option description.
  goServicePorts = {
    http = {
      port = 8100;
      metricsPort = 8120;
      desc = "Ingest (http) service";
    };
    sink = {
      port = 8101;
      metricsPort = 8121;
      desc = "sink service health";
    };
    db = {
      port = 8102;
      metricsPort = 8122;
      desc = "db service health";
    };
    ender = {
      port = 8103;
      metricsPort = 8132;
      desc = "ender service health";
    };
    storage = {
      port = 8104;
      metricsPort = 8124;
      desc = "storage service health";
    };
    assets = {
      port = 8105;
      metricsPort = 8125;
      desc = "assets service";
    };
    # Upstream name (backend/cmd/api, SERVICE_NAME=api); shares the backend package.
    api = {
      port = 8106;
      metricsPort = 8131;
      desc = ''Go "v2" API (session search, served at /v2/api)'';
    };
    heuristics = {
      port = 8109;
      metricsPort = 8126;
      desc = "heuristics service health";
    };
    integrations = {
      port = 8110;
      metricsPort = 8127;
      desc = "integrations service HTTP (proxy /integrations here)";
    };
    canvases = {
      port = 8114;
      metricsPort = 8128;
      desc = "canvases service (web canvas uploads at /v1/web/images)";
    };
    images = {
      port = 8115;
      metricsPort = 8129;
      desc = "images service (mobile screenshot uploads at /v1/mobile/images)";
    };
    spot = {
      port = 8116;
      metricsPort = 8130;
      desc = "spot service (Spot recorder REST API; proxy /spot here)";
    };
  };

  # Export the service's secrets, then run its body. Built here so a service names its secrets once, in `secretsNeeded`.
  mkScript =
    name: secretsNeeded: body:
    pkgs.writeShellApplication {
      name = "openreplay-${name}";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        ${(resolveSecrets secretsNeeded).preamble}
        ${body}
      '';
    };

  # Build a systemd service for one process from its shell body.
  mkService =
    {
      name,
      description,
      script,
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
      // environment;
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "openreplay";
        WorkingDirectory = cfg.stateDir;
        Restart = "on-failure";
        RestartSec = 5;
        ExecStart = lib.getExe (mkScript name secretsNeeded script);
        # An empty list renders no unit lines, so no special case is needed.
        LoadCredential = sec.loadCredential;
      }
      // extraServiceConfig;
    };

  # Go worker: DSNs + secrets, ensure the FS scratch dir, exec the binary.
  goService =
    {
      name,
      environment ? { },
      secretsNeeded ? [ ],
      clickhouse ? false,
      objectStore ? false,
    }:
    mkService {
      inherit name secretsNeeded;
      description = "OpenReplay ${name} service";
      environment = {
        SERVICE_NAME = name;
        HTTP_HOST = cfg.listenAddress;
        HTTP_PORT = toString cfg.${name}.port;
        METRICS_PORT = toString cfg.${name}.metricsPort;
        LOG_QUEUE_STATS_INTERVAL_SEC = "60";
        REDIS_STREAMS_MAX_LEN = "10000";
        HOSTNAME = "openreplay-${name}";
      }
      // topics
      // lib.optionalAttrs objectStore objectStorage
      // environment;
      script = ''
        ${dsnPreamble { inherit clickhouse; }}
        [ -n "''${FS_DIR:-}" ] && mkdir -p "$FS_DIR" || true
        # Named binary inside the Go backend package (cmd/http -> "http").
        exec ${lib.getExe' cfg.package name}
      '';
    };

  # Shared shape for the init one-shots: after network, run once, as the service user.
  mkOneShot =
    {
      description,
      script,
      secretsNeeded ? [ ],
      path ? [ ],
      after ? [ ],
      requires ? [ ],
      extraServiceConfig ? { },
    }:
    let
      sec = resolveSecrets secretsNeeded;
    in
    {
      inherit description path requires;
      after = [ "network-online.target" ] ++ after;
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      script = ''
        ${sec.preamble}
        ${script}
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.group;
        LoadCredential = sec.loadCredential;
      }
      // extraServiceConfig;
    };

  # clickhouse-client args, with the password only when one is configured.
  chClientArgs = ''
    args=(--host ${cfg.clickhouse.host} --port ${toString cfg.clickhouse.tcpPort} --user ${cfg.clickhouse.username})
    if [ -n "''${OR_CH_PASSWORD:-}" ]; then
      args+=(--password "$OR_CH_PASSWORD")
    fi
  '';

  # Secret option: a path to the file holding it. A non-null `nullMeans` makes it optional.
  secretFileOpt =
    slug: desc: nullMeans:
    lib.mkOption (
      {
        example = "/run/secrets/openreplay-${slug}";
        description = ''
          Path to a file holding the ${desc}. Read at service start via systemd
          LoadCredential, so the secret never reaches the Nix store.
          ${lib.optionalString (nullMeans != null) "Null ${nullMeans}."}
        '';
      }
      // (
        if nullMeans == null then
          { type = lib.types.str; }
        else
          {
            type = lib.types.nullOr lib.types.str;
            default = null;
          }
      )
    );
in
{
  # Literal secrets are gone (they landed in the store). Fail loudly on the old options.
  imports =
    lib.mapAttrsToList
      (
        old: new:
        lib.mkRemovedOptionModule (lib.splitString "." "services.openreplay.${old}") ''
          Secrets are only accepted as file paths. Set services.openreplay.${new} to a
          path whose file holds the value — e.g. config.sops.secrets.<name>.path, or any
          other file materialised at runtime under /run/secrets.
        ''
      )
      {
        "postgres.password" = "postgres.passwordFile";
        "clickhouse.password" = "clickhouse.passwordFile";
        "redis.password" = "redis.passwordFile";
        "smtp.password" = "smtp.passwordFile";
        "s3.secretKey" = "s3.secretKeyFile";
        "secrets.tokenSecret" = "secrets.tokenSecretFile";
        "secrets.jwtSecret" = "secrets.jwtSecretFile";
        "secrets.jwtRefreshSecret" = "secrets.jwtRefreshSecretFile";
        "secrets.jwtSpotSecret" = "secrets.jwtSpotSecretFile";
        "secrets.jwtSpotRefreshSecret" = "secrets.jwtSpotRefreshSecretFile";
        "secrets.assistJwtSecret" = "secrets.assistJwtSecretFile";
      };

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

    # SMTP for the dashboard API and the alerts scheduler. Null host disables email.
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
      passwordFile =
        secretFileOpt "smtp-password" "SMTP login password (EMAIL_PASSWORD)"
          "skips password authentication";
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
      passwordFile =
        secretFileOpt "postgres-password" "Postgres password"
          "builds a password-less DSN (peer/trust auth)";
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
      passwordFile =
        secretFileOpt "clickhouse-password" "ClickHouse password"
          "builds a password-less DSN";
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
      passwordFile = secretFileOpt "redis-password" "Redis password" "builds a password-less DSN";
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
      secretKeyFile = secretFileOpt "s3-secret-key" "S3 secret access key (AWS_SECRET_ACCESS_KEY)" null;
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

    # Paths to the files holding each secret (sops-nix, agenix, …). All required.
    secrets = {
      tokenSecretFile = secretFileOpt "token-secret" "tracker token secret" null;
      jwtSecretFile = secretFileOpt "jwt-secret" "dashboard JWT secret" null;
      jwtRefreshSecretFile = secretFileOpt "jwt-refresh-secret" "dashboard JWT refresh secret" null;
      jwtSpotSecretFile = secretFileOpt "jwt-spot-secret" "Spot JWT secret" null;
      jwtSpotRefreshSecretFile = secretFileOpt "jwt-spot-refresh-secret" "Spot JWT refresh secret" null;
      assistJwtSecretFile = secretFileOpt "assist-jwt-secret" "assist JWT secret" null;
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
  }
  # Port options for the Go services, from the table that also feeds their units.
  // lib.mapAttrs (name: p: {
    port = lib.mkOption {
      type = lib.types.port;
      default = p.port;
      description = "${p.desc} port.";
    };
    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = p.metricsPort;
      description = "${name} service /metrics + /health port.";
    };
  }) goServicePorts;

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
        assertion = cfg.s3.secretKeyFile != "";
        message = "services.openreplay.s3.secretKeyFile must be a path to a file holding the S3 secret access key.";
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
        openreplay-pg-init = mkOneShot {
          description = "OpenReplay Postgres schema init";
          secretsNeeded = [ "OR_PG_PASSWORD" ];
          path = [ pkgs.postgresql ];
          script = ''
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
        };
      })

      # one-shot: ClickHouse databases + schema
      (lib.mkIf cfg.initSchema {
        openreplay-ch-init = mkOneShot {
          description = "OpenReplay ClickHouse schema init";
          secretsNeeded = [ "OR_CH_PASSWORD" ];
          path = [ pkgs.clickhouse ];
          extraServiceConfig.Environment = [ "TZDIR=${tzDir}" ];
          script = ''
            ${chClientArgs}
            # Not safe to re-run; key on the `experimental` database it creates.
            if [ "$(clickhouse-client "''${args[@]}" --query "EXISTS DATABASE experimental")" = "1" ]; then
              echo "openreplay: clickhouse schema already present, skipping"
            else
              clickhouse-client "''${args[@]}" --multiquery < ${cfg.package.src}/scripts/schema/db/init_dbs/clickhouse/create/init_schema.sql
            fi
          '';
        };
      })

      # one-shot: ClickHouse retention TTLs. OSS keeps session data forever; MODIFY TTL is idempotent. Blob expiry is in the buckets one-shot.
      (lib.mkIf (cfg.retention.days != null && cfg.initSchema) {
        openreplay-retention = mkOneShot {
          description = "OpenReplay ClickHouse data-retention TTLs";
          secretsNeeded = [ "OR_CH_PASSWORD" ];
          path = [ pkgs.clickhouse ];
          after = [ "openreplay-ch-init.service" ];
          requires = [ "openreplay-ch-init.service" ];
          extraServiceConfig.Environment = [ "TZDIR=${tzDir}" ];
          script =
            let
              d = toString cfg.retention.days;
            in
            ''
              ${chClientArgs}
              # Sessions expire on `datetime`, events on `created_at`; keep upstream's soft-delete purge as a second clause.
              clickhouse-client "''${args[@]}" --query \
                "ALTER TABLE experimental.sessions MODIFY TTL datetime + INTERVAL ${d} DAY"
              clickhouse-client "''${args[@]}" --query \
                "ALTER TABLE product_analytics.events MODIFY TTL toDateTime(created_at) + INTERVAL ${d} DAY, _deleted_at + INTERVAL 1 DAY DELETE WHERE _deleted_at != '1970-01-01 00:00:00'"
              echo "openreplay: clickhouse retention TTL set to ${d} days"
            '';
        };
      })

      # one-shot: object-storage buckets
      (lib.mkIf cfg.initBuckets {
        openreplay-buckets = mkOneShot {
          description = "OpenReplay object-storage bucket init";
          secretsNeeded = [ "AWS_SECRET_ACCESS_KEY" ];
          path = [ pkgs.minio-client ];
          # mc writes its config under $HOME, which this one-shot does not own.
          extraServiceConfig.RuntimeDirectory = "openreplay-buckets";
          script =
            let
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
              # Replay buckets to expire. `mc ilm import` replaces the config, so it reconciles.
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
              export MC_CONFIG_DIR="$RUNTIME_DIRECTORY"
              mc alias set local ${cfg.s3.endpoint} ${cfg.s3.accessKey} "$AWS_SECRET_ACCESS_KEY"
              for b in ${lib.concatStringsSep " " cfg.s3.buckets}; do
                mc mb -p "local/$b"
              done
              mc anonymous set-json ${assetsPolicy} local/sessions-assets
              ${lib.optionalString (cfg.retention.days != null) ''
                # Best-effort: some backends reject lifecycle rules; the ClickHouse TTL still applies.
                for b in ${lib.concatStringsSep " " retentionBuckets}; do
                  mc ilm import "local/$b" < ${retentionLifecycle} \
                    || echo "openreplay: warning: lifecycle expiry not applied to $b (S3 backend may not support lifecycle rules)" >&2
                done
              ''}
            '';
        };
      })

      # ingestion pipeline (Redis Streams)
      {
        openreplay-http = goService {
          name = "http";
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

        # Derives events/issues (clicks, dead clicks, …) from the raw stream. Pure consumer.
        openreplay-heuristics = goService {
          name = "heuristics";
          secretsNeeded = [ "OR_REDIS_PASSWORD" ];
          environment = {
            GROUP_HEURISTICS = "heuristics";
          };
        };

        # Per-session <canvas> snapshots. Tracker POSTs to /v1/web/images; also consumes the canvas-trigger stream from ender. Buffers under FS_DIR/CANVAS_DIR -> mobs.
        openreplay-canvases = goService {
          name = "canvases";
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

        # Mobile replay screenshots. SDK POSTs to /v1/mobile/images; also consumes raw-images. Buffers under FS_DIR/SCREENSHOTS_DIR -> mobs.
        openreplay-images = goService {
          name = "images";
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

        # Spot: browser-extension screen recorder, not session replay. REST API at /v1/spots; proxy /spot/ stripping the prefix. Dashboard JWT + Spot JWT.
        openreplay-spot = goService {
          name = "spot";
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

        # Third-party log integrations (Sentry, Datadog, …); proxied at /integrations.
        openreplay-integrations = goService {
          name = "integrations";
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
          name = "api";
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
              # Presigns the replay DOM for the browser, so it must sign against a browser-reachable origin, not the loopback `endpoint`.
              AWS_ENDPOINT = cfg.s3.publicEndpoint;
              FS_DIR = "${cfg.stateDir}/api";
              # Live sessions: query the assist server at sprintf(ASSIST_URL, ASSIST_KEY).
              ASSIST_URL = assistUrlEnv;
              ASSIST_KEY = cfg.assistKey;
            };
          script = ''
            ${dsnPreamble { clickhouse = true; }}
            mkdir -p "$FS_DIR"
            exec ${lib.getExe' cfg.package "api"}
          '';
        };

        # Python dashboard REST API (chalice; FastAPI/uvicorn)
        openreplay-chalice = mkService {
          name = "chalice";
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
            # Internal: boto3 presigns virtual-hosted URLs the gateway can't route. Only supplementary assets (canvas frames, sourcemaps); the DOM is signed by the Go API.
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
            # chalice formats this with SMR_KEY -> http://host:port/smr/sourcemaps. The {} is Python str.format, passed through.
            sourcemaps_reader = "http://${cfg.listenAddress}:${toString cfg.sourcemapreader.port}/{}/sourcemaps";
          }
          // smtpEnv;
          script = ''
            # The Python API reads these under its own names (python-decouple).
            export pg_password="''${OR_PG_PASSWORD:-}"
            export ch_password="''${OR_CH_PASSWORD:-}"
            export S3_SECRET="$AWS_SECRET_ACCESS_KEY"
            ${dsnPreamble { }}
            exec ${lib.getExe cfg.chalice.package} --host ${cfg.listenAddress} --port ${toString cfg.chalice.port} --proxy-headers --log-level warning
          '';
        };

        # Live sessions / co-browsing (Node + socket.io). Proxy /ws-assist/ (strip -> /socket) and /assist/. WebRTC media is peer-to-peer.
        openreplay-assist = mkService {
          name = "assist";
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
          script = "exec ${lib.getExe cfg.assist.package}";
        };

        # Stack-trace symbolication, called by the chalice API. Internal only.
        openreplay-sourcemapreader = mkService {
          name = "sourcemapreader";
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
          script = ''
            # The Node service reads the S3 secret from S3_SECRET.
            export S3_SECRET="$AWS_SECRET_ACCESS_KEY"
            exec ${lib.getExe cfg.sourcemapreader.package}
          '';
        };

        # Notification scheduler (chalice codebase, APScheduler; no HTTP surface). CH_POOL=false / ASSIST_KEY=ignore match upstream's entrypoint.
        openreplay-alerts = mkService {
          name = "alerts";
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
          script = ''
            export pg_password="''${OR_PG_PASSWORD:-}"
            export ch_password="''${OR_CH_PASSWORD:-}"
            export S3_SECRET="$AWS_SECRET_ACCESS_KEY"
            ${dsnPreamble { }}
            exec ${lib.getExe cfg.alerts.package} --host ${cfg.listenAddress} --port ${toString cfg.alerts.port} --log-level warning
          '';
        };
      }
    ];
  };
}
