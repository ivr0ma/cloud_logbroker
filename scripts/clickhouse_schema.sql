-- Таблица для логов от logbroker
CREATE TABLE IF NOT EXISTS default.logs
(
    ts      DateTime,
    message String
)
ENGINE = MergeTree()
ORDER BY ts;
