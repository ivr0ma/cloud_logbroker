import os

CLICKHOUSE_HOST = os.environ.get("CLICKHOUSE_HOST", "127.0.0.1")
CLICKHOUSE_PORT = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
CLICKHOUSE_USER = os.environ.get("CLICKHOUSE_USER", "default")
CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "")

BUFFER_PATH = os.environ.get("BUFFER_PATH", "/var/lib/logbroker/buffer.log")
FLUSH_INTERVAL_SEC = float(os.environ.get("FLUSH_INTERVAL_SEC", "1.0"))
