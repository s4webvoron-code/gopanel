#!/usr/bin/env bash
# =====================================================================
# GoPanel v1.0.63 — Patch Release
# + FIX: NameError log в metrics.py (NameError при AccessDenied)
# + FIX: Race condition retry в gopanel-systemctl при чтении services.json
# + FIX: gopanel-attach — attach вместо new-session (лишний процесс)
# + FIX: _last_control LRU-ограничение в dashboard.py
# + FIX: Ограничение флагов в gopanel-journalctl (whitelist)
# + FIX: exit code в start-tmux.sh (надёжная передача кода завершения)
# + NEW: Колонка CPU в таблице мониторинга сервисов
# + NEW: Уведомление о восстановлении сервиса (alerts)
# + NEW: Панель горячих клавиш и статистики сессии на Dashboard
# + FIX: Throttle-ключ алертов включает level — восстановление больше не подавляется
# + FIX: AlertsPanel растягивается до InfoPanel (убран фиксированный height)
# + FIX: CPU всегда показывал 0.0% — psutil.Process кешируется между вызовами
# + FIX: Удалён нефункциональный экран метрик (клавиша 3), InfoPanel обновлена
# =====================================================================
set -Eeuo pipefail
umask 0022
trap 'echo "❌ Install failed at line $LINENO" >&2; exit 1' ERR
[[ $EUID -eq 0 ]] || { echo "❌ Run as root"; exit 1; }

command -v systemctl >/dev/null 2>&1 || { echo "❌ systemd is required"; exit 1; }

info() { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

APP_USER="monitor"
APP_DIR="/opt/gopanel"
CONF_DIR="/etc/gopanel"
LOG_DIR="/var/log/gopanel"
TMUX_SOCKET="$APP_DIR/tmux.sock"

PY="$(command -v python3)"
[[ -x "$PY" ]] || { err "python3 not found"; exit 1; }

if ! "$PY" -c 'import sys; assert sys.version_info >= (3,12)' 2>/dev/null; then
    err "Python 3.12 or newer is required"; exit 1
fi

if ! locale -a 2>/dev/null | grep -qi 'utf-8\|utf8'; then
    err "UTF-8 locale is required for proper UI rendering"; exit 1
fi

write_file() {
    local path="$1"
    local mode="${2:-0644}"
    mkdir -p "$(dirname "$path")" || { err "Failed to create dir for $path"; return 1; }
    cat > "$path" || { err "Failed to write $path"; return 1; }
    chmod "$mode" "$path" || { err "Failed to chmod $path"; return 1; }
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
    python3 python3-venv python3-pip tmux sudo ca-certificates rsync procps coreutils >/dev/null 2>&1

command -v tmux >/dev/null 2>&1 || { err "tmux not found after install"; exit 1; }
ok "System packages & tmux verified"

if getent passwd "$APP_USER" >/dev/null 2>&1; then
    ok "Пользователь $APP_USER уже существует"
else
    info "Создание пользователя $APP_USER"
    useradd -r -m -s /usr/bin/bash "$APP_USER" || { err "Не удалось создать пользователя $APP_USER"; exit 1; }
    ok "Пользователь $APP_USER создан"
fi

install -d -o "$APP_USER" -g "$APP_USER" -m 0750 "$APP_DIR" "$CONF_DIR" "$LOG_DIR"
mkdir -p "$APP_DIR/src/gopanel/ui/screens" "$APP_DIR/src/gopanel/ui/widgets"
chown -R "$APP_USER:$APP_USER" "$APP_DIR/src"
chmod -R 0750 "$APP_DIR/src"

# ======================== PYTHON SOURCE ========================

write_file "$APP_DIR/src/gopanel/__init__.py" <<'PY'
__version__ = "1.0.63"
PY

write_file "$APP_DIR/src/gopanel/config.py" <<'PY'
from __future__ import annotations

import os
from pathlib import Path

from pydantic_settings import BaseSettings
from pydantic import Field


class Settings(BaseSettings):
    config_path: Path = Field(
        default_factory=lambda: Path(os.getenv("GOPANEL_CONFIG", "/etc/gopanel/services.json"))
    )
    log_path: Path = Field(
        default_factory=lambda: Path(os.getenv("GOPANEL_LOG", "/var/log/gopanel/gopanel.log"))
    )
    poll_interval: float = Field(default=2.0, ge=0.5, le=60.0)
    use_sudo: bool = True
    sudo_binary: Path = Path("/usr/bin/sudo")
    systemctl: Path = Path("/usr/local/bin/gopanel-systemctl")
    journalctl: Path = Path("/usr/local/bin/gopanel-journalctl")

    class Config:
        env_prefix = "GOPANEL_"
        case_sensitive = False


settings = Settings()
PY

write_file "$APP_DIR/src/gopanel/utils.py" <<'PY'
from __future__ import annotations

import asyncio
import logging
import os
import re
import tempfile
from pathlib import Path
from typing import Sequence

from .config import settings


log = logging.getLogger("gopanel.utils")

UNIT_RE = re.compile(r"^[A-Za-z0-9_@][A-Za-z0-9_.@\-]{0,253}\.service$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,63}$")


def is_safe_unit(name: str) -> bool:
    return bool(UNIT_RE.match(name))


def is_safe_name(name: str) -> bool:
    return bool(NAME_RE.match(name))


def assert_safe_unit(name: str) -> str:
    if not is_safe_unit(name):
        raise ValueError(f"Unsafe unit: {name!r}")
    return name


async def run_exec(
    cmd: Sequence[str | Path],
    *,
    sudo: bool = False,
    timeout: float = 10.0
) -> tuple[int, str, str]:
    argv: list[str] = [str(c) for c in cmd]
    if sudo:
        argv = [str(settings.sudo_binary), "-n", "--", *argv]

    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return proc.returncode or 0, stdout.decode("utf-8", "replace"), stderr.decode("utf-8", "replace")
    except asyncio.TimeoutError:
        if proc:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            try:
                await proc.wait()
            except Exception:
                pass
        return 124, "", "timeout"
    except FileNotFoundError as e:
        return 127, "", str(e)


async def run_stream(
    cmd: Sequence[str | Path],
    *,
    sudo: bool = False,
    timeout: float = 10.0
):
    argv: list[str] = [str(c) for c in cmd]
    if sudo:
        argv = [str(settings.sudo_binary), "-n", "--", *argv]
    return await asyncio.wait_for(
        asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL
        ),
        timeout=timeout
    )


def atomic_write(path: Path, data: str, *, mode: int = 0o640) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".gopanel-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, str(path))
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
PY

write_file "$APP_DIR/src/gopanel/registry.py" <<'PY'
from __future__ import annotations

import fcntl
import json
import logging
import threading
import re
from pathlib import Path
from pydantic import BaseModel, Field, field_validator
from .config import settings
from .utils import atomic_write, assert_safe_unit

log = logging.getLogger("gopanel.registry")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,63}$")
MAX_SERVICES = 1000
LOCK_FILE = "/opt/gopanel/registry.lock"


class ServiceEntry(BaseModel):
    name: str = Field(min_length=1, max_length=64)
    unit: str = Field(min_length=1, max_length=255)
    group: str = Field(default="default", max_length=32)
    description: str = Field(default="", max_length=256)
    critical: bool = False
    tags: list[str] = Field(default_factory=list)
    manual_restarts: int = Field(default=0, ge=0)

    @field_validator('name')
    @classmethod
    def validate_name(cls, v):
        if not NAME_RE.match(v):
            raise ValueError(f"Invalid service name: {v!r}")
        return v

    def model_post_init(self, __context) -> None:
        assert_safe_unit(self.unit)


class Registry:
    def __init__(self, path: Path | None = None):
        self.path = path or settings.config_path
        self._lock = threading.RLock()
        self._services: dict[str, ServiceEntry] = {}
        Path(LOCK_FILE).parent.mkdir(parents=True, exist_ok=True)
        self.reload()

    def reload(self) -> bool:
        """Перечитывает реестр. Возвращает True при успехе, False при ошибке парсинга."""
        with self._lock:
            if not self.path.exists():
                log.warning("Registry file %s not found, keeping current data", self.path)
                return False
            try:
                raw = json.loads(self.path.read_text(encoding="utf-8"))
                items = raw.get("services", []) if isinstance(raw, dict) else []
                loaded: dict[str, ServiceEntry] = {}
                for obj in items:
                    try:
                        e = ServiceEntry.model_validate(obj)
                        loaded[e.name] = e
                    except Exception as ex:
                        log.warning("Skip %r: %s", obj, ex)
                self._services = loaded
                return True
            except Exception as e:
                log.error("Registry parse error, keeping old state: %s", e)
                return False

    def _flush_locked(self):
        payload = {"version": 1, "services": [s.model_dump() for s in self._services.values()]}
        Path(LOCK_FILE).parent.mkdir(parents=True, exist_ok=True)
        
        try:
            with open(LOCK_FILE, "w") as lf:
                fcntl.flock(lf, fcntl.LOCK_EX)
                try:
                    atomic_write(self.path, json.dumps(payload, ensure_ascii=False, indent=2))
                finally:
                    fcntl.flock(lf, fcntl.LOCK_UN)
        except OSError:
            atomic_write(self.path, json.dumps(payload, ensure_ascii=False, indent=2))

    def list(self) -> tuple[ServiceEntry, ...]:
        with self._lock:
            return tuple(self._services.values())

    def get(self, name: str) -> ServiceEntry | None:
        with self._lock:
            return self._services.get(name)

    def add(self, entry: ServiceEntry):
        with self._lock:
            if len(self._services) >= MAX_SERVICES:
                raise ValueError(f"Max services limit ({MAX_SERVICES}) reached")
            if entry.name in self._services:
                raise ValueError(f"{entry.name!r} exists")
            self._services[entry.name] = entry
            self._flush_locked()

    def update(self, entry: ServiceEntry):
        with self._lock:
            if entry.name not in self._services:
                raise KeyError(entry.name)
            self._services[entry.name] = entry
            self._flush_locked()

    def delete(self, name: str):
        with self._lock:
            if name not in self._services:
                raise KeyError(name)
            del self._services[name]
            self._flush_locked()


_registry: Registry | None = None
_registry_lock = threading.Lock()

