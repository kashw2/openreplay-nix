{ self, pkgs }:
pkgs.testers.runNixOSTest {
  name = "openreplay";

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ self.nixosModules.openreplay ];

      virtualisation = {
        memorySize = 6144;
        diskSize = 10240;
        cores = 4;
      };

      services.postgresql = {
        enable = true;
        enableTCPIP = true;
        authentication = pkgs.lib.mkForce ''
          local all all trust
          host  all all 127.0.0.1/32 trust
          host  all all ::1/128      trust
        '';
      };

      services.clickhouse.enable = true;

      services.redis.servers.openreplay = {
        enable = true;
        port = 6379;
        bind = "127.0.0.1";
      };

      systemd.services.seaweedfs =
        let
          s3Config = pkgs.writeText "seaweedfs-s3.json" (
            builtins.toJSON {
              identities = [
                {
                  name = "openreplay";
                  credentials = [
                    {
                      accessKey = "minioadmin";
                      secretKey = "minioadminpassword";
                    }
                  ];
                  actions = [
                    "Admin"
                    "Read"
                    "Write"
                    "List"
                    "Tagging"
                  ];
                }
              ];
            }
          );
        in
        {
          description = "SeaweedFS S3-compatible object store";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = ''
              ${lib.getExe pkgs.seaweedfs} server \
                -dir=/var/lib/seaweedfs \
                -ip=127.0.0.1 \
                -s3 -s3.port=9002 -s3.config=${s3Config}
            '';
            StateDirectory = "seaweedfs";
            Restart = "on-failure";
          };
        };

      # Secrets are file paths only. systemd reads LoadCredential sources as root, so /etc files are fine here.
      environment.etc =
        lib.mapAttrs' (name: value: lib.nameValuePair "openreplay-secrets/${name}" { text = value; })
          {
            "s3-secret-key" = "minioadminpassword";
            "token-secret" = "test-token-secret";
            "jwt-secret" = "test-jwt-secret";
            "jwt-refresh-secret" = "test-jwt-refresh-secret";
            "jwt-spot-secret" = "test-jwt-spot-secret";
            "jwt-spot-refresh-secret" = "test-jwt-spot-refresh-secret";
            "assist-jwt-secret" = "test-assist-jwt-secret";
          };

      services.openreplay = {
        enable = true;

        postgres = {
          host = "127.0.0.1";
          user = "postgres";
          database = "openreplay";
          createDatabase = true;
        };
        clickhouse.host = "127.0.0.1";
        redis.host = "127.0.0.1";

        # Exercise the data-retention path (ClickHouse TTLs + object lifecycle).
        retention.days = 30;

        s3 = {
          endpoint = "http://127.0.0.1:9002";
          region = "us-east-1";
          accessKey = "minioadmin";
          secretKeyFile = "/etc/openreplay-secrets/s3-secret-key";
          disableSslVerify = true;
        };

        secrets = {
          tokenSecretFile = "/etc/openreplay-secrets/token-secret";
          jwtSecretFile = "/etc/openreplay-secrets/jwt-secret";
          jwtRefreshSecretFile = "/etc/openreplay-secrets/jwt-refresh-secret";
          jwtSpotSecretFile = "/etc/openreplay-secrets/jwt-spot-secret";
          jwtSpotRefreshSecretFile = "/etc/openreplay-secrets/jwt-spot-refresh-secret";
          assistJwtSecretFile = "/etc/openreplay-secrets/assist-jwt-secret";
        };
      };

      systemd.services.openreplay-pg-init = {
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
      };
      systemd.services.openreplay-ch-init = {
        after = [ "clickhouse.service" ];
        requires = [ "clickhouse.service" ];
      };
      systemd.services.openreplay-buckets = {
        after = [ "seaweedfs.service" ];
        requires = [ "seaweedfs.service" ];
        preStart = ''
          for _ in $(seq 1 60); do
            ${lib.getExe pkgs.curl} -s -o /dev/null http://127.0.0.1:9002/ && exit 0
            sleep 1
          done
          echo "seaweedfs S3 did not become ready on :9002" >&2
          exit 1
        '';
      };

      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    start_all()

    with subtest("datastores come up"):
        machine.wait_for_unit("postgresql.service")
        machine.wait_for_unit("clickhouse.service")
        machine.wait_for_unit("redis-openreplay.service")
        machine.wait_for_unit("seaweedfs.service")
        machine.wait_for_open_port(9002)

    with subtest("schema and bucket init one-shots succeed"):
        machine.wait_for_unit("openreplay-pg-init.service")
        machine.wait_for_unit("openreplay-ch-init.service")
        try:
            machine.wait_for_unit("openreplay-buckets.service")
        except Exception:
            print(machine.execute("journalctl -u openreplay-buckets.service --no-pager")[1])
            raise
        machine.succeed(
            "psql -h 127.0.0.1 -U postgres -d openreplay -tAc "
            "\"SELECT to_regclass('public.tenants')\" | grep -q tenants"
        )

    with subtest("retention TTLs are applied to ClickHouse"):
        machine.wait_for_unit("openreplay-retention.service")
        # MODIFY TTL leaves a TTL clause on the session table's DDL.
        machine.succeed(
            "clickhouse-client --query 'SHOW CREATE TABLE experimental.sessions' | grep -q TTL"
        )
        # ClickHouse re-renders `INTERVAL 30 DAY` as `toIntervalDay(30)` in DDL.
        machine.succeed(
            "clickhouse-client --query 'SHOW CREATE TABLE product_analytics.events' "
            "| grep -qE 'toIntervalDay\\(30\\)|INTERVAL 30 DAY'"
        )

    with subtest("backend workers start"):
        for svc in ["http", "sink", "db", "ender", "storage", "assets", "heuristics", "canvases"]:
            machine.wait_for_unit(f"openreplay-{svc}.service")
        # Only http/integrations bind a TCP port; the rest are pure stream consumers.
        machine.wait_for_open_port(8100)

    with subtest("integrations service starts and listens"):
        machine.wait_for_unit("openreplay-integrations.service")
        machine.wait_for_open_port(8110)

    with subtest("images service starts and listens"):
        # Binds a TCP port for mobile screenshot uploads, unlike the consumers above.
        machine.wait_for_unit("openreplay-images.service")
        machine.wait_for_open_port(8115)

    with subtest("spot service starts and listens"):
        # Serves the Spot recorder REST API (/v1/spots, /spots/…) on a TCP port.
        machine.wait_for_unit("openreplay-spot.service")
        machine.wait_for_open_port(8116)

    with subtest("APIs and assist server start and listen"):
        machine.wait_for_unit("openreplay-api.service")
        machine.wait_for_open_port(8106)
        machine.wait_for_unit("openreplay-chalice.service")
        machine.wait_for_open_port(8000)
        machine.wait_for_unit("openreplay-assist.service")
        machine.wait_for_open_port(8107)

    with subtest("sourcemapreader starts and listens"):
        machine.wait_for_unit("openreplay-sourcemapreader.service")
        machine.wait_for_open_port(8111)

    with subtest("alerts scheduler starts and listens"):
        machine.wait_for_unit("openreplay-alerts.service")
        machine.wait_for_open_port(8113)

    with subtest("http ingest endpoint answers"):
        machine.succeed("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8100/")
  '';
}
