# Logbroker

Сервис приёма логов с персистентной буферизацией и отправкой в ClickHouse батчами (не чаще раза в секунду).

## API

- **POST /write_log** — принять логи. Тело запроса — текст, каждая строка = одна запись лога. После записи на диск возвращается 200 OK (гарантия доставки в ClickHouse).
- **GET /health** — проверка состояния.
- **GET /ping** — для балансировщика.

## Переменные окружения

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `CLICKHOUSE_HOST` | 127.0.0.1 | Хост ClickHouse |
| `CLICKHOUSE_PORT` | 8123 | Порт HTTP ClickHouse |
| `BUFFER_PATH` | /var/lib/logbroker/buffer.log | Файл буфера на диске |
| `FLUSH_INTERVAL_SEC` | 1.0 | Интервал отправки батча в ClickHouse (сек) |

## Запуск локально

```bash
cd logbroker
pip install -r requirements.txt
export CLICKHOUSE_HOST=10.2.0.24   # IP ВМ ClickHouse в подсети
uvicorn main:app --host 0.0.0.0 --port 80
```

На ВМ лучше запускать через systemd или в screen с `--port 80`.

## Пример

```bash
curl -X POST http://localhost/write_log -d 'first log line
second log line'
```