def get_registry() -> Registry:
    global _registry
    if _registry is None:
        with _registry_lock:
            if _registry is None:
                _registry = Registry()
    return _registry
PY

write_file "$APP_DIR/src/gopanel/systemd.py" <<'PY'
from __future__ import annotations

import asyncio
import logging
import os
import re
import time
from dataclasses import dataclass
from .config import settings
from .utils import assert_safe_unit, run_exec

log = logging.getLogger("gopanel.systemd")

try:
    _HOST_ARG_MAX = os.sysconf('SC_ARG_MAX')
    if _HOST_ARG_MAX <= 0:
        _HOST_ARG_MAX = 2097152
except Exception:
    _HOST_ARG_MAX = 2097152
ARG_MAX_SAFE = int(_HOST_ARG_MAX * 0.8)

_clock_gettime_ns = getattr(time, 'clock_gettime_ns', None)

def _monotonic_ns() -> int:
    if _clock_gettime_ns is not None:
        return _clock_gettime_ns(time.CLOCK_MONOTONIC)
    return time.monotonic_ns()


@dataclass(slots=True)
class UnitStatus:
    unit: str
    active: str = "unknown"
    sub: str = "unknown"
    main_pid: int | None = None
    memory_bytes: int = 0
    uptime_sec: float | None = None
    restarts: int = 0
    description: str = ""


_PROP = re.compile(r"^([A-Za-z0-9_]+)=(.*)$")

def _parse_props(current_props: dict[str, str]) -> UnitStatus | None:
    uid = current_props.get("Id")
    if not uid:
        return None
    st = UnitStatus(unit=uid)
    st.active = current_props.get("ActiveState", "unknown")
    st.sub = current_props.get("SubState", "unknown")
    st.description = current_props.get("Description", "")
    try:
        st.main_pid = int(current_props.get("MainPID", "0")) or None
    except ValueError:
        st.main_pid = None
    try:
        st.memory_bytes = int(current_props.get("MemoryCurrent", "0"))
    except ValueError:
        st.memory_bytes = 0
    try:
        st.restarts = int(current_props.get("NRestarts", "0"))
    except ValueError:
        st.restarts = 0
    mono_raw = current_props.get("ActiveEnterTimestampMonotonic", "0")
    if mono_raw != "0" and st.active == "active":
        try:
            enter_us = int(mono_raw)
            now_us = _monotonic_ns() // 1000
            delta = now_us - enter_us
            if delta > 0:
                st.uptime_sec = delta / 1_000_000
        except (ValueError, OverflowError):
            pass
    return st


def _parse_show_output(out: str) -> dict[str, UnitStatus]:
    result: dict[str, UnitStatus] = {}
    current_props: dict[str, str] = {}
    for line in out.splitlines():
        if not line.strip():
            st = _parse_props(current_props)
            if st:
                result[st.unit] = st
            current_props = {}
            continue
        m = _PROP.match(line)
        if m:
            current_props[m.group(1)] = m.group(2)
    st = _parse_props(current_props)
    if st:
        result[st.unit] = st
    return result


def _estimate_cmd_len(units: list[str]) -> int:
    base = [str(settings.systemctl), "show", "--no-pager",
            "--property=Id,ActiveState,SubState,MainPID,MemoryCurrent,NRestarts,ActiveEnterTimestampMonotonic,Description"]
    return sum(len(a) for a in base) + sum(len(u) for u in units) + len(units)


_fallback_sem = asyncio.Semaphore(5)

async def batch_show(units: list[str]) -> dict[str, UnitStatus]:
    if not units:
        return {}
    safe_units = [u for u in units if assert_safe_unit(u)]
    if not safe_units:
        return {}
    all_results: dict[str, UnitStatus] = {}
    idx = 0
    while idx < len(safe_units):
        chunk = []
        while idx < len(safe_units):
            trial = chunk + [safe_units[idx]]
            if _estimate_cmd_len(trial) > ARG_MAX_SAFE:
                break
            chunk.append(safe_units[idx])
            idx += 1
        if not chunk:
            chunk = [safe_units[idx]]
            idx += 1
        cmd = [settings.systemctl, "show", "--no-pager",
               "--property=Id,ActiveState,SubState,MainPID,MemoryCurrent,NRestarts,ActiveEnterTimestampMonotonic,Description"]
        cmd.extend(chunk)
        code, out, err = await run_exec(cmd, sudo=settings.use_sudo, timeout=15)
        if code != 0:
            log.error("batch_show chunk failed (%d units): %s", len(chunk), err)
            async def _single(u):
                async with _fallback_sem:
                    single_cmd = [settings.systemctl, "show", "--no-pager",
                                  "--property=Id,ActiveState,SubState,MainPID,MemoryCurrent,NRestarts,ActiveEnterTimestampMonotonic,Description",
                                  u]
                    sc, so, se = await run_exec(single_cmd, sudo=settings.use_sudo, timeout=10)
                    return sc, so, se, u
            tasks = [asyncio.create_task(_single(u)) for u in chunk]
            results = await asyncio.gather(*tasks, return_exceptions=True)
            for res in results:
                if isinstance(res, Exception):
                    log.warning("batch_show fallback exception: %s", res)
                    continue
                sc, so, se, u = res
                if sc == 0:
                    all_results.update(_parse_show_output(so))
                else:
                    log.warning("batch_show single fallback failed for %s: %s", u, se)
            continue
        all_results.update(_parse_show_output(out))
    return all_results


async def control(action: str, unit: str):
    if action not in {"start","stop","restart"}:
        raise ValueError(action)
    assert_safe_unit(unit)
    code, out, err = await run_exec([settings.systemctl, action, unit], sudo=settings.use_sudo, timeout=30)
    return code == 0, (out+err).strip() or ("ok" if code==0 else f"exit={code}")
PY

# --- FIX #3: metrics.py — добавлен import logging и log ---
write_file "$APP_DIR/src/gopanel/metrics.py" <<'PY'
from __future__ import annotations

import asyncio
import logging
import time
import threading
from collections import OrderedDict
from dataclasses import dataclass
import psutil

log = logging.getLogger("gopanel.metrics")


@dataclass(slots=True)
class HostMetrics:
    cpu_percent: float = 0.0
    mem_percent: float = 0.0
    mem_used_gb: float = 0.0
    mem_total_gb: float = 0.0
    swap_percent: float = 0.0
    disk_percent: float = 0.0
    load1: float = 0.0
    load5: float = 0.0
    load15: float = 0.0
    net_sent_mb: float = 0.0
    net_recv_mb: float = 0.0


@dataclass(slots=True)
class ProcessMetrics:
    pid: int | None = None
    cpu_percent: float = 0.0
    rss_mb: float = 0.0
    threads: int = 0
    open_fds: int = 0
    alive: bool = False


CACHE_TTL = 300.0
MAX_CACHE = 1024


class MetricsCollector:
    def __init__(self):
        self._prev_net = None
        self._loop = None
        self._proc_cache: OrderedDict[int, tuple] = OrderedDict()
        self._cache_lock = threading.Lock()
        psutil.cpu_percent(interval=None)

    def bind_loop(self, loop):
        self._loop = loop

    async def host(self):
        loop = self._loop or asyncio.get_running_loop()
        m, net = await loop.run_in_executor(None, self._host_sync, self._prev_net)
        self._prev_net = net
        return m

    async def process(self, pid):
        if pid is None:
            return ProcessMetrics()
        loop = self._loop or asyncio.get_running_loop()
        return await loop.run_in_executor(None, self._proc_sync, pid)

    @staticmethod
    def _host_sync(prev_net):
        cpu = psutil.cpu_percent(interval=None)
        mem = psutil.virtual_memory()
        swap = psutil.swap_memory()
        try:
            disk = psutil.disk_usage("/").percent
        except Exception:
            disk = 0.0
        try:
            l1, l5, l15 = psutil.getloadavg()
        except Exception:
            l1 = l5 = l15 = 0.0
        try:
            net = psutil.net_io_counters()
        except Exception:
            net = None
        sent = recv = 0.0
        cur = (0, 0)
        if net:
            cur = (net.bytes_sent, net.bytes_recv)
            if prev_net:
                sent = max(0, (net.bytes_sent - prev_net[0]) / 1024 / 1024)
                recv = max(0, (net.bytes_recv - prev_net[1]) / 1024 / 1024)
        return HostMetrics(
            cpu_percent=cpu,
            mem_percent=mem.percent,
            mem_used_gb=mem.used / 1073741824,
            mem_total_gb=mem.total / 1073741824,
            swap_percent=swap.percent,
            disk_percent=disk,
            load1=l1,
            load5=l5,
            load15=l15,
            net_sent_mb=sent,
            net_recv_mb=recv
        ), cur

    def _proc_sync(self, pid):
        now = time.monotonic()
        with self._cache_lock:
            # Чистим устаревшие записи
            while self._proc_cache:
                k, entry = next(iter(self._proc_cache.items()))
                ts = entry[1]  # позиция 1 — timestamp (формат: ct, ts, extras)
                if now - ts > CACHE_TTL:
                    del self._proc_cache[k]
                else:
                    break

            cached = self._proc_cache.get(pid)
            try:
                p = psutil.Process(pid)
                ct = p.create_time()

                # Если PID переиспользован другим процессом — сбрасываем кэш
                if cached and cached[0] != ct:
                    del self._proc_cache[pid]
                    cached = None

                # FIX CPU: используем кешированный Process-объект если он есть.
                # cpu_percent(interval=None) возвращает 0.0 при первом вызове
                # на новом объекте — psutil просто запоминает точку отсчёта.
                # При последующих вызовах того же объекта возвращается реальная дельта.
                if cached and 'proc_obj' in cached[2]:
                    p_cached = cached[2]['proc_obj']
                    try:
                        # Проверяем что процесс тот же (не зомби/переиспользован)
                        p_cached.status()
                        p = p_cached
                    except psutil.NoSuchProcess:
                        pass

                with p.oneshot():
                    cpu = p.cpu_percent(interval=None)
                    rss = p.memory_info().rss / 1048576
                    threads = p.num_threads()
                    try:
                        fds = p.num_fds()
                    except Exception:
                        fds = 0
                    alive = p.status() not in (psutil.STATUS_ZOMBIE, psutil.STATUS_DEAD)

                self._proc_cache.pop(pid, None)
                if len(self._proc_cache) >= MAX_CACHE:
                    self._proc_cache.popitem(last=False)
                # Сохраняем и timestamp, и сам объект Process для следующего вызова
                self._proc_cache[pid] = (ct, now, {'proc_obj': p})

                return ProcessMetrics(
                    pid=pid,
                    cpu_percent=cpu,
                    rss_mb=rss,
                    threads=threads,
                    open_fds=fds,
                    alive=alive
                )
            except psutil.NoSuchProcess:
                self._proc_cache.pop(pid, None)
                return ProcessMetrics(pid=pid, alive=False)
            except psutil.AccessDenied:
                log.warning("Access denied for PID %d, returning safe default", pid)
                return ProcessMetrics(pid=pid, alive=True)
