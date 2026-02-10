"""
Logbroker: приём логов (POST /write_log), персистентная буферизация,
отправка в ClickHouse батчами не чаще раза в секунду и при shutdown.
"""
import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import PlainTextResponse

from buffer import append_to_buffer, flush_once
from config import FLUSH_INTERVAL_SEC

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

flush_task: asyncio.Task | None = None


async def flush_loop():
    """Периодическая отправка буфера в ClickHouse не чаще раза в секунду."""
    global flush_task
    while True:
        try:
            await asyncio.sleep(FLUSH_INTERVAL_SEC)
            await flush_once()
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.exception("Flush error: %s", e)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global flush_task
    flush_task = asyncio.create_task(flush_loop())
    yield
    # Shutdown: остановить цикл и один раз дослать буфер
    if flush_task:
        flush_task.cancel()
        try:
            await flush_task
        except asyncio.CancelledError:
            pass
    try:
        await flush_once()
        logger.info("Final flush on shutdown done")
    except Exception as e:
        logger.exception("Final flush failed: %s", e)
    flush_task = None


app = FastAPI(title="Logbroker", lifespan=lifespan)


@app.post("/write_log", response_class=PlainTextResponse)
async def write_log(request: Request):
    """
    Принять тело запроса как логи (текст, построчно).
    После записи на диск возвращаем 200 OK — гарантия доставки в ClickHouse.
    """
    body = await request.body()
    text = body.decode("utf-8", errors="replace")
    lines = [line for line in text.split("\n") if line.strip()]
    if not lines:
        return PlainTextResponse("", status_code=200)
    append_to_buffer(lines)
    return PlainTextResponse("", status_code=200)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/ping")
async def ping():
    return ""
