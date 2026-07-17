# OpenReplay's Go backend — all cmd/* binaries (see subPackages). Built like
# upstream's backend/Dockerfile: CGO + the `dynamic` tag so confluent-kafka-go
# links a system librdkafka. The OSS runtime queues through Redis Streams, not
# Kafka, but the kafka bindings are still compiled in, so librdkafka is required
# at build time.
{
  buildGoModule,
  # Pinned checkout (see openreplay-src.nix), kept whole-repo so the module can
  # reuse this package's `src` for schema SQL; the Go module is under backend/.
  openreplay-src,
  pkg-config,
  rdkafka,
  cyrus_sasl,
  zlib,
  zstd,
  lz4,
  openssl,
}:
buildGoModule {
  pname = "openreplay-backend";
  inherit (openreplay-src) version;

  src = openreplay-src;
  modRoot = "backend";

  subPackages = [
    "cmd/http"
    "cmd/sink"
    "cmd/db"
    "cmd/ender"
    "cmd/storage"
    "cmd/assets"
    "cmd/heuristics" # Derives events/issues from raw messages
    "cmd/integrations" # HTTP service for third-party log integrations
    "cmd/canvases" # Archives <canvas> snapshots for replay
    "cmd/images" # Mobile session screenshot uploads
    "cmd/spot" # Spot browser-extension screen recorder
    "cmd/api" # The v2 api servers session dashboards
  ];

  vendorHash = "sha256-+e/lU8HXa8DhTCY84L9fwPSuzWvopmEZjVKu3CLv/g0=";

  tags = [ "dynamic" ];
  env.CGO_ENABLED = "1";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    rdkafka
    cyrus_sasl
    zlib
    zstd
    lz4
    openssl
  ];
}