PY

write_file "$APP_DIR/src/gopanel/journal.py" <<'PY'
from __future__ import annotations

import asyncio
import time
import logging
from .config import settings
from .utils import assert_safe_unit, run_exec, run_stream

log = logging.getLogger("gopanel.journal")
BACKPRESSURE_EVERY = 50
MAX_LINES_PER_SEC = 100
MAX_FOLLOW_SECONDS = 3600


async def tail(unit, n=500):
    assert_safe_unit(unit)
    try:
        code, out, err = await run_exec(
            [settings.journalctl, "-u", unit, "-n", str(n), "--no-pager", "-o", "short-iso"],
            sudo=settings.use_sudo,
            timeout=5.0
        )
        return out.strip() if code == 0 else f"[error: {err.strip()}]"
    except asyncio.TimeoutError:
        return "[error: tail timeout]"


async def follow(unit, *, stop_event, max_duration=MAX_FOLLOW_SECONDS):
    assert_safe_unit(unit)
    proc = None
    try:
        proc = await run_stream(
            [settings.journalctl, "-u", unit, "-f", "--no-pager", "-o", "short-iso"],
            sudo=settings.use_sudo,
            timeout=10
        )
    except asyncio.TimeoutError:
        yield "[error: journalctl startup timeout]"
        return
    except Exception as e:
        yield f"[error: could not start journal follow - {e}]"
        return

    start = time.monotonic()
    count = 0
    window_start = time.time()
    window_count = 0
    try:
        while not stop_event.is_set():
            if time.monotonic() - start > max_duration:
                break
            try:
                line = await asyncio.wait_for(proc.stdout.readline(), timeout=1.0)
            except asyncio.CancelledError:
                break
            except asyncio.TimeoutError:
                continue
            if not line:
                break
            now = time.time()
            if now - window_start >= 1.0:
                window_start = now
                window_count = 0
            window_count += 1
            if window_count > MAX_LINES_PER_SEC:
                await asyncio.sleep(0.05)
                continue
            count += 1
            if count % BACKPRESSURE_EVERY == 0:
                await asyncio.sleep(0)
            yield line.decode("utf-8", "replace").rstrip("\n")
    except asyncio.CancelledError:
        pass
    finally:
        if proc:
            try:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=1.0)
                except asyncio.TimeoutError:
                    try:
                        proc.kill()
                        await proc.wait()
                    except Exception:
                        pass
            except ProcessLookupError:
                pass
PY

write_file "$APP_DIR/src/gopanel/alerts.py" <<'PY'
from __future__ import annotations

import asyncio
import time
import weakref
from collections import deque
from dataclasses import dataclass


@dataclass(slots=True)
class Alert:
    ts: float
    level: str
    service: str
    message: str

    def __str__(self):
        sym = {"info": "✅", "warn": "⚠", "critical": "🔥"}.get(self.level, "•")
        from datetime import datetime
        return f"{sym} [{datetime.fromtimestamp(self.ts):%H:%M:%S}] {self.service}: {self.message}"


class AlertManager:
    def __init__(self):
        self._q = deque(maxlen=200)
        self._subs: list[weakref.ref] = []
        self._lock = asyncio.Lock()
        self._last: dict[str, float] = {}
        self._last_cleanup_ts = time.monotonic()

    async def push(self, level, service, msg):
        now = time.time()
        self._cleanup_last(now)
        # Ключ включает level: падение и восстановление одного сервиса
        # не подавляют друг друга (разные уровни — разные throttle-записи)
        throttle_key = f"{service}:{level}"
        if now - self._last.get(throttle_key, 0) < 30:
            return
        self._last[throttle_key] = now
        a = Alert(now, level, service, msg)
        async with self._lock:
            self._q.append(a)
            # Снимаем копию списка под локом — безопасная итерация
            subs = [ref() for ref in list(self._subs)]
        for q in subs:
            if q is not None:
                try:
                    q.put_nowait(a)
                except asyncio.QueueFull:
                    pass

    def _cleanup_last(self, now: float):
        if now - self._last_cleanup_ts > 300:
            cutoff = now - 600
            self._last = {k: v for k, v in self._last.items() if v > cutoff}
            self._last_cleanup_ts = now

    def history(self):
        return list(self._q)

    def subscribe(self) -> asyncio.Queue[Alert]:
        q: asyncio.Queue[Alert] = asyncio.Queue(maxsize=200)
        def _on_dead(ref, s=self._subs):
            try:
                s.remove(ref)
            except ValueError:
                pass
        self._subs.append(weakref.ref(q, _on_dead))
        return q

    def unsubscribe(self, q):
        # Итерируем по копии — безопасно при конкурентном доступе
        self._subs = [ref for ref in list(self._subs) if ref() is not None and ref() is not q]

    def cleanup_dead(self):
        self._subs = [ref for ref in list(self._subs) if ref() is not None]
PY

write_file "$APP_DIR/src/gopanel/cli.py" <<'PY'
import argparse
import sys
from .registry import ServiceEntry, get_registry
from .utils import is_safe_unit, is_safe_name


def cmd_add(args):
    if not is_safe_name(args.name):
        print(f"Bad service name: {args.name}", file=sys.stderr)
        return 2
    if not is_safe_unit(args.unit):
        print(f"Bad unit: {args.unit}", file=sys.stderr)
        return 2
    try:
        get_registry().add(ServiceEntry(
            name=args.name,
            unit=args.unit,
            group=args.group,
            description=args.description or "",
            critical=args.critical,
            tags=[t for t in (args.tags or "").split(",") if t]
        ))
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    print(f"✓ Добавлен '{args.name}'")
    return 0


def cmd_remove(args):
    try:
        get_registry().delete(args.name)
    except KeyError:
        print(f"Не найден: {args.name}", file=sys.stderr)
        return 1
    print(f"✓ Удалён '{args.name}'")
    return 0


def cmd_list(_):
    rows = get_registry().list()
    if not rows:
        print("(пусто)")
        return 0
    print(f"{'Имя':<20} {'Юнит':<30} {'Группа':<10} {'Крит':<5} Описание")
    for s in rows:
        print(f"{s.name:<20} {s.unit:<30} {s.group:<10} {'Y' if s.critical else 'N':<5} {s.description}")
    return 0


def main():
    p = argparse.ArgumentParser(prog="gopanel")
    sub = p.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("add")
    sp.add_argument("--name", required=True)
    sp.add_argument("--unit", required=True)
    sp.add_argument("--group", default="default")
    sp.add_argument("--description", default="")
    sp.add_argument("--tags", default="")
    sp.add_argument("--critical", action="store_true")
    sp.set_defaults(func=cmd_add)
    sp = sub.add_parser("remove")
    sp.add_argument("--name", required=True)
    sp.set_defaults(func=cmd_remove)
    sp = sub.add_parser("list")
    sp.set_defaults(func=cmd_list)
    args = p.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
PY

write_file "$APP_DIR/src/gopanel/__main__.py" <<'PY'
from __future__ import annotations

import logging
import sys
from logging.handlers import RotatingFileHandler
from .config import settings


def _setup_logging() -> None:
    fmt = "%(asctime)s %(levelname)-7s %(name)s: %(message)s"
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    try:
        settings.log_path.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(RotatingFileHandler(
            settings.log_path,
            maxBytes=5*1024*1024,
            backupCount=3,
            encoding="utf-8"
        ))
    except OSError:
        pass
    logging.basicConfig(level=logging.INFO, format=fmt, handlers=handlers)
    logging.getLogger("asyncio").setLevel(logging.WARNING)


def main() -> None:
    _setup_logging()
    from .app import GoPanelApp
    GoPanelApp().run()


if __name__ == "__main__":
    main()
PY

write_file "$APP_DIR/src/gopanel/app.py" <<'PY'
import asyncio
import logging
import time
from textual.app import App
from textual.binding import Binding
from .alerts import AlertManager
from .metrics import MetricsCollector
from .registry import get_registry
from .ui.screens.dashboard import DashboardScreen
from .ui.screens.logs import LogsScreen

log = logging.getLogger("gopanel.app")
NOTIFY_CLEANUP_INTERVAL = 300
NOTIFY_TTL = 600


class GoPanelApp(App):
    TITLE = "Service Monitoring and Management Center"
    SUB_TITLE = None
    CSS_PATH = "ui/theme.tcss"
    BINDINGS = [
        Binding("q", "quit", "Выход", priority=True),
        Binding("1", "screen('dashboard')", "Панель"),
        Binding("2", "screen('logs')", "Логи"),
        Binding("r", "reload", "Обновить"),
    ]

    def __init__(self):
        super().__init__()
        self.metrics = MetricsCollector()
        self.alerts = AlertManager()
        self._active_service = None
        self._last_reload: float = 0.0
        self._notify_last: dict[str, float] = {}
        self._notify_cleanup_ts = time.monotonic()

    def on_mount(self):
        self.metrics.bind_loop(asyncio.get_running_loop())
        self.install_screen(DashboardScreen(), "dashboard")
        self.install_screen(LogsScreen(), "logs")
        self.push_screen("dashboard")

    def action_screen(self, name):
        self.switch_screen(name)

    def action_reload(self):
        now = time.monotonic()
        if now - self._last_reload < 5.0:
            self.notify("Подождите 5 секунд", severity="warning")
            return
        self._last_reload = now
        try:
            ok = get_registry().reload()
            if ok:
                self.notify("✓ Реестр обновлён", severity="information")
            else:
                self.notify("⚠ Ошибка чтения реестра — работаем со старыми данными", severity="warning")
        except Exception as e:
            log.exception("reload failed")
            self.notify(f"Ошибка: {e}", severity="error")

    def throttled_notify(self, message: str, severity: str = "information", timeout: float = 2.0):
        now = time.monotonic()
        if now - self._notify_cleanup_ts > NOTIFY_CLEANUP_INTERVAL:
            cutoff = now - NOTIFY_TTL
            self._notify_last = {k: v for k, v in self._notify_last.items() if v > cutoff}
            self._notify_cleanup_ts = now
        last = self._notify_last.get(message, 0.0)
        if now - last >= timeout:
            self.notify(message, severity=severity)
            self._notify_last[message] = now
