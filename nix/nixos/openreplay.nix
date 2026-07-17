{ self }:
# NixOS module for the OpenReplay session-replay services. Runs only the app
# processes OpenReplay ships — the Go backend workers (http, sink, db, ender,
# storage, assets, heuristics, canvases, images), integrations, spot, the "v2"
# API, the Python dashboard API (chalice) + alerts scheduler, the assist server,
# and the sourcemapreader — plus the one-shot schema/bucket init upstream omits.
# It does NOT stand up Postgres, ClickHouse, Redis, an object store, or a gateway:
# point it at existing stores via options and front it with your own nginx/caddy.
# The dashboard SPA is exposed as `config.services.openreplay.dashboardRoot`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.openreplay;

  # Path to a named binary inside the Go backend package (cmd/http -> "http").
  orBin = name: lib.getExe' cfg.package name;
  # The pinned checkout, via the backend package's `src` — reused for schema SQL
  # and the Python API so the version stays pinned in one place.
  orSrc = cfg.package.src;

  # Python runtime for the chalice dashboard API and alerts scheduler (both run
  # from ${orSrc}/api against this env — not a built package). Every entry maps to
  # a line in the source's api/requirements.txt; all are in nixpkgs, no Docker.
  pyEnv = pkgs.python313.withPackages (
    ps: with ps; [
      fastapi
      uvicorn
      psycopg # psycopg[binary]
      psycopg-pool # psycopg[pool]
      psycopg2 # psycopg2-binary
      clickhouse-connect
      boto3
      pyjwt
      python-decouple
      pydantic
      email-validator # pydantic[email]
      apscheduler
      redis
      elasticsearch
      jira
      cachetools
      requests
      urllib3
    ]
  );

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
  assistUrl = "http://${cfg.listenAddress}:${toString cfg.ports.assist}/assist/%s";
  # systemd expands %-specifiers in Environment= values, eating the %s above;
  # double it so the process receives a literal %s.
  assistUrlEnv = lib.replaceStrings [ "%" ] [ "%%" ] assistUrl;

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

  # Init one-shots every service waits on. The seed is included so the Python API
  # only decides whether to register the pre-signup /health route after a tenant
  # exists — else it exposes the failing onboarding check until its next restart.
  initUnits =
    lib.optionals cfg.initSchema [
      "openreplay-pg-init.service"
      "openreplay-ch-init.service"
    ]
    ++ lib.optional cfg.initBuckets "openreplay-buckets.service"
    ++ lib.optional cfg.seed.enable "openreplay-seed.service";

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
  goWorker =
    {
      name,
      port,
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
          exec ${orBin name}
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
      defaultText = lib.literalExpression "openreplay-nix.packages.\${system}.openreplay-backend";
      description = "The Go backend package (also provides the pinned source via `.src`).";
    };
    dashboardPackage = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.openreplay-dashboard;
      defaultText = lib.literalExpression "openreplay-nix.packages.\${system}.openreplay-dashboard";
      description = "The built dashboard SPA (static site).";
    };
    assistPackage = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.openreplay-assist;
      defaultText = lib.literalExpression "openreplay-nix.packages.\${system}.openreplay-assist";
      description = "The assist server package (live sessions / co-browsing).";
    };
    sourcemapreaderPackage = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.openreplay-sourcemapreader;
      defaultText = lib.literalExpression "openreplay-nix.packages.\${system}.openreplay-sourcemapreader";
      description = "The sourcemapreader server package (JS stack-trace symbolication).";
    };
    dashboardRoot = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = cfg.dashboardPackage;
      defaultText = lib.literalExpression "config.services.openreplay.dashboardPackage";
      description = ''
        The static dashboard SPA root. Point your reverse proxy's document root
        at this; this module does not serve it.
      '';
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
    siteUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost";
      description = "Public base URL the dashboard is served from (SITE_URL).";
    };
    assetsOrigin = lib.mkOption {
      type = lib.types.str;
      default = cfg.siteUrl;
      defaultText = lib.literalExpression "config.services.openreplay.siteUrl";
      description = "Origin recorded assets are served from (ASSETS_ORIGIN).";
    };
    assistKey = lib.mkOption {
      type = lib.types.str;
      default = "openreplaydev";
      description = ''
        Shared path segment for the assist socket (/assist/<key>), used by the
        assist server and the dashboard/API. Not a secret.
      '';
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

    seed = {
      enable = lib.mkEnableOption ''
        seeding an initial tenant and owner login so the dashboard skips the
        signup/onboarding flow. That flow's installation health-check probes each
        backend at its Kubernetes service DNS, which is absent on a single host, so
        it always fails; seeding a tenant makes the API skip the route and go
        straight to login. The seed is reconciled on every rebuild: it inserts the
        tenant/owner when missing and otherwise updates the existing rows (tenant
        name, owner email/name, password, optional project) to match this config —
        so changing a value here and redeploying updates the seeded account, and
        also overwrites UI changes (e.g. a password reset) on the next rebuild,
        since the Nix configuration is the source of truth'';
      email = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "admin@example.com";
        description = "Owner login email (the API validates it as an email address).";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "Admin";
        description = "Owner display name.";
      };
      tenantName = lib.mkOption {
        type = lib.types.str;
        default = "OpenReplay";
        description = "Tenant (organisation) name.";
      };
      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Owner login password (plain; ends up in the Nix store).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Runtime path to a file holding the owner login password (kept out of the store).";
      };
      projectName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Name of an initial project to seed. Null (the default) seeds only the
          tenant and owner credentials — no project — so the first project is
          created from the dashboard like a normal signup.
        '';
      };
      projectKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Fixed tracker project key for the seeded project (only when projectName
          is set). Also the stable identity used to reconcile the project on later
          rebuilds, so with a fixed key the project can be renamed via projectName.
          Null lets Postgres generate a random one (read it from the dashboard
          afterwards); the project is then matched by name for reconciliation, so
          it cannot be renamed.
        '';
      };
    };

    ports = {
      http = lib.mkOption {
        type = lib.types.port;
        default = 8100;
        description = "Ingest (http) service port.";
      };
      sink = lib.mkOption {
        type = lib.types.port;
        default = 8101;
        description = "sink service health port.";
      };
      db = lib.mkOption {
        type = lib.types.port;
        default = 8102;
        description = "db service health port.";
      };
      ender = lib.mkOption {
        type = lib.types.port;
        default = 8103;
        description = "ender service health port.";
      };
      storage = lib.mkOption {
        type = lib.types.port;
        default = 8104;
        description = "storage service health port.";
      };
      assets = lib.mkOption {
        type = lib.types.port;
        default = 8105;
        description = "assets service port.";
      };
      goApi = lib.mkOption {
        type = lib.types.port;
        default = 8106;
        description = "Go \"v2\" API port (session search, served at /v2/api).";
      };
      dashboardApi = lib.mkOption {
        type = lib.types.port;
        default = 8000;
        description = "Python dashboard REST API port (served at /api).";
      };
      assist = lib.mkOption {
        type = lib.types.port;
        default = 8107;
        description = "Assist (live sessions) socket.io port; proxy /assist + /ws-assist here.";
      };
      assistHealth = lib.mkOption {
        type = lib.types.port;
        default = 8108;
        description = "Assist health/metrics port.";
      };
      heuristics = lib.mkOption {
        type = lib.types.port;
        default = 8109;
        description = "heuristics service health port.";
      };
      integrations = lib.mkOption {
        type = lib.types.port;
        default = 8110;
        description = "integrations service HTTP port (proxy /integrations here).";
      };
      sourcemapreader = lib.mkOption {
        type = lib.types.port;
        default = 8111;
        description = "sourcemapreader service port (queried by the dashboard API).";
      };
      sourcemapreaderHealth = lib.mkOption {
        type = lib.types.port;
        default = 8112;
        description = "sourcemapreader health port.";
      };
      alerts = lib.mkOption {
        type = lib.types.port;
        default = 8113;
        description = "alerts scheduler health/listen port.";
      };
      canvases = lib.mkOption {
        type = lib.types.port;
        default = 8114;
        description = "canvases service port (web canvas uploads at /v1/web/images).";
      };
      images = lib.mkOption {
        type = lib.types.port;
        default = 8115;
        description = "images service port (mobile screenshot uploads at /v1/mobile/images).";
      };
      spot = lib.mkOption {
        type = lib.types.port;
        default = 8116;
        description = "spot service port (Spot recorder REST API; proxy /spot here).";
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
        default = cfg.assetsOrigin;
        defaultText = lib.literalExpression "config.services.openreplay.assetsOrigin";
        description = ''
          Browser-facing S3 endpoint used to *presign* session-replay asset URLs
          — the DOM "mob" files the player downloads, canvas frames, and
          sourcemaps. These presigned URLs are fetched directly by the user's
          browser, so this must be an origin the browser can reach, and your
          reverse proxy must route the bucket paths (/mobs, /sessions-assets, …)
          to the object store while forwarding the original Host header
          unchanged (SigV4 signs the host, so a rewritten Host fails validation).

          Defaults to assetsOrigin (the public site). Leaving this equal to
          `endpoint` — e.g. a loopback address — only works when the browser
          runs on this same host (a local dev stack); on a real deployment the
          presigned URLs would point at an address the browser cannot reach and
          replays render blank.
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
        defaultText = lib.literalExpression "<fetched uap-core regexes.yaml>";
        description = "UAParser regexes file (UAPARSER_FILE); required by the http service.";
      };
      maxmind = lib.mkOption {
        type = lib.types.path;
        default = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/maxmind/MaxMind-DB/main/test-data/GeoLite2-City-Test.mmdb";
          hash = "sha256-+TZwK1HctslLKG13pvGCwxoWAbr0sn6OiWk03rQfSfI=";
        };
        defaultText = lib.literalExpression "<fetched GeoLite2-City-Test.mmdb (sample data)>";
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
        assertion = !cfg.seed.enable || cfg.seed.email != "";
        message = "services.openreplay.seed.email must be set when seed.enable is true.";
      }
      {
        assertion =
          !cfg.seed.enable || (cfg.seed.password != null) != (cfg.seed.passwordFile != null);
        message = "Set exactly one of services.openreplay.seed.password / passwordFile when seed.enable is true.";
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
                psql -v ON_ERROR_STOP=1 -f ${orSrc}/scripts/schema/db/init_dbs/postgresql/init_schema.sql
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
                clickhouse-client "''${args[@]}" --multiquery < ${orSrc}/scripts/schema/db/init_dbs/clickhouse/create/init_schema.sql
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

      # one-shot: seed initial tenant + owner login (+ optional project). Mirrors the
      # rows the upstream signup flow creates: a fresh deploy comes up past onboarding
      # with a known login, and later rebuilds reconcile them (insert or update).
      # Skipping onboarding stops the k8s-only installation health-check being served.
      (lib.mkIf cfg.seed.enable {
        openreplay-seed = {
          description = "OpenReplay initial tenant/owner seed";
          after = [ "network-online.target" ] ++ lib.optional cfg.initSchema "openreplay-pg-init.service";
          wants = [ "network-online.target" ];
          requires = lib.optional cfg.initSchema "openreplay-pg-init.service";
          wantedBy = [ "multi-user.target" ];
          serviceConfig =
            let
              sec = resolveSecrets [ "OR_PG_PASSWORD" ];
              usePwFile = cfg.seed.passwordFile != null;
              envList =
                lib.mapAttrsToList (n: v: "${n}=${v}") sec.environment
                ++ lib.optional (!usePwFile) "SEED_PASSWORD=${cfg.seed.password}";
              creds = sec.loadCredential ++ lib.optional usePwFile "seed-password:${cfg.seed.passwordFile}";
            in
            {
              Type = "oneshot";
              RemainAfterExit = true;
              User = cfg.user;
              Group = cfg.group;
            }
            // lib.optionalAttrs (creds != [ ]) { LoadCredential = creds; }
            // lib.optionalAttrs (envList != [ ]) { Environment = envList; };
          script =
            let
              sec = resolveSecrets [ "OR_PG_PASSWORD" ];
              # The password is bound as a psql variable (:'pw'), so a passwordFile
              # value is read at runtime, never serialised into the store; non-secret
              # fields are embedded directly.
              #
              # Each entity is an insert-when-missing + update-in-place pair reading
              # the same statement-start snapshot, so exactly one fires. Data-modifying
              # CTEs always run to completion (even if the final SELECT ignores them),
              # so every pair reconciles even with no project configured. The owner is
              # keyed by its 'owner' role, not its email, so the email can be changed
              # here and reconciled onto the existing owner rather than duplicated.
              seedProject = cfg.seed.projectName != null;
              hasProjectKey = cfg.seed.projectKey != null;
              projCols = lib.optionalString hasProjectKey ", project_key";
              projVals = lib.optionalString hasProjectKey ", '${cfg.seed.projectKey}'";
              # Identify the seeded project by its fixed project_key when one is set
              # (so its name can be changed here), otherwise fall back to its name.
              projMatch =
                if hasProjectKey then
                  "project_key = '${cfg.seed.projectKey}'"
                else
                  "name = '${cfg.seed.projectName}'";
              projectCtes = lib.optionalString seedProject ''
                , p_ins AS (
                  INSERT INTO public.projects (name, active${projCols})
                  SELECT '${cfg.seed.projectName}', TRUE${projVals}
                  WHERE NOT EXISTS (SELECT 1 FROM public.projects WHERE ${projMatch})
                  RETURNING project_id
                ), p_upd AS (
                  UPDATE public.projects SET name = '${cfg.seed.projectName}', active = TRUE
                  WHERE ${projMatch}
                  RETURNING project_id
                )'';
              projectCounts = lib.optionalString seedProject ''
                ,
                  (SELECT count(*) FROM p_ins) AS project_inserted,
                  (SELECT count(*) FROM p_upd) AS project_updated'';
              seedSql = pkgs.writeText "openreplay-seed.sql" ''
                WITH t_ins AS (
                  INSERT INTO public.tenants (name)
                  SELECT '${cfg.seed.tenantName}' WHERE NOT EXISTS (SELECT 1 FROM public.tenants)
                  RETURNING tenant_id
                ), t_upd AS (
                  UPDATE public.tenants SET name = '${cfg.seed.tenantName}'
                  WHERE tenant_id = (SELECT min(tenant_id) FROM public.tenants)
                  RETURNING tenant_id
                ), u_ins AS (
                  INSERT INTO public.users (email, role, name)
                  SELECT '${cfg.seed.email}', 'owner', '${cfg.seed.name}'
                  WHERE NOT EXISTS (SELECT 1 FROM public.users WHERE role = 'owner')
                  RETURNING user_id
                ), u_upd AS (
                  UPDATE public.users SET email = '${cfg.seed.email}', name = '${cfg.seed.name}'
                  WHERE user_id = (SELECT min(user_id) FROM public.users WHERE role = 'owner')
                  RETURNING user_id
                ), owner_user AS (
                  SELECT user_id FROM u_ins
                  UNION ALL
                  SELECT user_id FROM u_upd
                ), au_ins AS (
                  INSERT INTO public.basic_authentication (user_id, password)
                  SELECT user_id, crypt(:'pw', gen_salt('bf', 12)) FROM owner_user
                  WHERE NOT EXISTS (
                    SELECT 1 FROM public.basic_authentication ba
                    WHERE ba.user_id = (SELECT user_id FROM owner_user)
                  )
                  RETURNING user_id
                ), au_upd AS (
                  UPDATE public.basic_authentication SET password = crypt(:'pw', gen_salt('bf', 12))
                  WHERE user_id = (SELECT user_id FROM owner_user)
                  RETURNING user_id
                )${projectCtes}
                SELECT
                  (SELECT count(*) FROM t_ins) AS tenant_inserted,
                  (SELECT count(*) FROM t_upd) AS tenant_updated,
                  (SELECT count(*) FROM u_ins) AS owner_inserted,
                  (SELECT count(*) FROM u_upd) AS owner_updated,
                  (SELECT count(*) FROM au_ins) AS password_inserted,
                  (SELECT count(*) FROM au_upd) AS password_updated${projectCounts};
              '';
            in
            ''
              ${sec.preamble}
              ${lib.optionalString (cfg.seed.passwordFile != null) ''
                export SEED_PASSWORD="$(cat "$CREDENTIALS_DIRECTORY/seed-password")"
              ''}
              export PGPASSWORD="''${OR_PG_PASSWORD:-}"
              export PGHOST=${cfg.postgres.host} PGPORT=${toString cfg.postgres.port} PGUSER=${cfg.postgres.user} PGDATABASE=${cfg.postgres.database}
              psql -v ON_ERROR_STOP=1 -v pw="$SEED_PASSWORD" -f ${seedSql}
              echo "openreplay: seed reconciled (rows inserted when missing, otherwise updated to match config)"
            '';
          path = [ pkgs.postgresql ];
        };
      })

      # ingestion pipeline (Redis Streams)
      {
        openreplay-http = goWorker {
          name = "http";
          port = cfg.ports.http;
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

        openreplay-sink = goWorker {
          name = "sink";
          port = cfg.ports.sink;
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

        openreplay-db = goWorker {
          name = "db";
          port = cfg.ports.db;
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

        openreplay-ender = goWorker {
          name = "ender";
          port = cfg.ports.ender;
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

        openreplay-storage = goWorker {
          name = "storage";
          port = cfg.ports.storage;
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

        openreplay-assets = goWorker {
          name = "assets";
          port = cfg.ports.assets;
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
        openreplay-heuristics = goWorker {
          name = "heuristics";
          port = cfg.ports.heuristics;
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
        openreplay-canvases = goWorker {
          name = "canvases";
          port = cfg.ports.canvases;
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
        openreplay-images = goWorker {
          name = "images";
          port = cfg.ports.images;
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
        openreplay-spot = goWorker {
          name = "spot";
          port = cfg.ports.spot;
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
        openreplay-integrations = goWorker {
          name = "integrations";
          port = cfg.ports.integrations;
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
        openreplay-goapi = mkService {
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
              HTTP_PORT = toString cfg.ports.goApi;
              JWT_ISSUER = "OpenReplay-oss";
              BUCKET_NAME = "mobs";
              # Presigns the replay DOM ("mob") URLs the player fetches from the
              # browser, so it must sign against the browser-reachable origin, not
              # the loopback `endpoint` other workers use. Overrides objectStorage's.
              AWS_ENDPOINT = cfg.s3.publicEndpoint;
              FS_DIR = "${cfg.stateDir}/goapi";
              # Live sessions: query the assist server at sprintf(ASSIST_URL, ASSIST_KEY).
              ASSIST_URL = assistUrlEnv;
              ASSIST_KEY = cfg.assistKey;
            };
          command = pkgs.writeShellApplication {
            name = "openreplay-goapi";
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
              exec ${orBin "api"}
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
            LISTEN_PORT = toString cfg.ports.dashboardApi;
            ASSIST_URL = assistUrlEnv;
            ASSIST_KEY = cfg.assistKey;
            # Symbolication: chalice formats this with SMR_KEY (default "smr") ->
            # http://host:port/smr/sourcemaps, matching the sourcemapreader route.
            # The literal {} is Python str.format (not shell/systemd), passed through.
            sourcemaps_reader = "http://${cfg.listenAddress}:${toString cfg.ports.sourcemapreader}/{}/sourcemaps";
          };
          command = pkgs.writeShellApplication {
            name = "openreplay-pyapi";
            runtimeInputs = [
              pyEnv
              pkgs.coreutils
            ];
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
              ]).preamble
              }
              # The Python API reads these under its own names (python-decouple).
              export pg_password="''${OR_PG_PASSWORD:-}"
              export ch_password="''${OR_CH_PASSWORD:-}"
              export S3_SECRET="''${AWS_SECRET_ACCESS_KEY:-}"
              ${dsnPreamble { }}
              # uvicorn needs a writable workdir with the app + .env; copy the
              # pinned source out of the store on each start.
              work="${cfg.stateDir}/api"
              rm -rf "$work" && mkdir -p "$work"
              cp -r ${orSrc}/api/. "$work/" && chmod -R u+w "$work"
              cd "$work"
              [ -f env.default ] && mv -f env.default .env
              exec uvicorn app:app --host ${cfg.listenAddress} --port ${toString cfg.ports.dashboardApi} --proxy-headers --log-level warning
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
            LISTEN_PORT = toString cfg.ports.assist;
            HEALTH_PORT = toString cfg.ports.assistHealth;
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
              exec ${lib.getExe cfg.assistPackage}
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
            SMR_PORT = toString cfg.ports.sourcemapreader;
            # health.js binds its own listener on LISTEN_HOST:HEALTH_PORT.
            LISTEN_HOST = cfg.listenAddress;
            HEALTH_PORT = toString cfg.ports.sourcemapreaderHealth;
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
              exec ${lib.getExe cfg.sourcemapreaderPackage}
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
            LISTEN_PORT = toString cfg.ports.alerts;
            ASSIST_KEY = "ignore";
          };
          command = pkgs.writeShellApplication {
            name = "openreplay-alerts-run";
            runtimeInputs = [
              pyEnv
              pkgs.coreutils
            ];
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
              ]).preamble
              }
              export pg_password="''${OR_PG_PASSWORD:-}"
              export ch_password="''${OR_CH_PASSWORD:-}"
              export S3_SECRET="''${AWS_SECRET_ACCESS_KEY:-}"
              ${dsnPreamble { }}
              # uvicorn needs a writable working copy of the app; the alerts
              # entrypoint runs app_alerts:app rather than chalice's app:app.
              work="${cfg.stateDir}/alerts"
              rm -rf "$work" && mkdir -p "$work"
              cp -r ${orSrc}/api/. "$work/" && chmod -R u+w "$work"
              cd "$work"
              [ -f env.default ] && mv -f env.default .env
              exec uvicorn app_alerts:app --host ${cfg.listenAddress} --port ${toString cfg.ports.alerts} --log-level warning
            '';
          };
        };
      }
    ];
  };
}
