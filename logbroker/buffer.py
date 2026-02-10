"""
Персистентный буфер логов: запись в файл, отправка батчами в ClickHouse не чаще раза в секунду.
Переживает перезапуск (данные в файле), гарантирует доставку (повтор при ошибках).
"""
import asyncio
import os
import time
from pathlib import Path

import httpx

from config import (
    BUFFER_PATH,
    CLICKHOUSE_HOST,
    CLICKHOUSE_PORT,
    CLICKHOUSE_USER,
    CLICKHOUSE_PASSWORD,
    FLUSH_INTERVAL_SEC,
)

CLICKHOUSE_URL = f"http://{CLICKHOUSE_HOST}:{CLICKHOUSE_PORT}"
INSERT_QUERY = "INSERT INTO default.logs (ts, message) FORMAT TabSeparated"


def _escape_tsv(s: str) -> str:
    """Экранирование для TabSeparated: \\, \\n, \\t, \\r."""
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")


def _format_tsv_line(ts: str, message: str) -> str:
    """Одна строка TSV: ts\tmessage (message экранирован)."""
    return f"{ts}\t{_escape_tsv(message)}\n"


async def send_batch_to_clickhouse(rows: list[tuple[str, str]]) -> None:
    """Отправить батч в ClickHouse. При ошибке — выбросить исключение (повтор снаружи)."""
    if not rows:
        return
    body = "".join(_format_tsv_line(ts, msg) for ts, msg in rows)
    # В новых образах ClickHouse HTTP-интерфейс часто требует пароль.
    # Явно указываем user=default и пустой пароль, чтобы избежать REQUIRED_PASSWORD.
    params = {
        "query": INSERT_QUERY,
        "user": CLICKHOUSE_USER,
        "password": CLICKHOUSE_PASSWORD,
    }
    async with httpx.AsyncClient(timeout=30.0) as client:
        r = await client.post(CLICKHOUSE_URL, params=params, content=body)
        r.raise_for_status()


def _ensure_dir():
    Path(BUFFER_PATH).parent.mkdir(parents=True, exist_ok=True)


def append_to_buffer(lines: list[str]) -> None:
    """Дописать строки в конец файла буфера (по одной строке лога на строку файла)."""
    _ensure_dir()
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    with open(BUFFER_PATH, "a", encoding="utf-8", errors="replace") as f:
        for line in lines:
            line = line.rstrip("\n\r")
            f.write(f"{ts}\t{line}\n")
        f.flush()
        os.fsync(f.fileno())


def read_buffer() -> list[tuple[str, str]]:
    """
    Прочитать весь буфер, вернуть список (ts, message).
    После успешной отправки в CH нужно вызвать truncate_buffer().
    """
    path = Path(BUFFER_PATH)
    if not path.exists():
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    rows = []
    for line in content.strip().split("\n"):
        if not line:
            continue
        parts = line.split("\t", 1)
        ts = parts[0] if len(parts) > 0 else ""
        msg = parts[1] if len(parts) > 1 else ""
        rows.append((ts, msg))
    return rows


def truncate_buffer() -> None:
    """Очистить файл буфера после успешной отправки в ClickHouse."""
    path = Path(BUFFER_PATH)
    if path.exists():
        path.write_text("")


async def flush_once() -> bool:
    """
    Прочитать буфер, отправить в ClickHouse (с повторами при ошибках), при успехе очистить буфер.
    Возвращает True если был непустой буфер и он успешно отправлен.
    """
    rows = read_buffer()
    if not rows:
        return False
    last_error = None
    for attempt in range(5):
        try:
            await send_batch_to_clickhouse(rows)
            truncate_buffer()
            return True
        except Exception as e:
            last_error = e
            await asyncio.sleep(1.0 * (attempt + 1))
    raise last_error