PY

: > "$APP_DIR/src/gopanel/ui/__init__.py"
: > "$APP_DIR/src/gopanel/ui/screens/__init__.py"
: > "$APP_DIR/src/gopanel/ui/widgets/__init__.py"
chown "$APP_USER:$APP_USER" \
    "$APP_DIR/src/gopanel/ui/__init__.py" \
    "$APP_DIR/src/gopanel/ui/screens/__init__.py" \
    "$APP_DIR/src/gopanel/ui/widgets/__init__.py"

write_file "$APP_DIR/src/gopanel/ui/theme.tcss" <<'CSS'
Screen {
    background: #0a0e14;
    color: #c9d1d9;
}

.large-header {
    background: #000000;
    color: #00ffaa;
    text-style: bold;
    padding: 0 2;
    height: 3;
    align: center middle;
    content-align: center middle;
}

.version-subtitle {
    background: #000000;
    color: #00d4ff;
    text-style: dim;
    padding: 0 2;
    height: 1;
    align: center middle;
    content-align: center middle;
}

Footer {
    background: #0d1218;
    color: #00ffaa;
    border-top: heavy #00ffaa;
    padding: 0 2;
}

DataTable {
    background: #0d1218;
    border: round #00d4ff;
    height: 1fr;
}

DataTable > .datatable--header {
    background: #121a24;
    color: #00ffaa;
    text-style: bold;
}

DataTable > .datatable--cursor {
    background: #00d4ff33;
    color: #ffffff;
}

.status-active { color: #00ff88; text-style: bold; }
.status-failed { color: #ff3366; text-style: bold; }
.status-inactive { color: #6b7280; }
.status-unknown { color: #ffaa00; }

.panel {
    padding: 0 2;
    margin: 0 0 0 0;
    height: auto;
    min-height: 2;
    background: #0d1218;
    color: #00ffaa;
    text-style: bold;
    border-bottom: solid #00d4ff;
}

StatusBar {
    dock: bottom;
    height: 1;
    background: #0d1218;
    color: #00ffaa;
    border-top: heavy #00ffaa;
    padding: 0 2;
}

AlertsPanel {
    height: auto;
    min-height: 10;
    border: round #ffaa00;
    background: #0d1218;
    padding: 0 1;
}

#alerts-title {
    background: #121a24;
    color: #ffaa00;
    text-style: bold;
    padding: 0 1;
}

InfoPanel {
    height: auto;
    border: round #1e3a5f;
    background: #0d1218;
    padding: 0 1;
}

.metric-card {
    width: 1fr;
    height: 7;
    border: round #00d4ff;
    background: #0d1218;
    padding: 1 2;
    margin: 1;
}

ServiceFormScreen {
    align: center middle;
}

#form {
    width: 80;
    height: auto;
    max-height: 90%;
    background: #0d1218;
    border: heavy #00ffaa;
    padding: 1 2;
}

#action-buttons {
    height: 3;
    padding: 0 1;
    margin: 1 0;
    layout: horizontal;
}

#action-buttons Button {
    margin: 0 1;
    min-width: 14;
    height: 3;
    border: tall #1a1f2e;
    text-style: bold;
}

#btn-add { background: #00ff88; color: #0a0e14; border: tall #00cc66; }
#btn-add:hover { background: #00cc66; color: #ffffff; }
#btn-edit { background: #00d4ff; color: #0a0e14; border: tall #00a8cc; }
#btn-edit:hover { background: #00a8cc; color: #ffffff; }
#btn-del { background: #ff3366; color: #ffffff; border: tall #cc2952; }
#btn-del:hover { background: #cc2952; color: #ffffff; }
#btn-start { background: #00ff88; color: #0a0e14; border: tall #00cc66; }
#btn-start:hover { background: #00cc66; color: #ffffff; }
#btn-stop { background: #ffaa00; color: #0a0e14; border: tall #cc8800; }
#btn-stop:hover { background: #cc8800; color: #ffffff; }
#btn-restart { background: #00d4ff; color: #0a0e14; border: tall #00a8cc; }
#btn-restart:hover { background: #00a8cc; color: #ffffff; }
#btn-logs { background: #6b7280; color: #ffffff; border: tall #4b5563; }
#btn-logs:hover { background: #4b5563; color: #ffffff; }
#btn-quit { background: #ff3366; color: #ffffff; border: tall #cc2952; margin-left: 2; }
#btn-quit:hover { background: #cc2952; color: #ffffff; }

#logs-actions { height: 3; padding: 0 1; margin: 1 0; layout: horizontal; }
#logs-actions Button { margin: 0 1; min-width: 16; height: 3; }
#btn-back { background: #00d4ff; color: #0a0e14; border: tall #00a8cc; text-style: bold; }
#btn-back:hover { background: #00a8cc; color: #ffffff; }
#btn-reload { background: #00ff88; color: #0a0e14; border: tall #00cc66; text-style: bold; }
#btn-reload:hover { background: #00cc66; color: #ffffff; }
#btn-clear { background: #6b7280; color: #ffffff; border: tall #4b5563; }
#btn-clear:hover { background: #4b5563; color: #ffffff; }

