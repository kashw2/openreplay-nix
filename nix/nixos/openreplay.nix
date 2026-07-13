{ self }:
# NixOS module that provisions the OpenReplay session-replay services on a host.
# It runs only the application processes (the Go backend workers, the Go "v2"
# API, and the Python dashboard API) plus the one-shot schema/bucket init that
# OpenReplay does not apply itself. It deliberately does NOT stand up Postgres,
# ClickHouse, Redis, or an object store, nor a reverse-proxy gateway — you point
# it at existing stores via connection options and route to it with your own
# nginx/caddy. The static dashboard SPA is exposed as a package option
# (`config.services.openreplay.dashboardRoot`) for that reverse proxy to serve.
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
  # The single pinned OpenReplay source checkout, reached through the backend
  # package's `src` (which is openreplay-src). Reused here for the schema SQL and
  # the Python dashboard API so the version stays pinned in exactly one place.
  orSrc = cfg.package.src;

  # Python runtime for the legacy dashboard REST API (FastAPI on uvicorn); the
  # Go "v2" API is upstream's path forward. Not a built package — it runs from
  # ${orSrc}/api against this env (see the openreplay-api service), so it is
  # defined inline here rather than exposed as a customisable option. Every
  # entry maps to a line in the pinned source's api/requirements.txt; all are in
  # nixpkgs, so no Docker image is needed.
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

  # Redis-Streams "topics" — OSS OpenReplay queues through Redis, not Kafka.
  # These are the defaults baked into upstream's backend/Dockerfile; the config
  # structs still mark them required, so they are passed explicitly.
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

  # The APIs build the live-session REST URL as sprintf(ASSIST_URL, ASSIST_KEY),
  # so the %s placeholder is required (matches upstream chalice/api env).
  assistUrl = "http://${cfg.listenAddress}:${toString cfg.ports.assist}/assist/%s";
  # systemd expands %-specifiers in Environment= values (%s = the service user's
  # shell), which would eat the sprintf placeholder above. Double the % so the
  # process receives a literal %s.
  assistUrlEnv = lib.replaceStrings [ "%" ] [ "%%" ] assistUrl;

  # ---- secret handling (both plain and file, per secret) ----
  # Every secret has a plain `xxx` option and a `xxxFile` option. A *File value
  # is loaded via systemd LoadCredential and exported from the credentials dir
  # at runtime, so it never lands in the world-readable Nix store. A plain value
  # is passed via Environment= (which does land in the store — the documented
  # tradeoff). Passwords embedded in DSNs (Postgres/Redis/ClickHouse) are
  # assembled at runtime from these exported shell vars.
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

  # Given the list of secret env names a process needs, resolve them into the
  # systemd LoadCredential entries, the shell preamble that exports the file
  # ones, and the plain Environment entries for the string ones.
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

  # Runtime DSN assembly. Reads the OR_*_PASSWORD shell vars (set either from a
  # credential file or a plain Environment value) and builds the connection
  # strings the services expect, so a file-based password is never serialised
  # into the unit / store.
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

  # The init one-shots each service must wait on.
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

  # A Go backend worker (http/sink/db/ender/storage/assets): assemble DSNs +
  # secrets, ensure the FS scratch dir exists, then exec the binary.
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
        description = "S3-compatible endpoint URL.";
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
      # ---- one-shot: Postgres extensions + schema ----
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

      # ---- one-shot: ClickHouse databases + schema ----
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

      # ---- one-shot: object-storage buckets ----
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
            in
            ''
              ${sec.preamble}
              export MC_CONFIG_DIR="$RUNTIME_DIRECTORY"
              mc alias set local ${cfg.s3.endpoint} ${cfg.s3.accessKey} "$AWS_SECRET_ACCESS_KEY"
              for b in ${lib.concatStringsSep " " cfg.s3.buckets}; do
                mc mb -p "local/$b"
              done
              mc anonymous set-json ${assetsPolicy} local/sessions-assets
            '';
          path = [ pkgs.minio-client ];
        };
      })

      # ---- ingestion pipeline (Redis Streams) ----
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

        # ---- Go "v2" API (dashboard session search etc.) ----
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

        # ---- Python dashboard REST API (FastAPI/uvicorn) ----
        openreplay-api = mkService {
          description = "OpenReplay Python dashboard API";
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
              # uvicorn needs a writable working dir with the app + .env, so copy
              # the pinned source out of the read-only store on each start.
              work="${cfg.stateDir}/api"
              rm -rf "$work" && mkdir -p "$work"
              cp -r ${orSrc}/api/. "$work/" && chmod -R u+w "$work"
              cd "$work"
              [ -f env.default ] && mv -f env.default .env
              exec uvicorn app:app --host ${cfg.listenAddress} --port ${toString cfg.ports.dashboardApi} --proxy-headers --log-level warning
            '';
          };
        };

        # ---- assist: live sessions / co-browsing (Node + socket.io signalling) ----
        # Front it with your reverse proxy: /ws-assist/ (socket.io, WebSocket upgrade,
        # strip the prefix -> the server's /socket path) and /assist/ (REST live-session
        # list). WebRTC media is peer-to-peer between agent and visitor.
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
      }
    ];
  };
}