Button { background: #121a24; color: #00ffaa; border: tall #00d4ff; margin: 1; min-width: 16; }
Button:hover { background: #00ffaa22; color: #ffffff; }
Button.-primary { background: #00ffaa; color: #0a0e14; text-style: bold; }
Input { background: #121a24; border: tall #00d4ff; color: #c9d1d9; margin: 1; }
Input:focus { border: tall #00ffaa; }
Label { color: #00d4ff; margin: 0 1; }
#m-title, #log-title { background: #121a24; color: #00ffaa; text-style: bold; padding: 0 2; height: 3; }
CSS

write_file "$APP_DIR/src/gopanel/ui/widgets/service_table.py" <<'PY'
from textual.widgets import DataTable
from textual.message import Message


class ServiceTable(DataTable):
    BINDINGS = [
        ("a", "add", "Добавить"),
        ("e", "edit", "Изменить"),
        ("d", "del", "Удалить"),
        ("enter", "logs", "Логи"),
        ("s", "start", "Старт"),
        ("x", "stop", "Стоп"),
        ("ctrl_r", "restart", "Рестарт")
    ]

    def __init__(self):
        super().__init__(zebra_stripes=True, cursor_type="row")

    def on_mount(self):
        self.add_columns("Имя", "Юнит", "Статус", "Подстатус", "PID", "CPU", "Память", "Аптайм", "Рестарты", "Описание")

    def refresh_rows(self, services, statuses, proc_metrics=None):
        proc_metrics = proc_metrics or {}
        prev_key = None
        prev_row = self.cursor_row
        try:
            if self.cursor_row is not None:
                row = self.get_row_at(self.cursor_row)
                if row:
                    prev_key = row[0]
        except Exception:
            prev_key = None

        self.clear()
        new_row_index = None
        for idx, s in enumerate(services):
            st = statuses.get(s["unit"])
            pm = proc_metrics.get(s["unit"])
            if not st:
                row = [s["name"], s["unit"], "—", "—", "—", "—", "—", "—", "—", s["description"][:40]]
            else:
                sec = int(st.uptime_sec) if st.uptime_sec else None
                up = f"{sec // 86400}д {(sec % 86400) // 3600:02d}:{(sec % 3600) // 60:02d}" if sec else "—"
                mem = f"{st.memory_bytes / 1048576:.0f}M" if st.memory_bytes else "—"
                cpu = f"{pm.cpu_percent:.1f}%" if pm and pm.alive else "—"
                total_restarts = st.restarts + s.get("manual_restarts", 0)
                row = [
                    s["name"], s["unit"], st.active, st.sub,
                    str(st.main_pid or "—"), cpu, mem, up,
                    str(total_restarts), s["description"][:40]
                ]
            self.add_row(*row, key=s["name"])
            if prev_key and s["name"] == prev_key:
                new_row_index = idx

        try:
            if new_row_index is not None:
                self.move_cursor(row=new_row_index)
            elif prev_row is not None and prev_row < len(services):
                self.move_cursor(row=prev_row)
        except Exception:
            pass

    def selected_name(self):
        if self.cursor_row is None:
            return None
        try:
            return self.get_row_at(self.cursor_row)[0]
        except (IndexError, Exception):
            return None

    class Action(Message):
        def __init__(self, act, svc):
            self.act = act
            self.svc = svc
            super().__init__()

    def action_add(self): self.post_message(self.Action("add", None))
    def action_edit(self): self.post_message(self.Action("edit", self.selected_name()))
    def action_del(self): self.post_message(self.Action("del", self.selected_name()))
    def action_logs(self): self.post_message(self.Action("logs", self.selected_name()))
    def action_start(self): self.post_message(self.Action("start", self.selected_name()))
    def action_stop(self): self.post_message(self.Action("stop", self.selected_name()))
    def action_restart(self): self.post_message(self.Action("restart", self.selected_name()))
PY

write_file "$APP_DIR/src/gopanel/ui/widgets/status_bar.py" <<'PY'
from textual.reactive import reactive
from textual.widget import Widget
from textual.widgets import Static
from ...metrics import HostMetrics


class StatusBar(Widget):
    metrics: reactive[HostMetrics | None] = reactive(None)
    DEFAULT_CSS = "StatusBar { dock:bottom; height:1; background:#0d1218; color:#00ffaa; border-top:heavy #00ffaa; padding:0 2; }"

    def compose(self):
        yield Static("Загрузка...", id="sb")

    def watch_metrics(self, m):
        if m:
            try:
                self.query_one("#sb", Static).update(
                    f"⚡ CPU {m.cpu_percent:.1f}% │ 💾 MEM {m.mem_percent:.1f}% ({m.mem_used_gb:.1f}/{m.mem_total_gb:.1f}G) │ "
                    f"📊 LA {m.load1:.2f} {m.load5:.2f} {m.load15:.2f} │ 🌐 ↓{m.net_recv_mb:.1f} ↑{m.net_sent_mb:.1f} MB/s"
                )
            except Exception:
                pass
PY

write_file "$APP_DIR/src/gopanel/ui/widgets/alerts_panel.py" <<'PY'
import asyncio
from rich.markup import escape
from textual.widget import Widget
from textual.widgets import Static, RichLog


class AlertsPanel(Widget):
    DEFAULT_CSS = "AlertsPanel { height:auto; min-height:10; border:round #ffaa00; background:#0d1218; }"

    def __init__(self, mgr):
        super().__init__()
        self.mgr = mgr
        self._q = None
        self._t = None

    def compose(self):
        yield Static("🔔 Уведомления", id="alerts-title")
        yield RichLog(id="al", wrap=True, highlight=False, auto_scroll=True, max_lines=200, markup=True)

    def on_mount(self):
        self._q = self.mgr.subscribe()
        try:
            rl = self.query_one("#al", RichLog)
        except Exception:
            return
        for a in self.mgr.history()[-20:]:
            self._add(rl, a)
        self._t = asyncio.create_task(self._run())

    def on_unmount(self):
        if self._q:
            self.mgr.unsubscribe(self._q)
        if self._t:
            self._t.cancel()

    async def _run(self):
        try:
            cleanup_every = 100
            count = 0
            while True:
                a = await self._q.get()
                count += 1
                if count % cleanup_every == 0:
                    self.mgr.cleanup_dead()
                try:
                    rl = self.query_one("#al", RichLog)
                except Exception:
                    return
                self._add(rl, a)
        except asyncio.CancelledError:
            return

    def _add(self, rl: RichLog, a):
        c = {"critical": "#ff3366", "warn": "#ffaa00", "info": "#00ff88"}.get(a.level, "#00d4ff")
        rl.write(f"[{c}]{escape(str(a))}[/{c}]")
PY

write_file "$APP_DIR/src/gopanel/ui/screens/dashboard.py" <<'PY'
import asyncio
import logging
import time
from datetime import datetime
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import Footer, Static, Button
from ... import __version__
from ...registry import get_registry
from ...systemd import batch_show, control
from ..widgets.alerts_panel import AlertsPanel
from ..widgets.service_table import ServiceTable
from ..widgets.status_bar import StatusBar
from .service_form import ServiceFormScreen

log = logging.getLogger("gopanel.dashboard")
CONTROL_COOLDOWN = 2.0
# FIX #4: ограничиваем размер кэша cooldown-таймеров
_LAST_CONTROL_MAX = 300


class InfoPanel(Static):
    """Панель горячих клавиш и статистики сессии (Вариант А + В).

    Виджет намеренно простой — только Static, обновляется через update().
    Никакого polling внутри, никаких задач — данные приходят из _refresh()
    DashboardScreen, который уже всё считает.
    """
    DEFAULT_CSS = (
        "InfoPanel {"
        "  height: auto;"
        "  border: round #1e3a5f;"
        "  background: #0d1218;"
        "  padding: 0 1;"
        "}"
    )

    def __init__(self):
        super().__init__("")
        self._started_at = datetime.now().strftime("%H:%M:%S")

    def refresh_info(self, total: int, active: int, failed: int,
                     inactive: int, events: int) -> None:
        """Обновляет содержимое панели. Вызывается из DashboardScreen._refresh()."""
        hotkeys = (
            "[bold #00d4ff]Горячие клавиши:[/]  "
            "[#00ffaa]a[/] Добавить  "
            "[#00ffaa]e[/] Изменить  "
            "[#ff3366]d[/] Удалить  "
            "[#00ffaa]s[/] Старт  "
            "[#ffaa00]x[/] Стоп  "
            "[#00d4ff]Ctrl+R[/] Рестарт  "
            "[#6b7280]Enter[/] Логи  "
            "[#00ffaa]1[/]/[#00ffaa]2[/] Экраны  "
            "[#ff3366]q[/] Выход"
        )
        stats = (
            f"[bold #00d4ff]Сессия с {self._started_at}[/]   "
            f"Сервисов: [bold #c9d1d9]{total}[/]   "
            f"[#00ff88]▲ активных: {active}[/]   "
            f"[#ff3366]✗ упавших: {failed}[/]   "
            f"[#6b7280]◌ остановлено: {inactive}[/]   "
            f"[#ffaa00]~ событий: {events}[/]"
        )
        self.update(f"{hotkeys}\n{stats}")


class DashboardScreen(Screen):
    def __init__(self):
        super().__init__()
        self._last_control: dict[tuple[str, str], float] = {}
        # NEW: отслеживание предыдущих состояний для уведомлений о восстановлении
        self._prev_states: dict[str, str] = {}
        # NEW: счётчик событий за сессию
        self._event_count: int = 0

    def compose(self):
        yield Static(
            "[bold #00ffaa]Service Monitoring and Management Center[/]",
            id="large-header",
            classes="large-header"
        )
        yield Static(f"v{__version__}", classes="version-subtitle")
        with Vertical():
            yield Static("📊 Мониторинг сервисов", classes="panel")
            yield ServiceTable()
            with Horizontal(id="action-buttons"):
                yield Button("➕ Добавить", id="btn-add")
                yield Button("✏ Изменить", id="btn-edit")
                yield Button("🗑 Удалить", id="btn-del")
                yield Button("▶ Старт", id="btn-start")
                yield Button("⏹ Стоп", id="btn-stop")
                yield Button("🔄 Рестарт", id="btn-restart")
                yield Button("📜 Логи", id="btn-logs")
                yield Button("🚪 Выход", id="btn-quit")
            with Horizontal():
                yield AlertsPanel(self.app.alerts)
            # NEW: панель горячих клавиш + статистика сессии
            yield InfoPanel()
        yield StatusBar()
        yield Footer()

    def on_mount(self):
        self._t = asyncio.create_task(self._loop())

    async def on_unmount(self) -> None:
        self._t.cancel()
        try:
            await self._t
        except asyncio.CancelledError:
            pass

    async def _loop(self):
        from ...config import settings
        while True:
            try:
                await self._refresh()
            except asyncio.CancelledError:
                return
            except Exception as e:
                log.exception("poll: %s", e)
            await asyncio.sleep(settings.poll_interval)

    async def _refresh(self):
        try:
            tbl = self.query_one(ServiceTable)
        except Exception:
            return
        entries = get_registry().list()
        if not entries:
            tbl.refresh_rows([], {})
            self._update_info_panel([], {}, {})
            return
        units = [e.unit for e in entries]
        statuses = await batch_show(units)

        # NEW: собираем CPU-метрики по процессам (только живые PID)
        proc_metrics: dict = {}
        for e in entries:
            st = statuses.get(e.unit)
            if st and st.main_pid:
                try:
                    proc_metrics[e.unit] = await self.app.metrics.process(st.main_pid)
                except Exception:
                    pass

        rows = [
            {
                "name": e.name,
                "unit": e.unit,
                "description": e.description,
                "critical": e.critical,
                "manual_restarts": e.manual_restarts
            }
            for e in entries
        ]

        # NEW: уведомления о падении И о восстановлении
        for e in entries:
            st = statuses.get(e.unit)
            if not st or not e.critical:
                continue
            prev = self._prev_states.get(e.unit)
            curr = st.active
            if curr == "failed":
                await self.app.alerts.push("critical", e.name, f"УПАЛ ({st.sub})")
                if prev != "failed":
                    self._event_count += 1
            elif curr == "inactive":
                await self.app.alerts.push("warn", e.name, "остановлен")
                if prev not in ("inactive", None):
                    self._event_count += 1
            elif curr == "active" and prev in ("failed", "inactive"):
                # Сервис восстановился
                await self.app.alerts.push("info", e.name, "восстановлен")
                self._event_count += 1
            self._prev_states[e.unit] = curr

        tbl.refresh_rows(rows, statuses, proc_metrics)

        # NEW: обновляем панель горячих клавиш и статистики
        self._update_info_panel(entries, statuses, proc_metrics)

        try:
            self.query_one(StatusBar).metrics = await self.app.metrics.host()
        except Exception:
            pass

    def _update_info_panel(self, entries, statuses, proc_metrics) -> None:
        """Обновляет InfoPanel — вызывается только из _refresh(), безопасно."""
        try:
            panel = self.query_one(InfoPanel)
        except Exception:
            return
        total = len(entries)
        active = sum(1 for e in entries if statuses.get(e.unit) and statuses[e.unit].active == "active")
        failed = sum(1 for e in entries if statuses.get(e.unit) and statuses[e.unit].active == "failed")
        inactive = sum(1 for e in entries if statuses.get(e.unit) and statuses[e.unit].active == "inactive")
        panel.refresh_info(
            total=total,
            active=active,
            failed=failed,
            inactive=inactive,
            events=self._event_count
        )

    def on_button_pressed(self, ev: Button.Pressed) -> None:
        try:
            tbl = self.query_one(ServiceTable)
        except Exception:
            return
        sel = tbl.selected_name()
        btn_id = ev.button.id

        if btn_id == "btn-add":
            self.app.push_screen(ServiceFormScreen("add"), callback=lambda _: asyncio.create_task(self._refresh()))
        elif btn_id == "btn-edit":
            if sel:
                self.app.push_screen(ServiceFormScreen("edit", sel), callback=lambda _: asyncio.create_task(self._refresh()))
            else:
                self.app.throttled_notify("Выберите сервис (↑/↓)", severity="warning")
        elif btn_id == "btn-del":
            if sel:
                self._delete(sel)
            else:
                self.app.throttled_notify("Выберите сервис (↑/↓)", severity="warning")
        elif btn_id == "btn-logs":
            if sel:
                self.app._active_service = sel
                self.app.switch_screen("logs")
            else:
                self.app.throttled_notify("Выберите сервис (↑/↓)", severity="warning")
        elif btn_id in ("btn-start", "btn-stop", "btn-restart"):
            act = {"btn-start": "start", "btn-stop": "stop", "btn-restart": "restart"}[btn_id]
            if sel:
                asyncio.create_task(self._ctrl(act, sel))
            else:
                self.app.throttled_notify("Выберите сервис (↑/↓)", severity="warning")
        elif btn_id == "btn-quit":
            self.app.exit()

    def on_service_table_action(self, ev):
        if ev.act == "add":
            self.app.push_screen(ServiceFormScreen("add"), callback=lambda _: asyncio.create_task(self._refresh()))
        elif ev.act == "edit" and ev.svc:
            self.app.push_screen(ServiceFormScreen("edit", ev.svc), callback=lambda _: asyncio.create_task(self._refresh()))
        elif ev.act == "del" and ev.svc:
            self._delete(ev.svc)
        elif ev.act == "logs" and ev.svc:
            self.app._active_service = ev.svc
            self.app.switch_screen("logs")
        elif ev.act in {"start", "stop", "restart"} and ev.svc:
            asyncio.create_task(self._ctrl(ev.act, ev.svc))

    def _delete(self, name):
        try:
            get_registry().delete(name)
            self.app.throttled_notify(f"Удалён: {name}", severity="warning")
        except Exception as e:
            self.app.throttled_notify(str(e), severity="error")
        asyncio.create_task(self._refresh())

    def _evict_last_control(self):
        """FIX #4: удаляем устаревшие записи cooldown-кэша, чтобы он не рос бесконечно."""
        now = time.monotonic()
        # Удаляем записи старше 60 секунд (давно остыли)
        stale = [k for k, v in self._last_control.items() if now - v > 60.0]
        for k in stale:
            del self._last_control[k]
        # Если после чистки всё ещё много — обрезаем по лимиту (самые старые)
        if len(self._last_control) > _LAST_CONTROL_MAX:
            oldest = sorted(self._last_control.items(), key=lambda x: x[1])
            for k, _ in oldest[:len(self._last_control) - _LAST_CONTROL_MAX]:
                del self._last_control[k]

    async def _ctrl(self, act, name):
        key = (act, name)
        now = time.monotonic()
        last = self._last_control.get(key, 0.0)
        if now - last < CONTROL_COOLDOWN:
            self.app.throttled_notify(f"Подождите {CONTROL_COOLDOWN}с", severity="warning")
            return
        self._last_control[key] = now
        # FIX #4: периодически чистим кэш
        if len(self._last_control) > _LAST_CONTROL_MAX:
            self._evict_last_control()
        e = get_registry().get(name)
        if not e:
            return
        ok, msg = await control(act, e.unit)
        if ok and act in ("start", "restart"):
            try:
                e.manual_restarts += 1
                get_registry().update(e)
            except Exception as ex:
                log.warning("Failed to update manual_restarts for %s: %s", name, ex)
        act_ru = {"start": "СТАРТ", "stop": "СТОП", "restart": "РЕСТАРТ"}[act]
        self.app.throttled_notify(
            f"{act_ru} {name}: {'✓' if ok else '✗'} {msg[:80]}",
            severity="information" if ok else "error"
        )
        asyncio.create_task(self._refresh())
PY

write_file "$APP_DIR/src/gopanel/ui/screens/logs.py" <<'PY'
import asyncio
import logging
from rich.markup import escape
from textual.app import ComposeResult
from textual.containers import Vertical, Horizontal
from textual.screen import Screen
from textual.widgets import Footer, Static, Button, RichLog
from ... import __version__
from ..widgets.status_bar import StatusBar
from ...registry import get_registry
from ...journal import follow, tail

log = logging.getLogger("gopanel.logs")


class LogsScreen(Screen):
    BINDINGS = [("escape", "go_back", "Назад")]

    def __init__(self):
        super().__init__()
        self._task = None
        self._stop_event = asyncio.Event()
        self._current_service = None

    def compose(self):
        yield Static("[bold #00ffaa]Service Monitoring and Management Center[/]", id="log-title")
        yield Static(f"v{__version__}", classes="version-subtitle")
        with Vertical():
            with Horizontal(id="logs-actions"):
                yield Button("← Назад на панель", id="btn-back", variant="default")
                yield Button("🔄 Перезагрузить", id="btn-reload", variant="default")
                yield Button("🗑 Очистить экран", id="btn-clear", variant="default")
            yield RichLog(id="lv", wrap=True, highlight=True, auto_scroll=True, max_lines=2000, markup=True)
        yield StatusBar()
        yield Footer()

    async def on_mount(self):
        self._stop_event = asyncio.Event()
        self._task = None
        self._current_service = None

    async def on_screen_resume(self):
        target = getattr(self.app, "_active_service", None)
        log.info(f"on_screen_resume called, target={target}, current={self._current_service}")
        
        if target and target != self._current_service:
            asyncio.create_task(self._start_logs(target))

    async def on_unmount(self) -> None:
        self._stop_event.set()
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await asyncio.wait_for(self._task, timeout=1.0)
            except (asyncio.CancelledError, asyncio.TimeoutError):
                pass
            self._task = None

    def action_go_back(self):
        self.app.switch_screen("dashboard")

    def on_button_pressed(self, ev: Button.Pressed) -> None:
        if ev.button.id == "btn-back":
            self.app.switch_screen("dashboard")
        elif ev.button.id == "btn-reload":
            asyncio.create_task(self._reload_current())
        elif ev.button.id == "btn-clear":
            try:
                lv = self.query_one("#lv", RichLog)
                lv.clear()
                lv.write("[cyan]→ Экран очищен[/cyan]")
            except Exception:
                pass

    async def _reload_current(self):
        if self._current_service:
            asyncio.create_task(self._start_logs(self._current_service))
        else:
            try:
                self.query_one("#lv", RichLog).write("[yellow]⚠ Сервис не выбран[/yellow]")
            except Exception:
                pass

    async def _start_logs(self, name: str):
        log.info(f"_start_logs called for {name}")
        
        if self._task and not self._task.done():
            self._stop_event.set()
            self._task.cancel()
            try:
                await asyncio.wait_for(self._task, timeout=1.0)
            except (asyncio.CancelledError, asyncio.TimeoutError):
                pass
        
        self._current_service = name
        self._stop_event = asyncio.Event()

        try:
            lv = self.query_one("#lv", RichLog)
        except Exception:
            return

        lv.clear()
        lv.write(f"[cyan]📋 Журнал сервиса [bold]{escape(name)}[/bold][/cyan]\n[dim]Загрузка истории...[/dim]")

        entry = get_registry().get(name)
        if not entry:
            lv.write("[red]Сервис не найден в реестре[/red]")
            return

        try:
            init = await tail(entry.unit, 5)
        except Exception as ex:
            lv.write(f"[red]Ошибка: {escape(str(ex))}[/red]")
            return

        if "[error:" in init:
            lv.write(f"[red]{escape(init)}[/red]")
            return

        for line in init.splitlines():
            if line.strip():
                lv.write(f"[dim]{escape(line)}[/dim]")

        lv.write("\n[cyan]─── ▶ Получаю новые записи в реальном времени ───[/cyan]\n")
        self._task = asyncio.create_task(self._stream_logs(entry.unit, lv))

    async def _stream_logs(self, unit, lv):
        try:
            async for line in follow(unit, stop_event=self._stop_event):
                if self._stop_event.is_set():
                    return
                c = "white"
                u = line.upper()
                if "ERROR" in u or "FATAL" in u:
                    c = "#ff3366"
                elif "WARN" in u:
                    c = "#ffaa00"
                if line.startswith("[error:"):
                    c = "red"
                lv.write(f"[{c}]{escape(line)}[/{c}]")
        except asyncio.CancelledError:
            pass
        except Exception as e:
            try:
                lv.write(f"[red]Ошибка стрима: {escape(str(e))}[/red]")
            except Exception:
                pass
PY

write_file "$APP_DIR/src/gopanel/ui/screens/metrics.py" <<'PY'
import asyncio
from textual.app import ComposeResult
from textual.containers import Grid, Vertical
from textual.screen import Screen
from textual.widgets import Footer, Header, Static, Select
from ... import __version__
from ..widgets.status_bar import StatusBar
from ...registry import get_registry
from ...systemd import batch_show


class MetricsScreen(Screen):
    def compose(self):
        yield Static("[bold #00ffaa]Service Monitoring and Management Center[/]", id="m-title")
        yield Static(f"v{__version__}", classes="version-subtitle")
        with Vertical():
            yield Select([], id="ms", prompt="Выберите сервис...", allow_blank=True)
            with Grid():
                yield Static("—", id="m-pid", classes="metric-card")
                yield Static("—", id="m-cpu", classes="metric-card")
                yield Static("—", id="m-rss", classes="metric-card")
                yield Static("—", id="m-thr", classes="metric-card")
                yield Static("—", id="m-fds", classes="metric-card")
                yield Static("—", id="m-up", classes="metric-card")
                yield Static("—", id="m-rst", classes="metric-card")
        yield StatusBar()
        yield Footer()

    def on_mount(self):
        es = get_registry().list()
        try:
            self.query_one("#ms", Select).set_options([(e.name, e.name) for e in es])
        except Exception:
            return
        self._t = asyncio.create_task(self._poll())

    async def on_unmount(self) -> None:
        self._t.cancel()
        try:
            await self._t
        except asyncio.CancelledError:
            pass

    async def _poll(self):
        try:
            while True:
                try:
                    sel = self.query_one("#ms", Select)
                except Exception:
                    return
                if sel.value is not Select.BLANK and sel.value is not None and sel.value:
                    e = get_registry().get(str(sel.value))
                    if e:
                        sts = await batch_show([e.unit])
                        st = sts.get(e.unit)
                        if st:
                            pm = await self.app.metrics.process(st.main_pid)
                            sec = int(st.uptime_sec) if st.uptime_sec else None
                            up = f"{sec // 86400}д {(sec % 86400) // 3600:02d}:{(sec % 3600) // 60:02d}" if sec else "—"
                            try:
                                self.query_one("#m-pid", Static).update(f"[cyan]PID[/]\n[bold #00ffaa]{pm.pid or '—'}[/]")
                                self.query_one("#m-cpu", Static).update(f"[cyan]CPU[/]\n[bold #00ffaa]{pm.cpu_percent:.1f}%[/]")
                                self.query_one("#m-rss", Static).update(f"[cyan]Память[/]\n[bold #00ffaa]{pm.rss_mb:.1f} МБ[/]")
                                self.query_one("#m-thr", Static).update(f"[cyan]Потоки[/]\n[bold #00ffaa]{pm.threads}[/]")
                                self.query_one("#m-fds", Static).update(f"[cyan]Дескрипторы[/]\n[bold #00ffaa]{pm.open_fds}[/]")
                                self.query_one("#m-up", Static).update(f"[cyan]Аптайм[/]\n[bold #00ffaa]{up}[/]")
                                self.query_one("#m-rst", Static).update(f"[cyan]Рестарты[/]\n[bold #00ffaa]{st.restarts}[/]")
                            except Exception:
                                pass
                await asyncio.sleep(2.0)
        except asyncio.CancelledError:
            pass
PY

write_file "$APP_DIR/src/gopanel/ui/screens/service_form.py" <<'PY'
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Footer, Input, Label, Switch, Static
from ...registry import ServiceEntry, get_registry
from ...utils import is_safe_unit, is_safe_name


class ServiceFormScreen(ModalScreen[bool]):
    BINDINGS = [("escape", "cancel", "Отмена")]

    def __init__(self, mode, name=None):
        super().__init__()
        self.mode = mode
        self._name = name

    def compose(self):
        e = get_registry().get(self._name) if self._name and self.mode == "edit" else None
        t = "✏ Редактирование сервиса" if self.mode == "edit" else "➕ Добавление сервиса"
        with Vertical(id="form"):
            yield Static(t)
            yield Label("Имя (только латиница, цифры, _.-):")
            yield Input(value=e.name if e else "", placeholder="tg-bot", id="fn", disabled=self.mode == "edit")
            yield Label("Systemd юнит (например nginx.service):")
            yield Input(value=e.unit if e else "", placeholder="nginx.service", id="fu")
            yield Label("Группа:")
            yield Input(value=e.group if e else "default", id="fg")
            yield Label("Описание (можно кириллицей):")
            yield Input(value=e.description if e else "", id="fd")
            yield Label("Критический (уведомления при падении):")
            yield Switch(value=e.critical if e else False, id="fc")
            yield Button("💾 Сохранить", id="save", variant="primary")
            yield Button("❌ Отмена", id="cancel")
        yield Footer()

    def on_button_pressed(self, ev):
        if ev.button.id == "cancel":
            self.dismiss(False)
            return
        try:
            n = self.query_one("#fn", Input).value.strip()
            u = self.query_one("#fu", Input).value.strip()
        except Exception:
            self.notify("Ошибка формы", severity="error")
            return

        if not n:
            self.notify("❌ Заполните поле «Имя»", severity="error")
            return
        if not is_safe_name(n):
            self.notify(f"❌ Имя «{n}» недопустимо: только латиница, цифры, _.-", severity="error")
            return
        if not u:
            self.notify("❌ Заполните поле «Systemd юнит»", severity="error")
            return

        if not u.endswith(".service"):
            u = u + ".service"
            try:
                self.query_one("#fu", Input).value = u
            except Exception:
                pass

        if not is_safe_unit(u):
            self.notify(f"❌ Юнит «{u}» недопустим", severity="error")
            return

        entry = ServiceEntry(
            name=n,
            unit=u,
            group=self.query_one("#fg", Input).value.strip() or "default",
            description=self.query_one("#fd", Input).value.strip(),
            critical=self.query_one("#fc", Switch).value,
            tags=[]
        )
        reg = get_registry()
        try:
            if self.mode == "add":
                reg.add(entry)
            else:
                reg.update(entry)
        except Exception as ex:
            self.notify(str(ex), severity="error")
            return
        self.dismiss(True)

    def action_cancel(self):
        self.dismiss(False)
PY

# ======================== INSTALL ========================

VERSION="1.0.63"
if ! echo "$VERSION" | grep -qE '^[0-9]+(\.[0-9]+)*(\.(post|dev|a|b|rc)[0-9]+)?(\+[0-9a-zA-Z.]+)?$'; then
    err "Version '$VERSION' is not PEP 440 compliant. Aborting."
    exit 1
fi

write_file "$APP_DIR/pyproject.toml" <<TOML
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "gopanel"
version = "$VERSION"
requires-python = ">=3.12"

dependencies = [
    "textual>=0.67.1,<1.0.0",
    "psutil==5.9.8",
    "pydantic==2.7.0",
    "pydantic-settings==2.2.1"
]

[project.scripts]
gopanel = "gopanel.cli:main"
gopanel-tui = "gopanel.__main__:main"

[tool.setuptools.packages.find]
where = ["src"]

[tool.setuptools.package-data]
gopanel = ["ui/*.tcss"]
TOML

BACKUP_DIR="/tmp/gopanel-backup.$$"
if [[ -d "$APP_DIR/venv" ]]; then
    mkdir -p "$BACKUP_DIR"
    info "Creating backup to $BACKUP_DIR"
    rsync -a "$APP_DIR/" "$BACKUP_DIR/" >/dev/null || { err "Backup failed"; exit 1; }
    ok "Backup created"
fi

if [[ ! -f "$CONF_DIR/services.json" ]]; then
    write_file "$CONF_DIR/services.json" 0640 <<'JSON'
{
  "version": 1,
  "services": [
    {
      "name": "sshd",
      "unit": "ssh.service",
      "group": "infra",
      "description": "SSH сервер",
      "critical": true,
      "tags": []
    }
  ]
}
JSON
fi
chown "$APP_USER":"$APP_USER" "$CONF_DIR/services.json" 2>/dev/null || true

if systemctl is-active --quiet gopanel.service 2>/dev/null; then
    info "Остановка запущенного gopanel.service..."
    systemctl stop gopanel.service
    sleep 2
    ok "Сервис остановлен"
fi

if pgrep -u "$APP_USER" -f gopanel >/dev/null 2>&1; then
    info "Завершение оставшихся процессов..."
    pkill -u "$APP_USER" -f gopanel 2>/dev/null || true
    sleep 1
fi

if sudo -u "$APP_USER" tmux -S "$TMUX_SOCKET" has-session -t gopanel 2>/dev/null; then
    info "Завершение tmux-сессии..."
    sudo -u "$APP_USER" tmux -S "$TMUX_SOCKET" kill-session -t gopanel 2>/dev/null || true
    sleep 1
fi

info "Recreating Python virtual environment..."
rm -rf "$APP_DIR/venv"
sudo -u "$APP_USER" "$PY" -m venv "$APP_DIR/venv"
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -q --no-cache-dir --no-warn-script-location --upgrade pip wheel
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -q --no-cache-dir --no-warn-script-location \
    "textual>=0.67.1,<1.0.0" \
    psutil==5.9.8 \
    pydantic==2.7.0 \
    pydantic-settings==2.2.1
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -q --no-cache-dir "$APP_DIR" || { err "pip install failed"; exit 1; }

info "Syncing source to site-packages..."
SITE_PACKAGES="$(sudo -u "$APP_USER" "$APP_DIR/venv/bin/python" -c 'import site; print(site.getsitepackages()[0])')"
rsync -av --delete \
    "$APP_DIR/src/gopanel/" \
    "$SITE_PACKAGES/gopanel/" >/dev/null
chown -R "$APP_USER":"$APP_USER" "$SITE_PACKAGES/gopanel/"
find "$SITE_PACKAGES/gopanel" -name "*.pyc" -delete
find "$SITE_PACKAGES/gopanel" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
ok "Source synced"

mkdir -p "$APP_DIR/cache" "$APP_DIR/config" "$APP_DIR/data"
chown -R "$APP_USER:$APP_USER" "$APP_DIR/cache" "$APP_DIR/config" "$APP_DIR/data"
rm -f /etc/logrotate.d/gopanel

# FIX #6: start-tmux.sh — надёжная передача exit code через wait
write_file "$APP_DIR/start-tmux.sh" 0755 <<'SH'
#!/bin/bash
# FIX #6: сохраняем рабочую логику оригинала (-d detached + цикл ожидания).
# Улучшение: exit code пишется через явный $? сразу после TUI, переменная
# уникальна по PID чтобы исключить коллизии при параллельных запусках.
SOCKET="/opt/gopanel/tmux.sock"
EXIT_CODE_FILE="/tmp/gopanel-exit-$$"
rm -f "$EXIT_CODE_FILE"

cleanup() {
    tmux -S "$SOCKET" kill-session -t gopanel 2>/dev/null || true
}
trap cleanup EXIT

tmux -S "$SOCKET" kill-session -t gopanel 2>/dev/null || true
tmux -S "$SOCKET" new-session -d -s gopanel \
    "bash -c '/opt/gopanel/venv/bin/gopanel-tui; echo \$? > ${EXIT_CODE_FILE}'"

while tmux -S "$SOCKET" has-session -t gopanel 2>/dev/null; do
    sleep 2
done

if [ -f "$EXIT_CODE_FILE" ]; then
    code=$(cat "$EXIT_CODE_FILE")
    rm -f "$EXIT_CODE_FILE"
    exit "${code:-1}"
fi
exit 1
SH

# FIX #1: gopanel-systemctl — retry при race condition чтения services.json
write_file /usr/local/bin/gopanel-systemctl 0755 <<'SH'
#!/usr/bin/env python3
import sys
import json
import re
import os
import time

UNIT_RE = re.compile(r"^[A-Za-z0-9_@][A-Za-z0-9_.@\-]{0,253}\.service$")
ALLOWED_ACTIONS = {"status", "is-active", "show", "start", "stop", "restart", "list-unit-files"}

if not os.path.exists("/usr/bin/systemctl"):
    print("Error: /usr/bin/systemctl not found", file=sys.stderr)
    sys.exit(1)

args = sys.argv[1:]
if len(args) < 2:
    sys.exit(1)

action = args[0]
if action not in ALLOWED_ACTIONS:
    print(f"Blocked action: {action}", file=sys.stderr)
    sys.exit(1)

units = [a for a in args[1:] if a.endswith(".service")]
reg_file = "/etc/gopanel/services.json"

# FIX #1: retry при race condition — atomic_write делает rename,
# в момент которого файл может временно отсутствовать
allowed_units = set()
last_err = None
for attempt in range(3):
    try:
        with open(reg_file) as f:
            reg = json.load(f)
        allowed_units = {s["unit"] for s in reg.get("services", [])}
        last_err = None
        break
    except (FileNotFoundError, json.JSONDecodeError) as e:
        last_err = e
        if attempt < 2:
            time.sleep(0.05)
if last_err is not None:
    print(f"Error reading registry: {last_err}", file=sys.stderr)
    sys.exit(1)

if os.geteuid() != 0:
    print("Error: This wrapper must be run as root (via sudo).", file=sys.stderr)
    sys.exit(1)

if not units and action not in {"list-unit-files"}:
    print("Error: Service command requires at least one unit.", file=sys.stderr)
    sys.exit(1)

for u in units:
    if not UNIT_RE.match(u) or u not in allowed_units:
        print(f"Blocked unit: {u}", file=sys.stderr)
        sys.exit(1)

os.execv("/usr/bin/systemctl", ["systemctl"] + args)
SH

# FIX #2: gopanel-journalctl — whitelist разрешённых флагов
write_file /usr/local/bin/gopanel-journalctl 0755 <<'SH'
#!/usr/bin/env python3
import sys
import json
import re
import os
import time

UNIT_RE = re.compile(r"^[A-Za-z0-9_@][A-Za-z0-9_.@\-]{0,253}\.service$")
REG_FILE = "/etc/gopanel/services.json"

# FIX #2: явный whitelist разрешённых флагов — блокирует --user-unit,
# --namespace, match-параметры и другие потенциально опасные опции
ALLOWED_FLAGS = {
    "-u", "--unit",
    "-n", "--lines",
    "-f", "--follow",
    "--no-pager",
    "-o", "--output",
    "-r", "--reverse",
    "--since", "--until",
    "-p", "--priority",
    "-x", "--catalog",
    "-q", "--quiet",
}

if not os.path.exists("/usr/bin/stdbuf"):
    print("Error: /usr/bin/stdbuf not found", file=sys.stderr)
    sys.exit(1)

if not os.path.exists("/usr/bin/journalctl"):
    print("Error: /usr/bin/journalctl not found", file=sys.stderr)
    sys.exit(1)

# FIX #1 (аналогично): retry при race condition
allowed_units = set()
last_err = None
for attempt in range(3):
    try:
        with open(REG_FILE) as f:
            reg = json.load(f)
        allowed_units = {s["unit"] for s in reg.get("services", [])}
        last_err = None
        break
    except (FileNotFoundError, json.JSONDecodeError) as e:
        last_err = e
        if attempt < 2:
            time.sleep(0.05)
if last_err is not None:
    print(f"Error reading registry: {last_err}", file=sys.stderr)
    sys.exit(1)

if os.geteuid() != 0:
    print("Error: This wrapper must be run as root (via sudo).", file=sys.stderr)
    sys.exit(1)

args = sys.argv[1:]
has_u = False
i = 0
while i < len(args):
    arg = args[i]
    # Проверяем флаг на соответствие whitelist
    flag = arg.split("=")[0] if "=" in arg else arg
    if flag not in ALLOWED_FLAGS and arg.startswith("-"):
        print(f"Blocked flag: {arg}", file=sys.stderr)
        sys.exit(1)

    if arg in ("-u", "--unit"):
        if i + 1 < len(args):
            u = args[i + 1]
            if not UNIT_RE.match(u) or u not in allowed_units:
                sys.exit(1)
            has_u = True
            i += 2
            continue
    elif arg.startswith("--unit="):
        u = arg.split("=", 1)[1]
        if not UNIT_RE.match(u) or u not in allowed_units:
            sys.exit(1)
        has_u = True
        i += 1
        continue
    i += 1

if not has_u:
    sys.exit(1)

os.execv("/usr/bin/stdbuf", ["stdbuf", "-oL", "/usr/bin/journalctl"] + args)
SH

write_file /etc/sudoers.d/gopanel 0440 <<'SUDOERS'
# GoPanel sudoers — Cmnd_Alias с явным * для аргументов.
# Wrapper-скрипты сами валидируют аргументы (whitelist юнитов,
# whitelist действий, whitelist флагов). Cmnd_Alias здесь улучшает
# читаемость и явно документирует разрешённые точки входа.
# Убрать * нельзя: sudo без * блокирует любой вызов с аргументами,
# что полностью сломает show/start/stop/restart/journalctl.
Cmnd_Alias GOPANEL_SYSTEMCTL  = /usr/local/bin/gopanel-systemctl *
Cmnd_Alias GOPANEL_JOURNALCTL = /usr/local/bin/gopanel-journalctl *
monitor ALL=(root) NOPASSWD: GOPANEL_SYSTEMCTL, GOPANEL_JOURNALCTL
SUDOERS
visudo -cf /etc/sudoers.d/gopanel >/dev/null || { err "Invalid sudoers"; exit 1; }

write_file /etc/systemd/system/gopanel.service 0644 <<'SYSTEMD'
[Unit]
Description=GoPanel Monitoring TUI
After=network.target

[Service]
Type=simple
User=monitor
WorkingDirectory=/opt/gopanel
Environment=TERM=xterm-256color
Environment=HOME=/home/monitor
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
Environment=XDG_CACHE_HOME=/opt/gopanel/cache
Environment=XDG_CONFIG_HOME=/opt/gopanel/config
Environment=XDG_DATA_HOME=/opt/gopanel/data
Environment=TEXTUAL_CONFIG_DIR=/opt/gopanel/config/textual
ExecStart=/opt/gopanel/start-tmux.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
TimeoutStopSec=30
KillMode=control-group
MemoryMax=512M
TasksMax=256

PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/etc/gopanel /var/log/gopanel /opt/gopanel
ProtectHome=yes
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
SYSTEMD
systemctl daemon-reload
systemctl enable gopanel.service
systemctl start gopanel.service
sleep 3

info "Verifying installation..."
if ! sudo -u "$APP_USER" "$APP_DIR/venv/bin/python" -c "import gopanel; assert gopanel.__version__ == '$VERSION'" 2>/dev/null; then
    err "Verification failed. Rolling back..."
    systemctl stop gopanel.service 2>/dev/null || true
    if [[ -d "$BACKUP_DIR" ]]; then
        rm -rf "$APP_DIR" && mv "$BACKUP_DIR" "$APP_DIR"
        chown -R "$APP_USER:$APP_USER" "$APP_DIR"
        systemctl start gopanel.service 2>/dev/null || true
        ok "Rolled back"
    else
        err "No backup found."
        exit 1
    fi
fi
ok "Installation verified successfully"

if [[ -d "$BACKUP_DIR" ]]; then
    rm -rf "$BACKUP_DIR"
    ok "Backup cleaned"
fi

if systemctl is-active --quiet gopanel.service; then
    if sudo -u "$APP_USER" tmux -S "$TMUX_SOCKET" has-session -t gopanel 2>/dev/null; then
        ok "gopanel.service запущен успешно"
    else
        err "gopanel.service запущен, но tmux сессия не найдена"
    fi
else
    err "gopanel.service не запустился"
fi

# FIX #9: gopanel-attach — используем attach-session вместо new-session -A
# new-session -A при наличии сессии создавал второй экземпляр gopanel-tui
write_file /usr/local/bin/gopanel-attach 0755 <<'SH'
#!/usr/bin/env bash
SOCKET="/opt/gopanel/tmux.sock"
SESSION="gopanel"

# Определяем команду systemctl (с sudo или без)
if [[ $EUID -eq 0 ]]; then
    SYSTEMCTL_CMD="systemctl"
else
    SYSTEMCTL_CMD="sudo systemctl"
fi

# Запускаем сервис если не активен
if ! $SYSTEMCTL_CMD is-active --quiet gopanel.service 2>/dev/null; then
    echo "Запуск сервиса gopanel.service..."
    $SYSTEMCTL_CMD start gopanel.service
    # Ждём создания tmux-сессии (до 5 секунд)
    for i in {1..10}; do
        if sudo -u monitor tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
fi

# FIX #9: attach к уже существующей сессии — не создаём новый процесс gopanel-tui
if sudo -u monitor tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    exec sudo -u monitor tmux -S "$SOCKET" attach-session -t "$SESSION"
else
    echo "Ошибка: tmux-сессия '$SESSION' не найдена после запуска сервиса." >&2
    echo "Проверьте статус: systemctl status gopanel.service" >&2
    exit 1
fi
SH

write_file /usr/local/bin/gopanel 0755 <<'SH'
#!/usr/bin/env bash
exec sudo -u monitor /opt/gopanel/venv/bin/gopanel "$@"
SH

write_file /usr/local/bin/gopanel-uninstall 0755 <<'SH'
#!/usr/bin/env bash
set -eu
[[ $EUID -eq 0 ]] || { echo "Use sudo"; exit 1; }
read -p "Удалить GoPanel? [y/N] " c
[[ "$c" == "y" ]] || exit 0

systemctl stop gopanel.service 2>/dev/null || true
systemctl disable gopanel.service 2>/dev/null || true
tmux -S /opt/gopanel/tmux.sock kill-server 2>/dev/null || true
sleep 1

rm -f /etc/sudoers.d/gopanel
rm -f /usr/local/bin/gopanel
rm -f /usr/local/bin/gopanel-attach
rm -f /usr/local/bin/gopanel-uninstall
rm -f /usr/local/bin/gopanel-systemctl
rm -f /usr/local/bin/gopanel-journalctl
rm -f /etc/systemd/system/gopanel.service
rm -rf /opt/gopanel
userdel -r monitor 2>/dev/null || true

echo "Готово (конфиг в /etc/gopanel и логи в /var/log/gopanel сохранены)"
SH

chown -R "$APP_USER":"$APP_USER" "$APP_DIR" "$LOG_DIR" "$CONF_DIR"

cat <<BANNER

╔════════════════════════════════════════════════════════════════╗
║   🎛  Service Monitoring and Management Center  v1.0.63        ║
╠════════════════════════════════════════════════════════════════╣
║  ✓ Колонка CPU в таблице мониторинга                           ║
║  ✓ Уведомления о восстановлении сервисов (исправлен throttle)  ║
║  ✓ Панель горячих клавиш и статистики сессии                   ║
║  ✓ AlertsPanel растягивается до InfoPanel                      ║
║  ✓ CPU всегда показывал 0.0% — исправлено кешированием Process ║
║  ✓ Удалён нефункциональный экран метрик (клавиша 3)            ║
║  Автозапуск: включён  |  Подключиться: gopanel-attach          ║
╚════════════════════════════════════════════════════════════════╝

BANNER
