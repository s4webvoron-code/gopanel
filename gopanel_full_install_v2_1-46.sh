#!/usr/bin/env bash
# =====================================================================
# GoPanel Full Installer v2.1 + Telegram Bot v2.1
# Объединённый установщик: панель и бот за один запуск
# =====================================================================
set -Eeuo pipefail
umask 0022
_cleanup_fresh_install() {
    echo "⟳ Очистка после неудачной первичной установки..." >&2
    systemctl stop gopanel.service gopanel-bot.service 2>/dev/null || true
    systemctl disable gopanel.service gopanel-bot.service 2>/dev/null || true
    rm -f /etc/systemd/system/gopanel.service /etc/systemd/system/gopanel-bot.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f /etc/sudoers.d/gopanel /etc/sudoers.d/gopanel-bot
    rm -f /usr/local/bin/gopanel-systemctl /usr/local/bin/gopanel-journalctl
    rm -f /usr/local/bin/gopanel-save-bot-config /usr/local/bin/gopanel-db /usr/local/bin/gopanel-docker /usr/local/bin/gopanel-screenshot /usr/local/bin/gopanel-restart-bot
    rm -f /usr/local/bin/gopanel /usr/local/bin/gopanel-attach /usr/local/bin/gopanel-uninstall
    rm -f /etc/logrotate.d/gopanel
    rm -rf "${APP_DIR:-/opt/gopanel}"
    rm -rf "${CONF_DIR:-/etc/gopanel}"
    # [ИСПРАВЛЕНО v2.1-18] раньше пользователь удалялся безусловно при любой
    # ошибке "первичной" установки — а "первичность" определяется только по
    # отсутствию venv, что не учитывает случай, когда monitor уже существовал
    # до GoPanel (создан другим сервисом). Теперь userdel только если ЭТОТ
    # запуск установщика сам создал пользователя (см. USER_CREATED_BY_INSTALLER).
    if [[ "${USER_CREATED_BY_INSTALLER:-false}" == "true" ]]; then
        getent passwd "${APP_USER:-monitor}" >/dev/null 2>&1 && userdel -r "${APP_USER:-monitor}" 2>/dev/null || true
    fi
    # [ИСПРАВЛЕНО v2.1-18] LOG_DIR ранее не удалялся при откате первичной
    # установки, оставляя логи на диске.
    rm -rf "${LOG_DIR:-/var/log/gopanel}"
    echo "✓ Система очищена — повторный запуск установщика безопасен" >&2
}

_install_failed() {
    # [ИСПРАВЛЕНО v2.1-20] снимаем все три trap'а первой же строкой — без этого
    # сбой самой процедуры отката (rsync/mv/chown без `|| true`) под set -e
    # повторно активирует ERR-trap и вызовет _install_failed рекурсивно;
    # аналогично повторный INT/TERM во время отката не должен запускать его ещё раз.
    trap - ERR INT TERM
    echo "❌ Install failed at line $LINENO" >&2
    # [ИСПРАВЛЕНО v2.1-21] раньше готовность бэкапа определялась только по
    # существованию каталога — $BACKUP_DIR/app создаётся через mkdir ДО rsync,
    # то есть каталог существует уже в первую секунду. SIGINT (новое поведение
    # v2.1-20: INT/TERM тоже ведут в _install_failed) во время самого rsync
    # означал бы откат на ЧАСТИЧНЫЙ снимок — рабочая APP_DIR стиралась бы и
    # заменялась неполной копией. Теперь откат разрешён только если бэкап
    # реально завершился (BACKUP_COMPLETE=true, выставляется после успешного
    # rsync/cp обоих разделов бэкапа).
    if [[ -n "${BACKUP_DIR:-}" && -d "${BACKUP_DIR}" && "${BACKUP_COMPLETE:-false}" == "true" ]]; then
        # Обновление: откатываемся к рабочей версии
        echo "⟳ Автоматический откат из $BACKUP_DIR ..." >&2
        systemctl stop gopanel.service gopanel-bot.service 2>/dev/null || true
        rm -rf "$APP_DIR"
        mv "$BACKUP_DIR/app" "$APP_DIR"
        chown -R "${APP_USER:-monitor}:${APP_USER:-monitor}" "$APP_DIR"
        rsync -a --delete "$BACKUP_DIR/conf/" "/etc/gopanel/" 2>/dev/null || true
        [[ -f "/etc/gopanel/bot.json" ]] && chown root:monitor "/etc/gopanel/bot.json" && chmod 0640 "/etc/gopanel/bot.json" || true
        # [ИСПРАВЛЕНО v2.1-18] раньше откат восстанавливал только src/venv и
        # /etc/gopanel, оставляя НОВЫЕ sudoers/wrapper'ы/systemd unit'ы/
        # logrotate на месте — смешанное состояние "старый код + новое
        # системное окружение". Теперь эти файлы тоже входят в бэкап/откат.
        if [[ -d "$BACKUP_DIR/sys" ]]; then
            # ВАЖНО: копируем точечно (не rsync --delete всей /usr/local/bin/)
            # — там могут быть посторонние бинарники, не связанные с GoPanel.
            cp -f "$BACKUP_DIR/sys/bin/"gopanel* /usr/local/bin/ 2>/dev/null || true
            # [ИСПРАВЛЕНО v2.1-27] удаляем wrapper'ы, которых не было в манифесте —
            # т.е. появившиеся именно в ходе этого (неудачного) апгрейда.
            # Точечно по конкретным путям, не rsync --delete всей директории.
            if [[ -f "$BACKUP_DIR/sys/bin_manifest.txt" ]]; then
                for f in /usr/local/bin/gopanel*; do
                    [[ -e "$f" ]] || continue
                    grep -qxF "$f" "$BACKUP_DIR/sys/bin_manifest.txt" || rm -f "$f"
                done
            fi
            [[ -f "$BACKUP_DIR/sys/sudoers.d/gopanel" ]] && cp -f "$BACKUP_DIR/sys/sudoers.d/gopanel" /etc/sudoers.d/gopanel && chmod 0440 /etc/sudoers.d/gopanel
            [[ -f "$BACKUP_DIR/sys/systemd/gopanel.service" ]] && cp -f "$BACKUP_DIR/sys/systemd/gopanel.service" /etc/systemd/system/gopanel.service
            [[ -f "$BACKUP_DIR/sys/systemd/gopanel-bot.service" ]] && cp -f "$BACKUP_DIR/sys/systemd/gopanel-bot.service" /etc/systemd/system/gopanel-bot.service
            [[ -f "$BACKUP_DIR/sys/logrotate.d/gopanel" ]] && cp -f "$BACKUP_DIR/sys/logrotate.d/gopanel" /etc/logrotate.d/gopanel
        fi
        rm -rf "$BACKUP_DIR"
        systemctl daemon-reload 2>/dev/null || true
        systemctl start gopanel.service gopanel-bot.service 2>/dev/null || true
        echo "✓ Откат завершён — src/, venv, /etc/gopanel и системные wrapper'ы восстановлены" >&2
    elif [[ "${IS_FRESH_INSTALL:-false}" == "true" ]]; then
        # Первичная установка: удаляем всё что успели создать
        _cleanup_fresh_install
    fi
    exit 1
}
trap '_install_failed' ERR
# [ИСПРАВЛЕНО v2.1-20] раньше Ctrl+C/SIGTERM посреди установки не откатывали
# ничего (default-обработка сигнала просто убивала процесс) — система
# оставалась в смешанном состоянии (часть новых файлов, часть старых, venv
# частично пересоздан). Теперь INT/TERM запускают тот же откат, что и ERR.
trap '_install_failed' INT TERM
[[ $EUID -eq 0 ]] || { echo "❌ Run as root"; exit 1; }

command -v systemctl >/dev/null 2>&1 || { echo "❌ systemd is required"; exit 1; }

info() { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }  # BUGFIX: warn не была определена — с set -Eeuo pipefail вызов убивал установщик через trap ERR

APP_USER="monitor"
APP_DIR="/opt/gopanel"
CONF_DIR="/etc/gopanel"
LOG_DIR="/var/log/gopanel"
TMUX_SOCKET="$APP_DIR/tmux.sock"

# ======================== СИСТЕМНЫЕ ПРОВЕРКИ ========================

PY="$(command -v python3)"
[[ -x "$PY" ]] || { err "python3 not found"; exit 1; }

if ! "$PY" -c 'import sys; assert sys.version_info >= (3,12)' 2>/dev/null; then
    err "Python 3.12 or newer is required"; exit 1
fi

if ! locale -a 2>/dev/null | grep -qi 'utf-8\|utf8'; then
    err "UTF-8 locale is required for proper UI rendering"; exit 1
fi

# ======================== ИНТЕРАКТИВНЫЙ ВВОД (бот) ========================
# Защита от curl|bash: при запуске через pipe stdin занят телом скрипта.
# Все read явно используют /dev/tty — гарантирует ввод с клавиатуры.
if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
    err "Нет доступа к терминалу. Запустите скрипт напрямую: sudo bash gopanel_full_install.sh"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Настройка GoPanel + Telegram-бота"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Читаем существующий конфиг бота (если есть — предлагаем сохранить текущие значения)
_existing_token=""
_existing_users=""
_existing_alerts="true"
if [[ -f "/etc/gopanel/bot.json" ]]; then
    _existing_token=$(python3 -c "import json; d=json.load(open('/etc/gopanel/bot.json')); print(d.get('telegram_token',''))" 2>/dev/null || true)
    _existing_users=$(python3 -c "import json; d=json.load(open('/etc/gopanel/bot.json')); print(','.join(str(u) for u in d.get('authorized_users',[])))" 2>/dev/null || true)
    _existing_alerts=$(python3 -c "import json; d=json.load(open('/etc/gopanel/bot.json')); print('true' if d.get('enable_alerts',True) else 'false')" 2>/dev/null || true)
fi

if [[ -n "$_existing_token" && -n "$_existing_users" ]]; then
    echo ""
    echo "  ℹ  Обнаружен существующий конфиг /etc/gopanel/bot.json"
    echo "     Токен:        ${_existing_token:0:12}... (скрыт)"
    echo "     Пользователи: $_existing_users"
    echo "     Уведомления:  $_existing_alerts"
    echo ""
    read -p "  Оставить текущие настройки без изменений? [Y/n]: " _keep_cfg </dev/tty
    _keep_cfg=${_keep_cfg:-Y}
    if [[ "$_keep_cfg" =~ ^[Yy]$ ]]; then
        telegram_token="$_existing_token"
        IFS=',' read -ra valid_ids <<< "$_existing_users"
        # Защита: все ID должны быть цифрами и массив не пуст
        _ids_ok=true
        if [[ ${#valid_ids[@]} -eq 0 ]]; then _ids_ok=false; fi
        for _id in "${valid_ids[@]}"; do
            if [[ ! "$_id" =~ ^[0-9]+$ ]]; then _ids_ok=false; break; fi
        done
        if [[ "$_ids_ok" == "true" ]]; then
            authorized_users_json="["
            for i in "${!valid_ids[@]}"; do
                authorized_users_json+="${valid_ids[$i]}"
                if [[ $i -lt $((${#valid_ids[@]} - 1)) ]]; then
                    authorized_users_json+=","
                fi
            done
            authorized_users_json+="]"
            enable_alerts="$_existing_alerts"
            ok "Текущие настройки бота сохранены"
            echo ""
            info "Параметры приняты — начинаю установку..."
            echo ""
        else
            err "Существующий конфиг содержит некорректные ID — требуется повторный ввод"
            echo ""
            _do_input=true
        fi
    else
        echo ""
        echo "  Введите новые настройки:"
        echo ""
        _do_input=true
    fi
elif [[ -f "/etc/gopanel/bot.json" ]]; then
    # Файл есть, но токен или users пустые — конфиг повреждён или неполон
    err "Существующий /etc/gopanel/bot.json повреждён или неполон — требуется повторный ввод"
    echo ""
    _do_input=true
else
    echo ""
    echo "Для работы бота необходимо:"
    echo "  1. Создать бота через @BotFather в Telegram"
    echo "  2. Узнать свой Telegram ID через @userinfobot"
    echo ""
    _do_input=true
fi

if [[ "${_do_input:-false}" == "true" ]]; then
    while true; do
        read -p "Введите токен бота (от @BotFather): " telegram_token </dev/tty
        if [[ -z "$telegram_token" ]]; then
            err "Токен не может быть пустым"
            continue
        fi
        if [[ ! "$telegram_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            err "Неверный формат токена. Пример: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
            continue
        fi
        break
    done
    ok "Токен принят"

    echo ""
    echo "Введите Telegram ID авторизованных пользователей"
    echo "(можно ввести несколько ID через запятую, например: 123456789,987654321)"
    echo ""

    while true; do
        read -p "Telegram ID: " user_ids_str </dev/tty
        if [[ -z "$user_ids_str" ]]; then
            err "ID не могут быть пустыми"
            continue
        fi

        IFS=',' read -ra user_ids_array <<< "$user_ids_str"
        valid_ids=()
        all_valid=true

        for id in "${user_ids_array[@]}"; do
            id=$(echo "$id" | tr -d ' ')
            if [[ ! "$id" =~ ^[0-9]+$ ]]; then
                err "Неверный формат ID: $id (должно быть число)"
                all_valid=false
                break
            fi
            valid_ids+=("$id")
        done

        if [[ "$all_valid" == true ]]; then
            break
        fi
    done

    authorized_users_json="["
    for i in "${!valid_ids[@]}"; do
        authorized_users_json+="${valid_ids[$i]}"
        if [[ $i -lt $((${#valid_ids[@]} - 1)) ]]; then
            authorized_users_json+=","
        fi
    done
    authorized_users_json+="]"

    ok "ID приняты: ${valid_ids[*]}"

    echo ""
    read -p "Включить уведомления о падениях сервисов? [Y/n]: " enable_alerts_input </dev/tty
    enable_alerts_input=${enable_alerts_input:-Y}

    if [[ "$enable_alerts_input" =~ ^[Yy]$ ]]; then
        enable_alerts="true"
        ok "Уведомления включены"
    else
        enable_alerts="false"
        ok "Уведомления отключены"
    fi

    echo ""
    info "Параметры приняты — начинаю установку..."
    echo ""
fi

# FIX M-1: убран дублирующий безусловный вызов info "Параметры приняты..."
# Это сообщение уже выводится внутри if-блока выше (строка 225) при
# интерактивном вводе (_do_input=true). Безусловная версия здесь:
# 1) дублировала вывод при _do_input=true (два одинаковых сообщения подряд);
# 2) некорректно печатала "Параметры приняты" при пути без интерактивного ввода,
#    где параметры не вводились вовсе.

# ======================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ========================

write_file() {
    local path="$1"
    local mode="${2:-0644}"
    mkdir -p "$(dirname "$path")" || { err "Failed to create dir for $path"; return 1; }
    cat > "$path" || { err "Failed to write $path"; return 1; }
    chmod "$mode" "$path" || { err "Failed to chmod $path"; return 1; }
}

# ======================== СИСТЕМНЫЕ ПАКЕТЫ ========================

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
    python3 python3-venv python3-pip tmux sudo ca-certificates rsync procps coreutils \
    python3-pil fonts-dejavu-core curl >/dev/null 2>&1
# [ИСПРАВЛЕНО v2.1-18] curl используется дальше (проверка Telegram API), но
# не был в списке зависимостей — на минимальном образе без curl проверка
# токена молча проваливалась с вводящим в заблуждение предупреждением.

command -v tmux >/dev/null 2>&1 || { err "tmux not found after install"; exit 1; }
ok "System packages & tmux verified"

# ======================== ПОЛЬЗОВАТЕЛЬ И ДИРЕКТОРИИ ========================

if getent passwd "$APP_USER" >/dev/null 2>&1; then
    ok "Пользователь $APP_USER уже существует"
else
    info "Создание пользователя $APP_USER"
    useradd -r -m -s /usr/bin/bash "$APP_USER" || { err "Не удалось создать пользователя $APP_USER"; exit 1; }
    # [ИСПРАВЛЕНО v2.1-18] флаг для _cleanup_fresh_install — userdel допустим
    # только для пользователя, реально созданного этим запуском установщика.
    USER_CREATED_BY_INSTALLER=true
    ok "Пользователь $APP_USER создан"
fi

# [ИСПРАВЛЕНО v2.1-30] группа gopanel-view (v2.1-27) удалена целиком: attach-
# session к tmux даёт полный интерактивный клиент с командным режимом
# (Ctrl-B :), а `run-shell` там выполняется сервером tmux, уже работающим от
# monitor, — без единого дополнительного вызова sudo. Подтверждено реальным
# эксплойтом (pty + run-shell "id") — оператор из "view-only" группы получал
# полный код-execution от monitor. "Just view the panel" через sudo -u monitor
# tmux attach в принципе не может быть безопасным — sudoers не может
# разрешить attach, не разрешив тем самым интерактивный tmux целиком.

# [ИСПРАВЛЕНО v2.1-18] CONF_DIR раньше создавался monitor:monitor 0750 —
# владелец каталога мог удалить/подменить bot.json и gopanel.db в обход
# root-wrapper'ов (gopanel-db/gopanel-save-bot-config), даже если сами файлы
# защищены как root:monitor 0640. Теперь каталог root:monitor 0750 — monitor
# имеет только чтение+traverse (group r-x), запись только через wrapper'ы.
install -d -o root -g "$APP_USER" -m 0750 "$CONF_DIR"
install -d -o "$APP_USER" -g "$APP_USER" -m 0750 "$APP_DIR" "$LOG_DIR"
# 3.4: директория для экспорта логов из TUI (кнопка "💾 Экспорт" в экране логов)
install -d -o "$APP_USER" -g "$APP_USER" -m 0755 "$LOG_DIR/exports"
mkdir -p \
    "$APP_DIR/src/gopanel/ui/screens" \
    "$APP_DIR/src/gopanel/ui/widgets" \
    "$APP_DIR/src/gopanel/bot/handlers"
chown -R "$APP_USER:$APP_USER" "$APP_DIR/src"
chmod -R 0750 "$APP_DIR/src"

# ======================== РЕЗЕРВНАЯ КОПИЯ ========================
# Backup берётся ДО записи новых исходников — содержит рабочий src/+venv.
# При любой ошибке trap '_install_failed' восстановит эту копию.

BACKUP_DIR="/tmp/gopanel-backup.$$"
# [ИСПРАВЛЕНО v2.1-19] раньше "первичная установка" определялась только по
# отсутствию venv. Если venv отсутствовал (удалён вручную, сбойный апгрейд),
# а /etc/gopanel/gopanel.db или bot.json с реальными данными оставались,
# ветка "else" ниже считала это fresh install и НЕ создавала для них бэкап —
# при следующей ошибке _cleanup_fresh_install удалял их безвозвратно.
# [ИСПРАВЛЕНО v2.1-31] добавлен services.json (данные v2.0 до миграции на
# SQLite) — без него та же потеря данных возможна ещё до появления gopanel.db:
# venv отсутствует + gopanel.db/bot.json ещё нет + services.json есть → fresh
# install без бэкапа → сбой миграции (sys.exit(1)) → _cleanup_fresh_install
# удаляет /etc/gopanel вместе с services.json.
if [[ -d "$APP_DIR/venv" ]] || [[ -f "$CONF_DIR/gopanel.db" ]] || [[ -f "$CONF_DIR/bot.json" ]] || [[ -f "$CONF_DIR/services.json" ]]; then
    IS_FRESH_INSTALL=false
    mkdir -p "$BACKUP_DIR/app" "$BACKUP_DIR/conf"
    info "Creating backup to $BACKUP_DIR"
    rsync -a "$APP_DIR/"   "$BACKUP_DIR/app/"  >/dev/null || { err "Backup of APP_DIR failed";  exit 1; }
    rsync -a "$CONF_DIR/"  "$BACKUP_DIR/conf/" >/dev/null || { err "Backup of CONF_DIR failed"; exit 1; }
    # [ИСПРАВЛЕНО v2.1-34] rsync выше копирует gopanel.db голым файловым
    # копированием, пока gopanel.service/gopanel-bot.service ещё могут в неё
    # писать — снимок не гарантированно консистентен (SQLite официально не
    # считает это безопасным без своего backup API). Перезаписываем именно
    # gopanel.db в бэкапе через sqlite3.Connection.backup() (Online Backup
    # API) — он безопасен при открытых читателях/писателях на исходной БД.
    if [[ -f "$CONF_DIR/gopanel.db" ]]; then
        python3 -c "
import sqlite3
src = sqlite3.connect('$CONF_DIR/gopanel.db')
dst = sqlite3.connect('$BACKUP_DIR/conf/gopanel.db')
src.backup(dst)
dst.close()
src.close()
" || { err "Consistent backup of gopanel.db failed"; exit 1; }
    fi
    # [ИСПРАВЛЕНО v2.1-18] бэкап раньше не включал sudoers/wrapper'ы/systemd
    # unit'ы/logrotate — при откате они оставались уже новыми, откат не был
    # атомарным для всего системного слоя. Копируем то, что уже есть от
    # предыдущей установки (апгрейд — этот блок выполняется только когда
    # $APP_DIR/venv уже существует, т.е. эти файлы уже на диске).
    mkdir -p "$BACKUP_DIR/sys/bin" "$BACKUP_DIR/sys/sudoers.d" "$BACKUP_DIR/sys/systemd" "$BACKUP_DIR/sys/logrotate.d"
    cp -a /usr/local/bin/gopanel* "$BACKUP_DIR/sys/bin/" 2>/dev/null || true
    # [ИСПРАВЛЕНО v2.1-27] манифест wrapper'ов, существовавших ДО этого апгрейда —
    # без него откат восстанавливает старые файлы, но не удаляет новые,
    # которых не было (например, если апгрейд добавил новый wrapper).
    ls -1 /usr/local/bin/gopanel* 2>/dev/null > "$BACKUP_DIR/sys/bin_manifest.txt" || true
    [[ -f /etc/sudoers.d/gopanel ]] && cp -a /etc/sudoers.d/gopanel "$BACKUP_DIR/sys/sudoers.d/gopanel"
    [[ -f /etc/systemd/system/gopanel.service ]] && cp -a /etc/systemd/system/gopanel.service "$BACKUP_DIR/sys/systemd/gopanel.service"
    [[ -f /etc/systemd/system/gopanel-bot.service ]] && cp -a /etc/systemd/system/gopanel-bot.service "$BACKUP_DIR/sys/systemd/gopanel-bot.service"
    [[ -f /etc/logrotate.d/gopanel ]] && cp -a /etc/logrotate.d/gopanel "$BACKUP_DIR/sys/logrotate.d/gopanel"
    # [ИСПРАВЛЕНО v2.1-21] выставляется только здесь — после того, как оба
    # обязательных rsync (app/conf) и точечные cp системного слоя реально
    # завершились. См. комментарий у проверки этого флага в _install_failed.
    BACKUP_COMPLETE=true
    ok "Backup created (src/ + venv + /etc/gopanel + sudoers/wrappers/systemd сохранены)"
else
    IS_FRESH_INSTALL=true
    info "Первичная установка — при ошибке система будет очищена автоматически"
fi

# ======================== ОСТАНОВКА СТАРЫХ ПРОЦЕССОВ ========================
# Останавливаем сервисы после backup — при откате они будут перезапущены.

for svc in gopanel.service gopanel-bot.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        info "Остановка $svc..."
        systemctl stop "$svc"
        sleep 1
    fi
done

if pgrep -u "$APP_USER" -f gopanel >/dev/null 2>&1; then
    pkill -u "$APP_USER" -f gopanel 2>/dev/null || true
    sleep 1
fi

if sudo -u "$APP_USER" tmux -S "$TMUX_SOCKET" has-session -t gopanel 2>/dev/null; then
    sudo -u "$APP_USER" tmux -S "$TMUX_SOCKET" kill-session -t gopanel 2>/dev/null || true
    sleep 1
fi

# ======================== PYTHON SOURCE — ПАНЕЛЬ ========================

write_file "$APP_DIR/src/gopanel/__init__.py" <<'PY'
__version__ = "2.1"
PY

write_file "$APP_DIR/src/gopanel/config.py" <<'PY'
from __future__ import annotations

import os
from pathlib import Path

from pydantic_settings import BaseSettings
from pydantic import Field


class Settings(BaseSettings):
    # [ФИЧА v2.1-1] заменено config_path (services.json) на db_path (SQLite).
    # Единственное место использования — Registry.__init__ (registry.py),
    # переименование безопасно.
    db_path: Path = Field(
        default_factory=lambda: Path(os.getenv("GOPANEL_DB", "/etc/gopanel/gopanel.db"))
    )
    log_path: Path = Field(
        default_factory=lambda: Path(os.getenv("GOPANEL_LOG", "/var/log/gopanel/gopanel.log"))
    )
    poll_interval: float = Field(default=2.0, ge=0.5, le=60.0)
    use_sudo: bool = True
    sudo_binary: Path = Path("/usr/bin/sudo")
    systemctl: Path = Path("/usr/local/bin/gopanel-systemctl")
    journalctl: Path = Path("/usr/local/bin/gopanel-journalctl")
    docker: Path = Path("/usr/local/bin/gopanel-docker")

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
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,31}$")


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
    except asyncio.CancelledError:
        # [ИСПРАВЛЕНО v2.1-23] раньше при отмене корутины (например, graceful
        # shutdown бота) дочерний процесс не убивался — оставался висеть до
        # естественного завершения или пока не подчистит KillMode systemd.
        # Убиваем его здесь же и обязательно пробрасываем CancelledError дальше.
        if proc:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            try:
                await proc.wait()
            except Exception:
                pass
        raise
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

import asyncio
import hashlib
import json
import logging
import sqlite3
import subprocess
import threading
import time
import re
from pathlib import Path
from pydantic import BaseModel, Field, field_validator
from .config import settings
from .utils import assert_safe_unit  # FIX DEF-08: atomic_write удалён — не используется в registry.py

log = logging.getLogger("gopanel.registry")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,31}$")
MAX_SERVICES = 1000
# [ФИЧА v2.1-1] SQLite backend вместо services.json. LOCK_FILE/fcntl удалены:
# раньше запись = перезапись ВСЕГО файла целиком, и внешний advisory-лок
# защищал от гонки двух процессов на один снимок (FIX C-2). Теперь gopanel-db
# делает точечный upsert/delete ОДНОЙ строки внутри SQLite-транзакции —
# согласованность между процессами обеспечивает сама СУБД (busy_timeout
# внутри gopanel-db), внешний файловый лок для этого больше не нужен.
DB_WRAPPER = "/usr/local/bin/gopanel-db"


class ServiceEntry(BaseModel):
    name: str = Field(min_length=1, max_length=32)
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


class DockerEntry(BaseModel):
    # [ФИЧА v2.1-4] модель Docker-контейнера — та же структура полей, что
    # ServiceEntry, но unit -> image и без manual_restarts (нет аналога
    # systemd-рестартов, которые TUI/бот сами инкрементируют)
    name: str = Field(min_length=1, max_length=32)
    image: str = Field(min_length=1, max_length=255)
    group: str = Field(default="default", max_length=32)
    description: str = Field(default="", max_length=256)
    critical: bool = False
    tags: list[str] = Field(default_factory=list)

    @field_validator('name')
    @classmethod
    def validate_name(cls, v):
        if not NAME_RE.match(v):
            raise ValueError(f"Invalid container name: {v!r}")
        return v


class Registry:
    def __init__(self, db_path: Path | None = None):
        # [ФИЧА v2.1-1] path -> db_path (SQLite вместо services.json)
        self.db_path = db_path or settings.db_path
        self._lock = threading.RLock()
        self._services: dict[str, ServiceEntry] = {}
        self._containers: dict[str, DockerEntry] = {}  # [ФИЧА v2.1-4]
        # FIX C-2: лок для сериализации порядка flush на диск (см. _flush_async).
        # Создаём лениво (None здесь) и инициализируем asyncio.Lock() при первом
        # вызове _flush_async — Registry() может быть создан через get_registry()
        # вне работающего event loop (например, синхронный CLI-путь до того как
        # asyncio.run() стартовал), а asyncio.Lock() привязывается к текущему
        # running loop в момент первого await на нём в Python 3.10+. Создание
        # здесь в __init__ было бы безопасным в 3.10+, но ленивая инициализация
        # исключает любую зависимость от того, есть ли running loop на момент
        # конструирования Registry.
        self._flush_order_lock: asyncio.Lock | None = None
        self.reload()

    def reload(self) -> bool:
        with self._lock:
            if not self.db_path.exists():
                log.warning("Registry DB %s not found, keeping current data", self.db_path)
                return False
            try:
                # [ФИЧА v2.1-1] прямое чтение SQLite (аналогично прежнему
                # path.read_text() для JSON) — на запись нужен root через
                # gopanel-db, на чтение достаточно group-прав monitor (0640)
                conn = sqlite3.connect(str(self.db_path), timeout=5)
                try:
                    conn.row_factory = sqlite3.Row
                    rows = conn.execute(
                        "SELECT name, unit, group_name, description, critical, tags, manual_restarts "
                        "FROM services"
                    ).fetchall()
                    # [ИСПРАВЛЕНО v2.1-7] чтение containers изолировано в
                    # собственный try/except — раньше исключение здесь
                    # (например, гонка с параллельным gopanel-db upsert_container,
                    # либо повреждение именно этой таблицы) перехватывалось общим
                    # except ниже ДО присвоения self._services, из-за чего сбой
                    # чтения контейнеров откатывал уже успешно прочитанные
                    # сервисы. Теперь сбой чтения containers не мешает services.
                    try:
                        container_rows = conn.execute(
                            "SELECT name, image, group_name, description, critical, tags FROM containers"
                        ).fetchall()
                    except sqlite3.Error as ce:
                        log.error("Containers read error, keeping old containers state: %s", ce)
                        container_rows = None
                finally:
                    conn.close()
                loaded: dict[str, ServiceEntry] = {}
                for row in rows:
                    try:
                        e = ServiceEntry.model_validate({
                            "name": row["name"],
                            "unit": row["unit"],
                            "group": row["group_name"],
                            "description": row["description"],
                            "critical": bool(row["critical"]),
                            "tags": json.loads(row["tags"] or "[]"),
                            "manual_restarts": row["manual_restarts"],
                        })
                        loaded[e.name] = e
                    except Exception as ex:
                        log.warning("Skip %r: %s", dict(row), ex)
                self._services = loaded
                if container_rows is not None:
                    loaded_containers: dict[str, DockerEntry] = {}
                    for row in container_rows:
                        try:
                            c = DockerEntry.model_validate({
                                "name": row["name"],
                                "image": row["image"],
                                "group": row["group_name"],
                                "description": row["description"],
                                "critical": bool(row["critical"]),
                                "tags": json.loads(row["tags"] or "[]"),
                            })
                            loaded_containers[c.name] = c
                        except Exception as ex:
                            log.warning("Skip container %r: %s", dict(row), ex)
                    self._containers = loaded_containers
                return True
            except sqlite3.Error as e:
                log.error("Registry DB read error, keeping old state: %s", e)
                return False

    @staticmethod
    def _entry_to_db_data(entry: ServiceEntry) -> dict:
        # [ФИЧА v2.1-1] сериализация ServiceEntry в плоский dict для gopanel-db
        return {
            "name": entry.name,
            "unit": entry.unit,
            "group_name": entry.group,
            "description": entry.description,
            "critical": int(entry.critical),
            "tags": json.dumps(entry.tags, ensure_ascii=False),
            "manual_restarts": entry.manual_restarts,
        }

    def _write_command(self, cmd: dict):
        """Синхронно выполняет одну SQL-команду через gopanel-db (sudo).

        [ФИЧА v2.1-1] Замена _write_payload/_flush_locked: раньше сюда
        передавался снимок ВСЕГО реестра (json.dumps со всеми services),
        теперь — точечная команда upsert/delete на одну строку. Место
        вызова (под self._lock, сразу после мутации — см. add/update/delete)
        и обработка ошибок (FIX DEF-06 / v2.7) сохранены без изменений.
        """
        payload = json.dumps(cmd, ensure_ascii=False)
        try:
            proc = subprocess.run(
                ["sudo", "-n", DB_WRAPPER],
                input=payload, text=True, capture_output=True, timeout=5
            )
            if proc.returncode != 0:
                raise OSError(f"gopanel-db failed: {proc.stderr.strip()}")
        except (OSError, subprocess.TimeoutExpired) as e:
            # [ИСПРАВЛЕНО v2.7] сохранено на новом пути записи
            log.error("Failed to flush registry: %s", e)
            raise

    async def _flush_command_async(self, cmd: dict):
        """Асинхронный wrapper — не блокирует event loop.

        FIX C-3 / FIX C-2 сохранены: get_running_loop() (не get_event_loop()),
        self._flush_order_lock гарантирует порядок выполнения команд в том же
        порядке, в котором были вызваны add/update/delete (иначе быстрые
        последовательные изменения одной и той же записи могли бы применяться
        к SQLite не в том порядке).
        """
        loop = asyncio.get_running_loop()
        if self._flush_order_lock is None:
            self._flush_order_lock = asyncio.Lock()
        async with self._flush_order_lock:
            await loop.run_in_executor(None, self._write_command, cmd)

    def list(self) -> tuple[ServiceEntry, ...]:
        with self._lock:
            return tuple(self._services.values())

    def fingerprint(self) -> str:
        # [ИСПРАВЛЕНО v2.1-22] короткий отпечаток текущего состояния реестра
        # (имя+unit каждого сервиса). Встраивается в callback_data кнопок
        # управления вместо голого имени/индекса — если сервис с тем же именем
        # удалили и пересоздали с другим unit (или изменился состав/имена
        # сервисов), отпечаток меняется, и обработчик отклоняет устаревшую
        # кнопку вместо выполнения действия над другой текущей записью.
        # Вычисляется на лету от текущего self._services — не отдельный
        # счётчик, поэтому не "протухает" от простого reload() без изменений.
        with self._lock:
            payload = "|".join(
                f"{e.name}:{e.unit}" for e in sorted(self._services.values(), key=lambda e: e.name)
            )
        # [ИСПРАВЛЕНО v2.1-22, доп. правка] 8 hex-символов + разделители в
        # callback_data вида "confirm_restart:{name}:{fp}" превышали лимит
        # Telegram в 64 байта (см. проверку в бот-коде ниже). 6 hex-символов
        # (16.7M значений) более чем достаточно для детекта изменения реестра —
        # это не криптографическая защита, а маркер "что-то изменилось".
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:6]

    def container_fingerprint(self) -> str:
        # [ИСПРАВЛЕНО v2.1-29] аналог fingerprint() выше, но для Docker-
        # контейнеров (name:image) — docker.py не имел этой защиты: кнопки
        # start/stop/restart адресовались только по имени контейнера, что
        # позволяло старой кнопке подействовать на пересозданный контейнер
        # с тем же именем, но другим image (та же уязвимость, что была у
        # сервисов до v2.1-22).
        with self._lock:
            payload = "|".join(
                f"{c.name}:{c.image}" for c in sorted(self._containers.values(), key=lambda c: c.name)
            )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:6]

    def get(self, name: str) -> ServiceEntry | None:
        with self._lock:
            return self._services.get(name)

    async def add(self, entry: ServiceEntry):
        with self._lock:
            if len(self._services) >= MAX_SERVICES:
                raise ValueError(f"Max services limit ({MAX_SERVICES}) reached")
            if entry.name in self._services:
                raise ValueError(f"{entry.name!r} exists")
            self._services[entry.name] = entry
            # FIX DEF-06 (сохранено, адаптировано под SQLite): команда строится
            # ПОД ЛОКОМ сразу после мутации — состояние entry фиксируется
            # атомарно с мутацией in-memory словаря.
            cmd = {"action": "upsert_service", "data": self._entry_to_db_data(entry)}
        try:
            await self._flush_command_async(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] при ошибке записи в БД (например, UNIQUE
            # по unit) in-memory словарь раньше оставался изменённым — до
            # следующего reload() запись выглядела существующей в TUI/боте,
            # хотя в БД её не было ("фантомный" сервис).
            with self._lock:
                self._services.pop(entry.name, None)
            raise

    def add_sync(self, entry: ServiceEntry):
        """Синхронный вариант для CLI (вне event loop)."""
        with self._lock:
            if len(self._services) >= MAX_SERVICES:
                raise ValueError(f"Max services limit ({MAX_SERVICES}) reached")
            if entry.name in self._services:
                raise ValueError(f"{entry.name!r} exists")
            self._services[entry.name] = entry
            cmd = {"action": "upsert_service", "data": self._entry_to_db_data(entry)}
        try:
            self._write_command(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] см. add() выше.
            with self._lock:
                self._services.pop(entry.name, None)
            raise

    async def update(self, entry: ServiceEntry):
        with self._lock:
            if entry.name not in self._services:
                raise KeyError(entry.name)
            _previous = self._services[entry.name]
            self._services[entry.name] = entry
            cmd = {"action": "upsert_service", "data": self._entry_to_db_data(entry)}
        try:
            await self._flush_command_async(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] см. add() выше — при ошибке записи
            # возвращаем предыдущее значение записи, а не оставляем новое.
            with self._lock:
                self._services[entry.name] = _previous
            raise

    def update_sync(self, entry: ServiceEntry):
        """Синхронный вариант для CLI (вне event loop)."""
        with self._lock:
            if entry.name not in self._services:
                raise KeyError(entry.name)
            _previous = self._services[entry.name]
            self._services[entry.name] = entry
            cmd = {"action": "upsert_service", "data": self._entry_to_db_data(entry)}
        try:
            self._write_command(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] см. update() выше.
            with self._lock:
                self._services[entry.name] = _previous
            raise

    async def delete(self, name: str):
        with self._lock:
            if name not in self._services:
                raise KeyError(name)
            _previous = self._services[name]
            del self._services[name]
            cmd = {"action": "delete_service", "name": name}
        try:
            await self._flush_command_async(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] при ошибке записи удалённая запись раньше
            # оставалась удалённой из RAM, хотя в БД всё ещё присутствовала.
            with self._lock:
                self._services[name] = _previous
            raise

    def delete_sync(self, name: str):
        """Синхронный вариант для CLI (вне event loop)."""
        with self._lock:
            if name not in self._services:
                raise KeyError(name)
            _previous = self._services[name]
            del self._services[name]
            cmd = {"action": "delete_service", "name": name}
        try:
            self._write_command(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-35] пропущен в v2.1-34 — единственный из шести
            # sync/async CRUD-методов без отката in-memory при ошибке записи.
            with self._lock:
                self._services[name] = _previous
            raise

    # [ФИЧА v2.1-4] CRUD для контейнеров — та же логика (лок, snapshot команды
    # под локом, flush вне лока), что и у сервисов выше; используют actions
    # upsert_container/delete_container, уже реализованные в gopanel-db
    # (Фича 1, с заделом на эту фичу).

    @staticmethod
    def _container_to_db_data(entry: DockerEntry) -> dict:
        return {
            "name": entry.name,
            "image": entry.image,
            "group_name": entry.group,
            "description": entry.description,
            "critical": int(entry.critical),
            "tags": json.dumps(entry.tags, ensure_ascii=False),
        }

    def list_containers(self) -> tuple[DockerEntry, ...]:
        with self._lock:
            return tuple(self._containers.values())

    def get_container(self, name: str) -> DockerEntry | None:
        with self._lock:
            return self._containers.get(name)

    async def add_container(self, entry: DockerEntry):
        with self._lock:
            if len(self._containers) >= MAX_SERVICES:
                raise ValueError(f"Max containers limit ({MAX_SERVICES}) reached")
            if entry.name in self._containers:
                raise ValueError(f"{entry.name!r} exists")
            self._containers[entry.name] = entry
            cmd = {"action": "upsert_container", "data": self._container_to_db_data(entry)}
        try:
            await self._flush_command_async(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] см. Registry.add() выше — тот же откат
            # in-memory состояния при ошибке записи в БД.
            with self._lock:
                self._containers.pop(entry.name, None)
            raise

    def add_container_sync(self, entry: DockerEntry):
        with self._lock:
            if len(self._containers) >= MAX_SERVICES:
                raise ValueError(f"Max containers limit ({MAX_SERVICES}) reached")
            if entry.name in self._containers:
                raise ValueError(f"{entry.name!r} exists")
            self._containers[entry.name] = entry
            cmd = {"action": "upsert_container", "data": self._container_to_db_data(entry)}
        try:
            self._write_command(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] см. add_container() выше.
            with self._lock:
                self._containers.pop(entry.name, None)
            raise

    async def update_container(self, entry: DockerEntry):
        with self._lock:
            if entry.name not in self._containers:
                raise KeyError(entry.name)
            _previous = self._containers[entry.name]
            self._containers[entry.name] = entry
            cmd = {"action": "upsert_container", "data": self._container_to_db_data(entry)}
        try:
            await self._flush_command_async(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] см. Registry.update() выше.
            with self._lock:
                self._containers[entry.name] = _previous
            raise

    def update_container_sync(self, entry: DockerEntry):
        with self._lock:
            if entry.name not in self._containers:
                raise KeyError(entry.name)
            _previous = self._containers[entry.name]
            self._containers[entry.name] = entry
            cmd = {"action": "upsert_container", "data": self._container_to_db_data(entry)}
        try:
            self._write_command(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] см. update_container() выше.
            with self._lock:
                self._containers[entry.name] = _previous
            raise

    async def delete_container(self, name: str):
        with self._lock:
            if name not in self._containers:
                raise KeyError(name)
            _previous = self._containers[name]
            del self._containers[name]
            cmd = {"action": "delete_container", "name": name}
        try:
            await self._flush_command_async(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] см. Registry.delete() выше.
            with self._lock:
                self._containers[name] = _previous
            raise

    def delete_container_sync(self, name: str):
        with self._lock:
            if name not in self._containers:
                raise KeyError(name)
            _previous = self._containers[name]
            del self._containers[name]
            cmd = {"action": "delete_container", "name": name}
        try:
            self._write_command(cmd)
        except Exception:
            # [ИСПРАВЛЕНО v2.1-34] см. delete_container() выше.
            with self._lock:
                self._containers[name] = _previous
            raise

    # [ИСПРАВЛЕНО v2.1-10] pending-restart флаг вынесен из in-memory словаря
    # процесса (был в DashboardScreen/AlertMonitor по отдельности) в общую
    # таблицу settings — TUI и бот работают в РАЗНЫХ ОС-процессах
    # (gopanel.service и gopanel-bot.service), поэтому рестарт, запущенный
    # через одного, был невидим другому: тот показывал "остановлен" +
    # "восстановлен" вместо одного "перезапущен". Ключ таблицы settings —
    # общий для обоих процессов файл gopanel.db, поэтому теперь флаг виден
    # обеим сторонам. time.time() (не time.monotonic()) — значение пишет
    # один процесс, читает другой, нужны сравнимые wall-clock метки.
    _PENDING_RESTART_PREFIX = "pending_restart:"

    async def mark_pending_restart(self, unit: str) -> None:
        cmd = {"action": "update_setting", "key": self._PENDING_RESTART_PREFIX + unit, "value": str(time.time())}
        await self._flush_command_async(cmd)

    async def clear_pending_restart(self, unit: str) -> None:
        cmd = {"action": "delete_setting", "key": self._PENDING_RESTART_PREFIX + unit}
        await self._flush_command_async(cmd)

    def get_pending_restarts(self) -> dict[str, float]:
        """Прямое чтение (без sudo, как list()/get()) — один SELECT за цикл опроса."""
        try:
            conn = sqlite3.connect(str(self.db_path), timeout=2)
            try:
                rows = conn.execute(
                    "SELECT key, value FROM settings WHERE key LIKE ?",
                    (self._PENDING_RESTART_PREFIX + "%",)
                ).fetchall()
            finally:
                conn.close()
        except sqlite3.Error as e:
            log.warning("Failed to read pending restarts: %s", e)
            return {}
        result: dict[str, float] = {}
        plen = len(self._PENDING_RESTART_PREFIX)
        for key, value in rows:
            try:
                result[key[plen:]] = float(value)
            except (ValueError, TypeError):
                continue
        return result


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
    enter_timestamp: int = 0


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
            st.enter_timestamp = enter_us
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
    # [ИСПРАВЛЕНО v2.1-19] assert_safe_unit не bool-предикат, а raise-или-return:
    # на первом же небезопасном unit'е список comprehension падал целиком, вместо
    # того чтобы пропустить только эту запись — весь опрос статусов останавливался
    # из-за одной некорректной записи в реестре.
    safe_units = []
    for u in units:
        try:
            assert_safe_unit(u)
            safe_units.append(u)
        except ValueError:
            log.warning("batch_show: skip unsafe unit %r", u)
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
        # [ИСПРАВЛЕНО v2.1-8] таймаут batch-запроса увеличен 15с -> 25с —
        # реже уходим в поюнитный фоллбэк при кратковременной медлительности
        # systemctl/D-Bus. Лог понижен ERROR->WARNING: это не необработанный
        # сбой, а штатный, самовосстанавливающийся сценарий (см. фоллбэк ниже).
        code, out, err = await run_exec(cmd, sudo=settings.use_sudo, timeout=25)
        if code != 0:
            log.warning("batch_show chunk failed (%d units): %s — falling back to per-unit", len(chunk), err)
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

write_file "$APP_DIR/src/gopanel/docker.py" <<'PY'
# [ФИЧА v2.1-4] Аналог systemd.py, но для Docker-контейнеров через
# gopanel-docker wrapper. Статусы приводятся к тем же меткам active/
# inactive/failed/activating, что и systemd, чтобы переиспользовать
# существующую цветовую схему и логику детекции падений/рестартов.
from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from .config import settings
from .utils import run_exec

log = logging.getLogger("gopanel.docker")

_STATE_MAP = {
    "running": "active",
    "exited": "inactive",
    "paused": "inactive",
    "restarting": "activating",
    "dead": "failed",
    "created": "inactive",
    "removing": "deactivating",
}


@dataclass(slots=True)
class ContainerStatus:
    name: str = ""
    active: str = "unknown"     # приведено к systemd-меткам (см. _STATE_MAP)
    status_text: str = ""       # исходный текст docker ("Up 5 days", "Exited (0) 2 hours ago")
    image: str = ""
    cpu_percent: float = 0.0
    mem_usage_text: str = ""
    tags: list = field(default_factory=list)


async def docker_ps() -> dict[str, ContainerStatus]:
    """Возвращает статусы ВСЕХ известных docker'у контейнеров одним вызовом."""
    code, out, err = await run_exec([str(settings.docker), "ps"], sudo=settings.use_sudo, timeout=15)
    if code != 0:
        log.warning("docker ps failed: %s", err.strip() or f"exit={code}")
        return {}
    result: dict[str, ContainerStatus] = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = obj.get("Names", "")
        if not name:
            continue
        state = obj.get("State", "")
        result[name] = ContainerStatus(
            name=name,
            active=_STATE_MAP.get(state, "inactive"),
            status_text=obj.get("Status", ""),
            image=obj.get("Image", ""),
        )
    return result


async def docker_stats(name: str) -> tuple[float, str] | None:
    """CPU% и Mem usage для одного контейнера. None при ошибке/остановленном контейнере."""
    code, out, err = await run_exec([str(settings.docker), "stats", name], sudo=settings.use_sudo, timeout=10)
    if code != 0:
        return None
    line = out.strip().splitlines()[0] if out.strip() else ""
    if not line:
        return None
    try:
        obj = json.loads(line)
        cpu_raw = obj.get("CPUPerc", "0%").rstrip("%")
        return float(cpu_raw), obj.get("MemUsage", "—")
    except (json.JSONDecodeError, ValueError):
        return None


async def docker_control(action: str, name: str) -> tuple[bool, str]:
    if action not in {"start", "stop", "restart"}:
        raise ValueError(action)
    code, out, err = await run_exec([str(settings.docker), action, name], sudo=settings.use_sudo, timeout=30)
    return code == 0, (out + err).strip() or ("ok" if code == 0 else f"exit={code}")


async def docker_logs(name: str) -> str:
    """Последние 200 строк docker logs (см. gopanel-docker: --tail 200)."""
    code, out, err = await run_exec([str(settings.docker), "logs", name], sudo=settings.use_sudo, timeout=15)
    if code != 0:
        return f"[error: {err.strip() or f'exit={code}'}]"
    return out
PY

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
            while self._proc_cache:
                k, entry = next(iter(self._proc_cache.items()))
                ts = entry[1]
                if now - ts > CACHE_TTL:
                    del self._proc_cache[k]
                else:
                    break

            cached = self._proc_cache.get(pid)
            try:
                p = psutil.Process(pid)
                ct = p.create_time()

                if cached and cached[0] != ct:
                    del self._proc_cache[pid]
                    cached = None

                if cached and 'proc_obj' in cached[2]:
                    p_cached = cached[2]['proc_obj']
                    try:
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
            [settings.journalctl, "-u", unit, "-n", str(n), "--no-pager", "-o", "short"],
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
            [settings.journalctl, "-u", unit, "-f", "--no-pager", "-o", "short"],
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
    # Счётчик пропущенных строк из-за throttle (3.3)
    # При превышении MAX_LINES_PER_SEC строки дропаются — раньше молча.
    # Теперь выдаём предупреждение каждые 100 пропущенных строк.
    skipped = 0
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
                # FIX M-1: сбрасываем skipped вместе с window_count.
                # Ранее skipped был кумулятивным — первые 99 пропущенных строк
                # терялись молча (порог 100 достигался только при длительном burst).
                # Теперь репортируем per-second: каждые 100 дропов в рамках
                # одной секунды выдаём предупреждение, затем счётчик сбрасывается.
                window_start = now
                window_count = 0
                skipped = 0
            window_count += 1
            if window_count > MAX_LINES_PER_SEC:
                skipped += 1
                if skipped % 100 == 0:
                    yield f"[warn: пропущено {skipped} строк/сек из-за высокой нагрузки]"
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
        # FIX H-5: проверка троттлинга и запись в _last вынесены ПОД lock,
        # чтобы операция check-then-set была атомарной. Без этого два
        # coroutine могут одновременно пройти проверку (now - last < 3 == False)
        # до того, как первый запишет метку времени, и оба выдадут алерт.
        # _cleanup_last вызывается до lock — это безопасно, т.к. она только
        # фильтрует устаревшие ключи и не влияет на корректность throttle.
        self._cleanup_last(now)
        throttle_key = f"{service}:{level}"
        async with self._lock:
            if now - self._last.get(throttle_key, 0) < 3:
                return
            self._last[throttle_key] = now
            a = Alert(now, level, service, msg)
            self._q.append(a)
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
        self._subs = [ref for ref in list(self._subs) if ref() is not None and ref() is not q]

    def cleanup_dead(self):
        self._subs = [ref for ref in list(self._subs) if ref() is not None]
PY

write_file "$APP_DIR/src/gopanel/cli.py" <<'PY'
import argparse
import subprocess  # [ИСПРАВЛЕНО v2.1-38]
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
        get_registry().add_sync(ServiceEntry(
            name=args.name,
            unit=args.unit,
            group=args.group,
            description=args.description or "",
            critical=args.critical,
            tags=[t for t in (args.tags or "").split(",") if t]
        ))
    except (ValueError, OSError, subprocess.TimeoutExpired) as e:  # [ИСПРАВЛЕНО v2.1-38] (Low)
        print(f"Error: {e}", file=sys.stderr)
        return 1
    print(f"✓ Добавлен '{args.name}'")
    return 0


def cmd_remove(args):
    try:
        get_registry().delete_sync(args.name)
    except KeyError:
        print(f"Не найден: {args.name}", file=sys.stderr)
        return 1
    except (OSError, subprocess.TimeoutExpired) as e:  # [ИСПРАВЛЕНО v2.1-38] (Low)
        print(f"Error: {e}", file=sys.stderr)
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
from .config import settings


def _setup_logging() -> None:
    fmt = "%(asctime)s %(levelname)-7s %(name)s: %(message)s"
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    try:
        settings.log_path.parent.mkdir(parents=True, exist_ok=True)
        # FIX LOG-ROTATE: заменяем RotatingFileHandler на FileHandler.
        # RotatingFileHandler самостоятельно переименовывал gopanel.log →
        # gopanel.log.1 при достижении 5MB, конфликтуя с logrotate (copytruncate).
        # Итог: смешанная ротация — Python создавал .log.1/.log.2,
        # logrotate создавал .log.1.gz, оба механизма мешали друг другу.
        # Теперь вся ротация — на стороне logrotate (copytruncate обнуляет файл
        # на месте, Python продолжает писать в тот же fd без переоткрытия).
        handlers.append(logging.FileHandler(
            settings.log_path,
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

# ======================== PYTHON SOURCE — APP.PY (с поддержкой бота) ========================
# app.py пишется сразу с поддержкой бота — без патчинга после установки

write_file "$APP_DIR/src/gopanel/app.py" <<'PY'
import asyncio
import logging
import os
import time
from textual.app import App
from textual.binding import Binding
from .alerts import AlertManager
from .metrics import MetricsCollector
from .registry import get_registry
from .ui.screens.dashboard import DashboardScreen
from .ui.screens.logs import LogsScreen
from .ui.screens.bot_settings import BotSettingsScreen

log = logging.getLogger("gopanel.app")
NOTIFY_CLEANUP_INTERVAL = 300
NOTIFY_TTL = 600


class GoPanelApp(App):
    TITLE = "Центр мониторинга и управления сервисами"  # [ФИЧА v2.1-6]
    SUB_TITLE = None
    CSS_PATH = "ui/theme.tcss"
    BINDINGS = [
        Binding("q", "quit", "Выход", priority=True),
        Binding("1", "screen('dashboard')", "Панель"),
        Binding("2", "screen('logs')", "Логи"),
        Binding("4", "screen('bot')", "Бот"),
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
        # [ИСПРАВЛЕНО v2.6] лог-файл создавался, но на здоровой панели без
        # ошибок в него не попадало ни строки — не было способа убедиться,
        # что логирование вообще работает. Строка при старте закрывает это.
        log.info("GoPanel TUI запущен (PID=%s)", os.getpid())
        self.metrics.bind_loop(asyncio.get_running_loop())
        self.install_screen(DashboardScreen(), "dashboard")
        self.install_screen(LogsScreen(), "logs")
        self.install_screen(BotSettingsScreen(), "bot")
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

/* [ИСПРАВЛЕНО v2.1-43]: ряд кнопок Docker тянулся на 1fr (на терминале ~53 строки - 8 строк
   при высоте кнопок 3), под кнопками оставалась пустая полоса, а таблицы и панель алертов
   получали меньше места. Высота ряда = высоте кнопок; освободившееся место делят между
   собой таблицы и панель алертов.
   [ИСПРАВЛЕНО v2.1-44]: в v2.1-43 было height: 3 - ошибка: у кнопок Docker действует общее
   правило Button { margin: 1 }, поэтому им нужно 5 строк (3 высота + по 1 отступу сверху и
   снизу); при 3 нижняя рамка кнопок обрезалась. Верхний ряд (#action-buttons) использует
   margin: 0 1 у кнопок и внешний margin: 1 0 у ряда, ему хватает 3. */
#docker-action-buttons {
    height: 5;
}

AlertsPanel {
    /* [ИСПРАВЛЕНО v2.1-37] Textual применяет CSS_PATH-стили (этот файл)
       поверх DEFAULT_CSS виджета — правило "height: auto" здесь имело
       приоритет над фиксом v2.1-36 в alerts_panel.py, который менял только
       DEFAULT_CSS и поэтому не действовал в реальном рендере. См. подробный
       комментарий о причине бага (задержка автопрокрутки RichLog на одну
       запись при auto-высоте контейнера) в alerts_panel.py.
    */
    /* [ИСПРАВЛЕНО v2.1-39]: фиксированные 12 строк при обёртке Horizontal (1fr) в
       дашборде обрезались обёрткой: она получала 2-8 строк (делит высоту с
       двумя таблицами и рядом кнопок Docker), нижние строки RichLog и низ
       полосы прокрутки оказывались за границей видимой области, а свежая
       запись автопрокрутки - в скрытой части (видна только после следующей).
       Высота панели теперь равна высоте обёртки ([ИСПРАВЛЕНО v2.1-40]: минимум у обёртки
       НЕ задаётся - он сжимал таблицы и кнопки Docker на терминалах до ~55 строк).
       От содержимого высота по-прежнему не зависит. */
    height: 100%;
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
#btn-bot { background: #9966ff; color: #ffffff; border: tall #7744cc; }
#btn-bot:hover { background: #7744cc; color: #ffffff; }
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
#m-title, #log-title { background: #121a24; color: #00ffaa; text-style: bold; padding: 0 2; height: 3; content-align: center middle; text-align: center; }
CSS

write_file "$APP_DIR/src/gopanel/ui/widgets/service_table.py" <<'PY'
from textual.widgets import DataTable
from textual.message import Message

# [ФИЧА v2.1-6] Локализация systemd-статусов только для ОТОБРАЖЕНИЯ в
# таблице. Детекция событий (dashboard.py: failed/active/inactive/...)
# по-прежнему сравнивает СЫРЫЕ английские значения st.active/st.sub —
# перевод применяется в самом конце, в момент построения строки таблицы,
# и никак не затрагивает логику определения падений/рестартов.
STATE_RU = {
    "active": "активное",
    "inactive": "неактивное",
    "failed": "ошибка",
    "activating": "запуск",
    "deactivating": "остановка",
    "reloading": "перезагрузка",
}

SUB_RU = {
    "running": "работает",
    "dead": "остановлен",
    "exited": "завершён",
    "failed": "сбой",
    "start-pre": "подготовка",
    "stop-post": "завершение",
    "auto-restart": "авто-рестарт",
    "start": "старт",
    "stop": "стоп",
    "listening": "слушает",
    "plugged": "подключён",
    "mounted": "смонтирован",
    "waiting": "ожидание",
    "tentative": "пробный",
}


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
        # [ФИЧА v2.1-2] фильтр по группе (None = показывать все) + кэш
        # последних данных, чтобы filter_by_group могла перерисовать таблицу
        # немедленно, не дожидаясь следующего poll-цикла _do_refresh
        self._current_filter: str | None = None
        self._last_services: list = []
        self._last_statuses: dict = {}
        self._last_proc_metrics: dict = {}

    def on_mount(self):
        self.add_columns("Имя", "Юнит", "Статус", "Подстатус", "PID", "CPU", "Память", "Аптайм", "Рестарты", "Описание")

    def filter_by_group(self, group: str | None) -> None:
        """Фильтрует отображаемые строки по группе. group=None — показать все."""
        self._current_filter = group
        self.refresh_rows(self._last_services, self._last_statuses, self._last_proc_metrics)

    def refresh_rows(self, services, statuses, proc_metrics=None):
        proc_metrics = proc_metrics or {}
        self._last_services = services
        self._last_statuses = statuses
        self._last_proc_metrics = proc_metrics
        if self._current_filter is not None:
            services = [s for s in services if s.get("group") == self._current_filter]
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
                # [ФИЧА v2.1-6] fallback на исходное значение, если незнакомый
                # статус (например, новая версия systemd добавит sub-state)
                state_ru = STATE_RU.get(st.active, st.active)
                sub_ru = SUB_RU.get(st.sub, st.sub)
                row = [
                    s["name"], s["unit"], state_ru, sub_ru,
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

write_file "$APP_DIR/src/gopanel/ui/widgets/docker_table.py" <<'PY'
# [ФИЧА v2.1-4] Таблица Docker-контейнеров — структура зеркалит service_table.py
# (та же логика сохранения курсора, тот же паттерн Action-сообщения), но
# работает с DockerEntry/ContainerStatus вместо ServiceEntry/UnitStatus.
from textual.widgets import DataTable
from textual.message import Message

_STATE_RU = {
    "active": "активное",
    "inactive": "неактивное",
    "failed": "ошибка",
    "activating": "запуск",
    "deactivating": "остановка",
}


class DockerTable(DataTable):
    BINDINGS = [
        ("a", "add", "Добавить"),
        ("e", "edit", "Изменить"),
        ("d", "del", "Удалить"),
        ("s", "start", "Старт"),
        ("x", "stop", "Стоп"),
        ("ctrl_r", "restart", "Рестарт"),
    ]

    def __init__(self):
        super().__init__(zebra_stripes=True, cursor_type="row")

    def on_mount(self):
        self.add_columns("Имя", "Образ", "Состояние", "Статус", "CPU", "Память", "Описание")

    def refresh_rows(self, containers, statuses):
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
        for idx, c in enumerate(containers):
            st = statuses.get(c["name"])
            if not st:
                row = [c["name"], c["image"][:30], "—", "—", "—", "—", c["description"][:40]]
            else:
                state_display = _STATE_RU.get(st.active, st.active)
                # [ИСПРАВЛЕНО v2.1-11] раньше `and st.cpu_percent` считало
                # простаивающий контейнер (0.0%) неотличимым от "статистика
                # не запрашивалась" — 0.0 в Python falsy. Проверяем по
                # mem_usage_text (непустая строка только если docker_stats()
                # реально успешно отработал).
                cpu = f"{st.cpu_percent:.1f}%" if st.active == "active" and st.mem_usage_text else "—"
                mem = st.mem_usage_text or "—"
                row = [c["name"], c["image"][:30], state_display, st.status_text[:24], cpu, mem, c["description"][:40]]
            self.add_row(*row, key=c["name"])
            if prev_key and c["name"] == prev_key:
                new_row_index = idx

        try:
            if new_row_index is not None:
                self.move_cursor(row=new_row_index)
            elif prev_row is not None and prev_row < len(containers):
                self.move_cursor(row=prev_row)
        except Exception:
            pass

    def selected_name(self):
        if self.cursor_row is None:
            return None
        try:
            return self.get_row_at(self.cursor_row)[0]
        except Exception:
            return None

    class Action(Message):
        def __init__(self, act, container):
            self.act = act
            self.container = container
            super().__init__()

    def action_add(self): self.post_message(self.Action("add", None))
    def action_edit(self): self.post_message(self.Action("edit", self.selected_name()))
    def action_del(self): self.post_message(self.Action("del", self.selected_name()))
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
    # [ИСПРАВЛЕНО v2.1-36] "height:auto; min-height:10" без потолка — панель
    # растёт под содержимое без ограничения. Известная особенность Textual:
    # запись в RichLog внутри контейнера с auto-высотой пересчитывает layout
    # ПОСЛЕ отрисовки — auto_scroll прокручивает по ещё старому (не
    # пересчитанному) размеру, поэтому новая строка остаётся невидимой до
    # следующей записи, которая наконец подхватывает актуальный размер (но
    # сама повторяет ту же задержку на один шаг). Фиксированная высота отдаёт
    # прокрутку самому RichLog — без пересчёта layout на каждую строку.
    DEFAULT_CSS = "AlertsPanel { height:12; border:round #ffaa00; background:#0d1218; }"

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
from pathlib import Path
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import Footer, Static, Button, Select
from ... import __version__
from ...registry import get_registry
from ...systemd import batch_show, control
from ...docker import docker_ps, docker_control, docker_stats
from ..widgets.alerts_panel import AlertsPanel
from ..widgets.service_table import ServiceTable
from ..widgets.docker_table import DockerTable
from ..widgets.status_bar import StatusBar
from .service_form import ServiceFormScreen
from .container_form import ContainerFormScreen

log = logging.getLogger("gopanel.dashboard")
CONTROL_COOLDOWN = 2.0
_LAST_CONTROL_MAX = 300
# [ИСПРАВЛЕНО v2.2] метка времени фактического attach к tmux-сессии,
# пишется в gopanel-attach. Используется для корректного отображения
# "Сессия с ..." при реконнекте к уже работающей панели (см. InfoPanel).
ATTACH_MARKER = Path("/opt/gopanel/data/last_attach")


class InfoPanel(Static):
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
        self._started_at = datetime.now().strftime("%d.%m.%Y %H:%M:%S")

    def set_started_at(self, value: str) -> None:
        # [ИСПРАВЛЕНО v2.2] позволяет обновить "Сессия с ..." по факту
        # реального attach, а не только при создании процесса панели
        self._started_at = value

    def refresh_info(self, total: int, active: int, failed: int,
                     inactive: int, events: int) -> None:
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
            "[#9966ff]4[/] Бот  "
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
    # [ФИЧА v2.1-2] g — открыть выбор группы, G — сбросить фильтр (показать все)
    # [ИСПРАВЛЕНО v2.1-10] tab — переключить фокус между таблицей сервисов и
    # Docker-таблицей напрямую (не через цепочку всех фокусируемых виджетов
    # по умолчанию — их на экране много: Select, кнопки и т.д.)
    BINDINGS = [
        ("g", "open_group_filter", "Группа"),
        ("G", "reset_group_filter", "Все группы"),
        ("tab", "switch_table", "Переключить таблицу"),
    ]

    def __init__(self):
        super().__init__()
        self._last_control: dict[tuple[str, str], float] = {}
        self._prev_states: dict[str, str] = {}
        self._prev_enter_ts: dict[str, int] = {}
        # FIX SLOW-RESTART-TUI: аналог _last_active_enter_ts из бота.
        # _prev_enter_ts обновляется каждый poll включая фазу activating (ts=0).
        # Для детекции медленного рестарта нужен enter_ts из последнего
        # активного состояния.
        self._last_active_enter_ts: dict[str, int] = {}
        # [ИСПРАВЛЕНО v2.1-10] pending-restart больше не хранится в памяти
        # этого процесса — см. Registry.mark_pending_restart/get_pending_restarts
        # (registry.py). Раньше TUI и бот, будучи разными ОС-процессами, не
        # видели pending-флаг друг друга: рестарт через бота отображался в
        # TUI как "остановлен"+"восстановлен", и наоборот.
        # [ИСПРАВЛЕНО v2.1-15] 30с увеличено до 120с — нагрузочный тест
        # показал: сам batch_show(таймаут 25с, v2.1-8) уже занимает большую
        # часть окна в 30с, а под реальной нагрузкой (много сервисов
        # рестартуют одновременно, systemctl/D-Bus объективно медленнее)
        # один цикл опроса легко занимает больше 30с — тайм-аут флага
        # истекал ДО того, как опрос успевал увидеть возврат в active, и
        # исходный баг (см. пред. абзац) возвращался именно под нагрузкой,
        # то есть ровно тогда, когда защита нужнее всего.
        self._pending_restart_timeout = 120.0
        self._event_count: int = 0
        # [ИСПРАВЛЕНО v2.1-38] (Medium): детекция падений critical-контейнеров в TUI.
        self._container_bad: dict[str, int] = {}
        self._container_alerted: set[str] = set()
        # [ИСПРАВЛЕНО v2.1-39]: см. комментарий у AlertMonitor._handled_pending в боте.
        self._handled_pending: dict[str, float] = {}
        # [ИСПРАВЛЕНО v2.1-41] время последнего предупреждения "Docker refresh failed" (троттлинг лога).
        self._docker_warn_ts: float = 0.0
        self._refresh_lock = asyncio.Lock()
        # FIX M-1: инициализируем _t в __init__, чтобы on_unmount не падал
        # с AttributeError если вызывается раньше on_mount (edge case при
        # завершении приложения до полной инициализации экрана).
        self._t: asyncio.Task | None = None
        # FIX BG-TASKS: asyncio.create_task() без сохранения ссылки опасен —
        # event loop держит weak reference на задачу; при завершении приложения
        # незавершённые задачи дают «Task was destroyed but it was pending».
        # Храним strong references, удаляем через done_callback автоматически.
        self._bg_tasks: set[asyncio.Task] = set()
        # [ИСПРАВЛЕНО v2.2] последняя учтённая mtime ATTACH_MARKER
        self._last_attach_mtime: float = 0.0

    def compose(self):
        yield Static(
            "[bold #00ffaa]Центр мониторинга и управления сервисами[/]",  # [ФИЧА v2.1-6]
            id="large-header",
            classes="large-header"
        )
        yield Static(f"v{__version__}", classes="version-subtitle")
        with Vertical():
            yield Static("📊 Мониторинг сервисов", classes="panel")
            yield Select(
                options=self._build_group_options(),
                value="__all__",
                id="group-filter",
                allow_blank=False,
            )
            yield ServiceTable()
            with Horizontal(id="action-buttons"):
                yield Button("➕ Добавить", id="btn-add")
                yield Button("✏ Изменить", id="btn-edit")
                yield Button("🗑 Удалить", id="btn-del")
                yield Button("▶ Старт", id="btn-start")
                yield Button("⏹ Стоп", id="btn-stop")
                yield Button("🔄 Рестарт", id="btn-restart")
                yield Button("📜 Логи", id="btn-logs")
                yield Button("⚙ Бот", id="btn-bot")
                yield Button("🚪 Выход", id="btn-quit")
            yield Static("🐳 Docker-контейнеры", classes="panel")
            yield DockerTable()
            with Horizontal(id="docker-action-buttons"):
                yield Button("➕ Добавить", id="dbtn-add")
                yield Button("✏ Изменить", id="dbtn-edit")
                yield Button("🗑 Удалить", id="dbtn-del")
                yield Button("▶ Старт", id="dbtn-start")
                yield Button("⏹ Стоп", id="dbtn-stop")
                yield Button("🔄 Рестарт", id="dbtn-restart")
            with Horizontal():
                yield AlertsPanel(self.app.alerts)
            yield InfoPanel()
        yield StatusBar()
        yield Footer()

    def on_mount(self):
        self._t = asyncio.create_task(self._loop())

    def _build_group_options(self):
        # [ФИЧА v2.1-2] список групп по данным реестра на текущий момент
        try:
            entries = get_registry().list()
        except Exception:
            entries = []
        # [ИСПРАВЛЕНО v2.1-7] группы контейнеров (Фича 4) тоже учитываются в
        # списке — раньше группа, существующая только у контейнеров, не
        # попадала в выпадающий список вовсе. Сама фильтрация по-прежнему
        # применяется только к ServiceTable (у DockerTable нет фильтра по
        # группе — контейнеров в TUI мало, отдельная таблица уже компактна).
        try:
            containers = get_registry().list_containers()
        except Exception:
            containers = []
        counts: dict[str, int] = {}
        for e in entries:
            counts[e.group] = counts.get(e.group, 0) + 1
        for c in containers:
            counts.setdefault(c.group, 0)
        options = [(f"Все ({len(entries)})", "__all__")]
        for group in sorted(counts):
            options.append((f"{group} ({counts[group]})", group))
        return options

    def on_select_changed(self, event: Select.Changed) -> None:
        if event.select.id != "group-filter":
            return
        group = None if event.value == "__all__" else event.value
        try:
            self.query_one(ServiceTable).filter_by_group(group)
        except Exception:
            pass

    def action_open_group_filter(self):
        try:
            self.query_one("#group-filter", Select).focus()
        except Exception:
            pass

    def action_reset_group_filter(self):
        try:
            self.query_one("#group-filter", Select).value = "__all__"
        except Exception:
            pass

    def action_switch_table(self):
        # [ИСПРАВЛЕНО v2.1-10] tab переключает фокус конкретно между
        # ServiceTable и DockerTable, минуя остальные фокусируемые виджеты
        try:
            stbl = self.query_one(ServiceTable)
            dtbl = self.query_one(DockerTable)
        except Exception:
            return
        if self.focused is stbl:
            dtbl.focus()
        else:
            stbl.focus()

    def _modal_already_open(self) -> bool:
        # [ИСПРАВЛЕНО v2.1-13] при частом/дублирующемся нажатии хоткея или
        # кнопки (например, быстрые повторные нажатия "a") push_screen
        # вызывался повторно ДО того, как предыдущая модалка успевала забрать
        # фокус — открывались несколько стековых экземпляров ServiceFormScreen/
        # ContainerFormScreen одновременно, и Escape не гарантированно
        # закрывал их по одному (наблюдалось эмпирически даже с паузами
        # между нажатиями). Явная проверка текущего экрана перед push_screen.
        return isinstance(self.app.screen, (ServiceFormScreen, ContainerFormScreen))

    async def on_unmount(self) -> None:
        # FIX M-1: проверяем _t на None перед cancel() — в норме он всегда
        # установлен из on_mount, но при race condition при завершении
        # приложения on_unmount может прийти раньше on_mount.
        if self._t is not None:
            self._t.cancel()
            try:
                await self._t
            except asyncio.CancelledError:
                pass
        # FIX BG-TASKS: при размонтировании отменяем все незавершённые
        # фоновые задачи (_ctrl, _delete_async, _refresh из callback).
        for task in list(self._bg_tasks):
            task.cancel()
        if self._bg_tasks:
            await asyncio.gather(*self._bg_tasks, return_exceptions=True)
        self._bg_tasks.clear()

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
        # Блокировка предотвращает параллельное выполнение _refresh
        # при одновременных вызовах из _loop и _ctrl
        if self._refresh_lock.locked():
            return
        async with self._refresh_lock:
            await self._do_refresh()

    async def _do_refresh(self):
        try:
            tbl = self.query_one(ServiceTable)
        except Exception:
            return

        # [ФИЧА v2.1-4] обновление Docker-таблицы — до early-return по пустому
        # списку сервисов ниже, иначе контейнеры не обновлялись бы вовсе при
        # нулевом количестве systemd-сервисов в реестре
        try:
            dtbl = self.query_one(DockerTable)
            containers = get_registry().list_containers()
            container_rows = [
                {"name": c.name, "image": c.image, "description": c.description, "critical": c.critical}
                for c in containers
            ]
            # [ИСПРАВЛЕНО v2.1-38] (Low): таймаут, чтобы зависший docker-демон не растягивал
            # цикл опроса systemd на 15+ с (при таймауте блок пропускается до след. цикла).
            docker_statuses = await asyncio.wait_for(docker_ps(), timeout=5.0) if containers else {}
            # [ИСПРАВЛЕНО v2.1-10] live CPU/RAM — раньше docker_stats() был
            # написан, но никогда не вызывался из цикла опроса (столбцы
            # CPU/Память в DockerTable всегда показывали "—"). Запрашиваем
            # параллельно только для реально запущенных контейнеров — тот же
            # паттерн, что и proc_metrics для systemd-сервисов выше.
            running = [name for name, st in docker_statuses.items() if st.active == "active"]
            if running:
                # [ИСПРАВЛЕНО v2.1-38] (Low): общий таймаут на stats; при превышении CPU/RAM просто не обновляются.
                try:
                    stats_results = await asyncio.wait_for(
                        asyncio.gather(
                            *[docker_stats(name) for name in running],
                            return_exceptions=True
                        ),
                        timeout=10.0,  # [ИСПРАВЛЕНО v2.1-42] было 5.0: у docker_stats свой таймаут 10 с, лимит 5 с
                        # только обрезал бы медленные, но успешные ответы под нагрузкой (CPU/RAM переставали обновляться)
                    )
                except asyncio.TimeoutError:
                    stats_results = [None] * len(running)
                for name, result in zip(running, stats_results):
                    if isinstance(result, Exception) or result is None:
                        continue
                    cpu, mem = result
                    docker_statuses[name].cpu_percent = cpu
                    docker_statuses[name].mem_usage_text = mem
            dtbl.refresh_rows(container_rows, docker_statuses)
            # [ИСПРАВЛЕНО v2.1-38] (Medium): детекция падений critical-контейнеров. Подтверждение
            # двумя опросами подряд (штатный docker restart ложных алертов не даёт);
            # пустой docker_statuses = docker недоступен -> цикл пропускается.
            names = {c.name for c in containers}
            for stale in set(self._container_bad) - names:
                self._container_bad.pop(stale, None)
                self._container_alerted.discard(stale)
            if docker_statuses:
                for c in containers:
                    if not c.critical:
                        continue
                    cst = docker_statuses.get(c.name)
                    if cst is not None and cst.active == "active":
                        if c.name in self._container_alerted:
                            self._container_alerted.discard(c.name)
                            await self.app.alerts.push("info", c.name, "контейнер восстановлен")
                            self._event_count += 1
                        self._container_bad[c.name] = 0
                        continue
                    self._container_bad[c.name] = self._container_bad.get(c.name, 0) + 1
                    if self._container_bad[c.name] >= 2 and c.name not in self._container_alerted:
                        self._container_alerted.add(c.name)
                        state_txt = cst.status_text if cst is not None and cst.status_text else "не найден в docker"
                        # [ИСПРАВЛЕНО v2.1-46]: как в боте (_send_container_notice) - Exited (0)/(143) это
                        # штатная остановка (docker stop шлёт SIGTERM -> код 143), а не падение: уровень warn.
                        if cst is not None and (cst.status_text or "").startswith(("Exited (0)", "Exited (143)")):
                            await self.app.alerts.push("warn", c.name, f"контейнер остановлен ({state_txt})")
                        else:
                            await self.app.alerts.push("critical", c.name, f"контейнер упал/остановлен ({state_txt})")
                        self._event_count += 1
        except Exception as ex:
            # [ИСПРАВЛЕНО v2.1-41] при недоступном docker цикл падал в это место каждые ~2-7 с
            # и забивал лог одинаковыми строками - пишем не чаще раза в минуту.
            if time.time() - self._docker_warn_ts >= 60.0:
                self._docker_warn_ts = time.time()
                log.warning("Docker refresh failed: %s", ex)

        entries = get_registry().list()
        # [ИСПРАВЛЕНО v2.1-17] очистка словарей отслеживания для удалённых
        # сервисов — зеркалит уже существующую очистку на стороне бота (FIX
        # MEMLEAK-1, alerts.py). Без этого при работе панели неделями/
        # месяцами с добавлением/удалением сервисов эти словари росли бы
        # неограниченно (до этого исправления — навсегда, даже после
        # удаления сервиса из реестра).
        active_units = {e.unit for e in entries}
        for stale in set(self._prev_states) - active_units:
            self._prev_states.pop(stale, None)
            self._prev_enter_ts.pop(stale, None)
            self._last_active_enter_ts.pop(stale, None)
        if not entries:
            tbl.refresh_rows([], {})
            self._update_info_panel([], {}, {})
            return
        units = [e.unit for e in entries]
        statuses = await batch_show(units)

        proc_metrics: dict = {}
        pid_entries = [(e, statuses[e.unit].main_pid)
                       for e in entries
                       if statuses.get(e.unit) and statuses[e.unit].main_pid]
        if pid_entries:
            results = await asyncio.gather(
                *[self.app.metrics.process(pid) for _, pid in pid_entries],
                return_exceptions=True
            )
            for (e, _), result in zip(pid_entries, results):
                if not isinstance(result, Exception):
                    proc_metrics[e.unit] = result

        rows = [
            {
                "name": e.name,
                "unit": e.unit,
                "description": e.description,
                "critical": e.critical,
                "manual_restarts": e.manual_restarts,
                "group": e.group,
            }
            for e in entries
        ]

        # [ФИЧА v2.1-2] обновляем список групп в выпадающем списке — в try,
        # чтобы сбой обновления опций не ронял основной цикл опроса
        try:
            sel = self.query_one("#group-filter", Select)
            new_options = self._build_group_options()
            if new_options != list(sel._options):
                current = sel.value
                sel.set_options(new_options)
                if current in [o[1] for o in new_options]:
                    sel.value = current
        except Exception:
            pass

        # [ИСПРАВЛЕНО v2.1-10] один SELECT за цикл опроса вместо in-memory
        # словаря — тот же флаг виден и боту (см. registry.py)
        # [ИСПРАВЛЕНО v2.1-18] синхронный sqlite3-вызов раньше выполнялся
        # прямо в event loop Textual (в отличие от бота, где этот же вызов
        # уже обёрнут в asyncio.to_thread) — при конкурентной блокировке БД
        # мог подвесить интерфейс до timeout соединения. Обёрнут в to_thread.
        try:
            pending_map = await asyncio.to_thread(get_registry().get_pending_restarts)
        except Exception:
            pending_map = {}

        for e in entries:
            st = statuses.get(e.unit)
            if not st or not e.critical:
                # [ИСПРАВЛЕНО v2.1-31] уточнён комментарий — раньше утверждал,
                # что ведётся "детекция рестарта" для некритических, хотя код
                # ниже только сохраняет prev_states/prev_enter_ts и делает
                # continue: никакого уведомления для некритических не шлётся
                # (сознательная политика, симметричная с ботом — v2.1-28/31).
                # Состояние сохраняется, чтобы при появлении critical=true у
                # уже отслеживаемого сервиса не было ложного скачка enter_ts.
                if st and st.active == "active" and st.enter_timestamp != 0:
                    self._last_active_enter_ts[e.unit] = st.enter_timestamp
                if st:
                    self._prev_states[e.unit] = st.active
                    self._prev_enter_ts[e.unit] = st.enter_timestamp
                continue
            prev = self._prev_states.get(e.unit)
            curr = st.active
            curr_enter_ts = st.enter_timestamp
            prev_enter_ts = self._prev_enter_ts.get(e.unit, 0)
            last_active_ts = self._last_active_enter_ts.get(e.unit, 0)

            # [ИСПРАВЛЕНО v2.4] если для этого unit'а ожидается ручной рестарт
            # (см. _ctrl), не гадаем по фазе systemd — подавляем "остановлен"
            # для любых промежуточных состояний и по возврату в active
            # отправляем ОДНО уведомление о рестарте.
            pending_since = pending_map.get(e.unit)
            if pending_since is not None and time.time() - pending_since > self._pending_restart_timeout:
                try:
                    await get_registry().clear_pending_restart(e.unit)
                except Exception:
                    pass
                pending_since = None
            # [ИСПРАВЛЕНО v2.1-39]: флаг этой метки уже обработан данным процессом.
            if pending_since is None:
                self._handled_pending.pop(e.unit, None)
            elif self._handled_pending.get(e.unit) == pending_since:
                pending_since = None
            if pending_since is not None:
                # [ИСПРАВЛЕНО v2.1-38] (Medium): условие снятия флага как в боте (v2.1-36) -
                # нужен новый enter_timestamp либо смена предыдущего статуса.
                if curr == "active" and (curr_enter_ts != prev_enter_ts or prev != "active"):
                    # [ИСПРАВЛЕНО v2.1-39]: флаг в БД не удаляем - его ещё ждёт бот.
                    self._handled_pending[e.unit] = pending_since
                    await self.app.alerts.push("critical", e.name, "перезапущен (ручной рестарт)")
                    self._event_count += 1
                # [ИСПРАВЛЕНО v2.1-38] (High): "failed" на двух опросах подряд при флаге -
                # реальное падение, а не промежуточное состояние рестарта.
                # [ИСПРАВЛЕНО v2.1-40]: см. комментарий в боте (рестарт уже упавшего сервиса).
                elif curr == "failed" and prev == "failed" and time.time() - pending_since > 5.0:
                    # [ИСПРАВЛЕНО v2.1-39]: то же - только локальная отметка, флаг в БД остаётся.
                    self._handled_pending[e.unit] = pending_since
                    await self.app.alerts.push("critical", e.name, f"УПАЛ ({st.sub})")
                    self._event_count += 1
                self._prev_states[e.unit] = curr
                self._prev_enter_ts[e.unit] = curr_enter_ts
                if curr == "active" and curr_enter_ts != 0:
                    self._last_active_enter_ts[e.unit] = curr_enter_ts
                continue

            if prev is None:
                # Первый опрос — показываем текущее проблемное состояние
                if curr == "failed":
                    await self.app.alerts.push("critical", e.name, f"УПАЛ ({st.sub})")
                    self._event_count += 1
                elif curr == "inactive":
                    await self.app.alerts.push("warn", e.name, "остановлен")
                    self._event_count += 1
            else:
                if curr == "failed" and prev != "failed":
                    await self.app.alerts.push("critical", e.name, f"УПАЛ ({st.sub})")
                    self._event_count += 1
                elif curr == "inactive" and prev not in ("inactive", "deactivating", None):
                    await self.app.alerts.push("warn", e.name, "остановлен")
                    self._event_count += 1
                elif curr == "deactivating" and prev not in ("deactivating", "inactive", "failed", None):
                    await self.app.alerts.push("warn", e.name, "остановлен")
                    self._event_count += 1
                elif curr == "active" and prev in ("failed", "inactive", "deactivating"):
                    await self.app.alerts.push("info", e.name, "восстановлен")
                    self._event_count += 1
                elif (curr == "active" and prev == "active"
                      and curr_enter_ts != 0 and prev_enter_ts != 0
                      and curr_enter_ts != prev_enter_ts):
                    # Быстрый ручной рестарт: enter_timestamp изменился
                    # FIX N-3: ранее TUI отправлял ДВА уведомления подряд —
                    # "перезапущен (ручной рестарт)" + "восстановлен". Бот
                    # отправляет одно: _send_restart_notice. Для синхронности
                    # оставляем только одно уведомление о рестарте.
                    await self.app.alerts.push("critical", e.name, "перезапущен (ручной рестарт)")
                    self._event_count += 1
                # FIX SLOW-RESTART-TUI: медленный рестарт через фазу activating.
                # Аналог FIX SLOW-RESTART-1 из бота. prev_enter_ts при activating=0,
                # поэтому используем last_active_ts из последнего активного состояния.
                elif curr == "active" and prev == "activating":
                    ts_changed = (curr_enter_ts != 0
                                  and last_active_ts != 0
                                  and curr_enter_ts != last_active_ts)
                    if ts_changed:
                        # FIX N-4: при медленном рестарте TUI тоже отправлял два
                        # уведомления (critical + info). Для синхронности с ботом
                        # (один _send_restart_notice) оставляем одно уведомление.
                        await self.app.alerts.push("critical", e.name, "перезапущен (ручной рестарт)")
                        self._event_count += 1
                    else:
                        # Первый запуск после стопа (enter_ts не изменился) —
                        # только recovery, без уведомления о рестарте
                        await self.app.alerts.push("info", e.name, "восстановлен")
                        self._event_count += 1

            self._prev_states[e.unit] = curr
            self._prev_enter_ts[e.unit] = curr_enter_ts
            # Обновляем last_active_enter_ts только в активном состоянии
            if curr == "active" and curr_enter_ts != 0:
                self._last_active_enter_ts[e.unit] = curr_enter_ts

        tbl.refresh_rows(rows, statuses, proc_metrics)
        self._update_info_panel(entries, statuses, proc_metrics)

        try:
            self.query_one(StatusBar).metrics = await self.app.metrics.host()
        except Exception:
            pass

    def _update_info_panel(self, entries, statuses, proc_metrics) -> None:
        try:
            panel = self.query_one(InfoPanel)
        except Exception:
            return
        # [ИСПРАВЛЕНО v2.2] при переподключении к уже работающей tmux-сессии
        # (после обрыва интернета/рестарта сервера) процесс InfoPanel не
        # пересоздаётся, поэтому "Сессия с ..." оставалась от первого
        # запуска. Подтягиваем реальное время attach из ATTACH_MARKER
        # (пишется в gopanel-attach) на каждом poll-цикле.
        try:
            mtime = ATTACH_MARKER.stat().st_mtime
            if mtime != self._last_attach_mtime:
                self._last_attach_mtime = mtime
                panel.set_started_at(datetime.fromtimestamp(mtime).strftime("%d.%m.%Y %H:%M:%S"))
        except OSError:
            pass
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
            if not self._modal_already_open():
                self.app.push_screen(ServiceFormScreen("add"), callback=lambda _: self._track(asyncio.create_task(self._refresh())))
        elif btn_id == "btn-edit":
            if sel:
                if not self._modal_already_open():
                    self.app.push_screen(ServiceFormScreen("edit", sel), callback=lambda _: self._track(asyncio.create_task(self._refresh())))
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
        elif btn_id == "btn-bot":
            self.app.switch_screen("bot")
        elif btn_id in ("btn-start", "btn-stop", "btn-restart"):
            act = {"btn-start": "start", "btn-stop": "stop", "btn-restart": "restart"}[btn_id]
            if sel:
                # FIX BG-TASKS: сохраняем ссылку через _track — иначе GC может
                # уничтожить задачу до завершения sudo systemctl (timeout 30s)
                self._track(asyncio.create_task(self._ctrl(act, sel)))
            else:
                self.app.throttled_notify("Выберите сервис (↑/↓)", severity="warning")
        elif btn_id == "btn-quit":
            self.app.exit()
        elif btn_id in ("dbtn-add", "dbtn-edit", "dbtn-del", "dbtn-start", "dbtn-stop", "dbtn-restart"):
            # [ФИЧА v2.1-4] Docker-кнопки работают с DockerTable, а не ServiceTable
            try:
                dtbl = self.query_one(DockerTable)
            except Exception:
                return
            dsel = dtbl.selected_name()
            if btn_id == "dbtn-add":
                if not self._modal_already_open():
                    self.app.push_screen(ContainerFormScreen("add"), callback=lambda _: self._track(asyncio.create_task(self._refresh())))
            elif btn_id == "dbtn-edit":
                if dsel:
                    if not self._modal_already_open():
                        self.app.push_screen(ContainerFormScreen("edit", dsel), callback=lambda _: self._track(asyncio.create_task(self._refresh())))
                else:
                    self.app.throttled_notify("Выберите контейнер (↑/↓)", severity="warning")
            elif btn_id == "dbtn-del":
                if dsel:
                    self._delete_container(dsel)
                else:
                    self.app.throttled_notify("Выберите контейнер (↑/↓)", severity="warning")
            else:
                act = {"dbtn-start": "start", "dbtn-stop": "stop", "dbtn-restart": "restart"}[btn_id]
                if dsel:
                    self._track(asyncio.create_task(self._docker_ctrl(act, dsel)))
                else:
                    self.app.throttled_notify("Выберите контейнер (↑/↓)", severity="warning")

    def on_docker_table_action(self, ev):
        # [ФИЧА v2.1-4] обработчик хоткеев DockerTable (a/e/d/s/x/ctrl+r),
        # зеркалит on_service_table_action
        if ev.act == "add":
            if not self._modal_already_open():
                self.app.push_screen(ContainerFormScreen("add"), callback=lambda _: self._track(asyncio.create_task(self._refresh())))
        elif ev.act == "edit" and ev.container:
            if not self._modal_already_open():
                self.app.push_screen(ContainerFormScreen("edit", ev.container), callback=lambda _: self._track(asyncio.create_task(self._refresh())))
        elif ev.act == "del" and ev.container:
            self._delete_container(ev.container)
        elif ev.act in ("start", "stop", "restart") and ev.container:
            self._track(asyncio.create_task(self._docker_ctrl(ev.act, ev.container)))
        elif ev.container is None and ev.act != "add":
            self.app.throttled_notify("Выберите контейнер (↑/↓)", severity="warning")

    def _delete_container(self, name):
        self._track(asyncio.create_task(self._delete_container_async(name)))

    async def _delete_container_async(self, name):
        try:
            await get_registry().delete_container(name)
            self.app.throttled_notify(f"Удалён контейнер: {name}", severity="warning")
        except Exception as e:
            log.warning("Failed to delete container %s: %s", name, e)
            self.app.throttled_notify(str(e), severity="error")
        await self._refresh()

    async def _docker_ctrl(self, act, name):
        c = get_registry().get_container(name)
        if not c:
            return
        ok, msg = await docker_control(act, c.name)
        act_ru = {"start": "СТАРТ", "stop": "СТОП", "restart": "РЕСТАРТ"}[act]
        self.app.throttled_notify(
            f"{act_ru} {name}: {'✓' if ok else '✗'} {msg[:80]}",
            severity="information" if ok else "error"
        )
        await asyncio.sleep(0.3)
        await self._refresh()

    def on_service_table_action(self, ev):
        if ev.act == "add":
            if not self._modal_already_open():
                self.app.push_screen(ServiceFormScreen("add"), callback=lambda _: self._track(asyncio.create_task(self._refresh())))
        elif ev.act == "edit" and ev.svc:
            if not self._modal_already_open():
                self.app.push_screen(ServiceFormScreen("edit", ev.svc), callback=lambda _: self._track(asyncio.create_task(self._refresh())))
        elif ev.act == "del" and ev.svc:
            self._delete(ev.svc)
        elif ev.act == "logs" and ev.svc:
            self.app._active_service = ev.svc
            self.app.switch_screen("logs")
        elif ev.act in {"start", "stop", "restart"} and ev.svc:
            # FIX BG-TASKS: сохраняем ссылку — hotkey-путь аналогичен кнопкам
            self._track(asyncio.create_task(self._ctrl(ev.act, ev.svc)))

    def _track(self, task: asyncio.Task) -> asyncio.Task:
        """Сохраняет strong reference на задачу; удаляет её при завершении.
        Без этого event loop держит только weak ref — при выходе из приложения
        незавершённые задачи дают RuntimeWarning и могут быть прерваны."""
        self._bg_tasks.add(task)
        def _done(t: asyncio.Task) -> None:
            self._bg_tasks.discard(t)
            # FIX TRACK-EXC: читаем исключение из завершённой задачи.
            # Без этого asyncio печатает "Task exception was never retrieved"
            # в stderr и исключение теряется — ошибки systemctl start/stop/restart
            # или _refresh() становились невидимы. Теперь они попадают в
            # gopanel.log с полным traceback'ом.
            if not t.cancelled():
                exc = t.exception()
                if exc is not None:
                    log.error(
                        "Background task %s failed: %s",
                        t.get_name(), exc,
                        exc_info=exc
                    )
        task.add_done_callback(_done)
        return task

    def _delete(self, name):
        # FIX BG-TASKS: сохраняем ссылку на задачу удаления
        self._track(asyncio.create_task(self._delete_async(name)))

    async def _delete_async(self, name):
        try:
            await get_registry().delete(name)
            self.app.throttled_notify(f"Удалён: {name}", severity="warning")
        except Exception as e:
            log.warning("Failed to delete service %s: %s", name, e)  # [ИСПРАВЛЕНО v2.6]
            self.app.throttled_notify(str(e), severity="error")
        await self._refresh()

    def _evict_last_control(self):
        now = time.monotonic()
        stale = [k for k, v in self._last_control.items() if now - v > 60.0]
        for k in stale:
            del self._last_control[k]
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
        if len(self._last_control) > _LAST_CONTROL_MAX:
            self._evict_last_control()
        e = get_registry().get(name)
        if not e:
            return
        if act == "restart":
            # [ИСПРАВЛЕНО v2.4] помечаем ДО вызова control(), чтобы _do_refresh
            # не успел поймать промежуточное inactive/deactivating как отдельное
            # событие "остановлен" ещё до того, как рестарт будет учтён
            if e.critical:
                # [ИСПРАВЛЕНО v2.5] флаг ставим только для critical — для
                # некритичных сервисов _do_refresh никогда не доходит до
                # чтения/очистки этого флага (критик-гейт раньше)
                # [ИСПРАВЛЕНО v2.1-10] флаг теперь в общей БД (виден боту)
                try:
                    await get_registry().mark_pending_restart(e.unit)
                except Exception:
                    pass
        else:
            # [ИСПРАВЛЕНО v2.5] явный stop/start отменяет ожидание предыдущего
            # рестарта этого же сервиса — иначе алерт "остановлен" откладывался
            # до истечения тайм-аута pending-флага
            try:
                await get_registry().clear_pending_restart(e.unit)
            except Exception:
                pass
        ok, msg = await control(act, e.unit)
        if not ok:
            # [ИСПРАВЛЕНО v2.5] control() не удался — снимаем флаг, иначе он до
            # 30с подавляет алерты о реальном падении сервиса
            try:
                await get_registry().clear_pending_restart(e.unit)
            except Exception:
                pass
        if ok and act == "restart":
            try:
                e.manual_restarts += 1
                await get_registry().update(e)
            except Exception as ex:
                log.warning("Failed to update manual_restarts for %s: %s", name, ex)
        act_ru = {"start": "СТАРТ", "stop": "СТОП", "restart": "РЕСТАРТ"}[act]
        self.app.throttled_notify(
            f"{act_ru} {name}: {'✓' if ok else '✗'} {msg[:80]}",
            severity="information" if ok else "error"
        )
        # Небольшая пауза чтобы systemd успел изменить состояние
        await asyncio.sleep(0.3)
        await self._refresh()
PY

write_file "$APP_DIR/src/gopanel/ui/screens/logs.py" <<'PY'
import asyncio
import collections
import logging
import re
import time
from pathlib import Path
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

# Параметры batch-записи в RichLog (защита от фризов UI при высоком потоке логов)
_BATCH_SIZE = 30        # строк до принудительного flush
_FLUSH_INTERVAL = 0.05  # секунд до принудительного flush
# Размер буфера для экспорта логов
_EXPORT_BUFFER_SIZE = 5000


class LogsScreen(Screen):
    BINDINGS = [("escape", "go_back", "Назад")]

    def __init__(self):
        super().__init__()
        self._task = None
        self._stop_event = asyncio.Event()
        self._current_service = None
        # FIX LOGS-SELF-CANCEL: отдельный атрибут для хранения задачи-запускателя
        # _start_logs. _start_logs сам управляет self._task (стрим-задача).
        # Нельзя хранить результат create_task(_start_logs) в self._task — это
        # вызывало self-cancellation: _start_logs проверяет self._task в начале
        # и отменял бы сам себя.
        self._launcher_task: asyncio.Task | None = None
        # Флаг автопрокрутки — отключается кнопкой "⬆ В начало"
        # чтобы пользователь мог читать старые записи без "выброса" вниз
        self._auto_scroll: bool = True
        # FIX B5: флаг запроса сброса pending batch при очистке экрана.
        # Устанавливается в btn-clear, сбрасывается в _flush после дропа батча.
        self._clear_pending: bool = False
        # FIX ST-5: флаг защиты от параллельных вызовов _load_more_history.
        # Без него быстрые нажатия «+200 строк» запускали параллельные tail()
        # процессы — строки писались в RichLog вперемешку (interleaved output).
        self._loading_history: bool = False
        # Буфер последних строк лога для функции экспорта в файл.
        # Не используем lv.lines (непубличный API Textual) — храним сами.
        # deque(maxlen) вместо list: O(1) append+eviction vs O(n) list.pop(0)
        # при высоком потоке логов.
        self._log_buffer: collections.deque[str] = collections.deque(maxlen=_EXPORT_BUFFER_SIZE)

    def compose(self):
        yield Static("[bold #00ffaa]Центр мониторинга и управления сервисами[/]", id="log-title")  # [ФИЧА v2.1-6]
        yield Static(f"v{__version__}", classes="version-subtitle")
        with Vertical():
            with Horizontal(id="logs-actions"):
                yield Button("← Назад на панель", id="btn-back", variant="default")
                yield Button("⬆ В начало", id="btn-scroll-top", variant="default")
                yield Button("⬇ В конец", id="btn-scroll-bottom", variant="default")
                yield Button("📜 +200 строк", id="btn-load-more", variant="default")
                yield Button("💾 Экспорт", id="btn-export", variant="default")
                yield Button("🔄 Перезагрузить", id="btn-reload", variant="default")
                yield Button("🗑 Очистить экран", id="btn-clear", variant="default")
            # Увеличен max_lines: 2000→5000. При throttle 100 строк/сек
            # это ~50 секунд прокручиваемой истории вместо ~20 секунд.
            yield RichLog(id="lv", wrap=True, highlight=True, auto_scroll=True, max_lines=5000, markup=True)
        yield StatusBar()
        yield Footer()

    async def on_mount(self):
        self._stop_event = asyncio.Event()
        self._task = None
        self._launcher_task = None
        self._current_service = None
        self._auto_scroll = True
        self._clear_pending = False
        self._loading_history = False
        self._log_buffer = collections.deque(maxlen=_EXPORT_BUFFER_SIZE)

    async def on_screen_resume(self):
        target = getattr(self.app, "_active_service", None)
        if target and target != self._current_service:
            # FIX LOGS-TASK-1 + FIX LOGS-SELF-CANCEL:
            # Храним задачу-запускатель в self._launcher_task, НЕ в self._task.
            # self._task используется внутри _start_logs для управления стримом.
            # Если бы мы писали self._task = create_task(_start_logs(...)),
            # то _start_logs при старте видел бы self._task = себя (not done)
            # и немедленно отменял бы сам себя — логи никогда не запускались.
            self._launcher_task = asyncio.create_task(self._start_logs(target))

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
                self._log_buffer.clear()
                # FIX B5: при очистке экрана pending batch в _stream_logs
                # (локальная переменная) не очищался. Через 50мс _flush()
                # записывал накопленные строки в только что очищенный RichLog.
                # Устанавливаем флаг — _flush() проверит его и сбросит батч
                # без записи в RichLog.
                self._clear_pending = True
                lv.write("[cyan]→ Экран очищен[/cyan]")
            except Exception:
                pass
        elif ev.button.id == "btn-scroll-top":
            # FIX M-3: _scroll_to_top содержит только синхронные Textual вызовы.
            # Ранее create_task создавал лишнюю задачу в event loop — overhead
            # без пользы. Вызываем методы напрямую без create_task.
            try:
                lv = self.query_one("#lv", RichLog)
                lv.scroll_home(animate=False)
                self._auto_scroll = False
                self.app.throttled_notify("⬆ Прокручено в начало (автопрокрутка отключена)", severity="information")
            except Exception:
                pass
        elif ev.button.id == "btn-scroll-bottom":
            # FIX M-3: аналогично btn-scroll-top
            try:
                lv = self.query_one("#lv", RichLog)
                lv.scroll_end(animate=False)
                self._auto_scroll = True
                self.app.throttled_notify("⬇ Прокручено в конец (автопрокрутка включена)", severity="information")
            except Exception:
                pass
        elif ev.button.id == "btn-load-more":
            # FIX ST-5: проверяем флаг перед запуском — предотвращаем
            # параллельные вызовы _load_more_history при быстрых нажатиях.
            # Флаг устанавливается ЗДЕСЬ (до create_task), а не внутри
            # корутины — иначе между create_task и первой строкой корутины
            # event loop мог обработать второе нажатие и запустить дубль.
            if self._loading_history:
                self.app.throttled_notify("⏳ Загрузка уже выполняется...", severity="warning")
            else:
                self._loading_history = True
                asyncio.create_task(self._load_more_history())
        elif ev.button.id == "btn-export":
            asyncio.create_task(self._export_logs())

    async def _scroll_to_top(self):
        """Прокручивает лог в начало и отключает автопрокрутку."""
        try:
            lv = self.query_one("#lv", RichLog)
            lv.scroll_home(animate=False)
            self._auto_scroll = False
            self.app.throttled_notify("⬆ Прокручено в начало (автопрокрутка отключена)", severity="information")
        except Exception:
            pass

    async def _scroll_to_bottom(self):
        """Прокручивает лог в конец и включает автопрокрутку."""
        try:
            lv = self.query_one("#lv", RichLog)
            lv.scroll_end(animate=False)
            self._auto_scroll = True
            self.app.throttled_notify("⬇ Прокручено в конец (автопрокрутка включена)", severity="information")
        except Exception:
            pass

    async def _load_more_history(self):
        """Подгружает последние 200 строк из journalctl и добавляет на экран.
        # [ИСПРАВЛЕНО v2.3] было 500 — не совпадало с меткой кнопки "+200 строк"
        # и отчёт "Загружено N строк" показывал фактически доступное количество
        # (могло быть меньше 500), что выглядело как случайное число.

        Внимание: RichLog.write() всегда добавляет строки в КОНЕЦ виджета.
        Textual 0.67 не поддерживает prepend. История добавляется ПОСЛЕ
        текущих записей стрима с явным разделителем чтобы пользователь
        понимал хронологический порядок.
        """
        # FIX ST-5: флаг _loading_history уже установлен в on_button_pressed
        # ДО create_task — это устраняет race condition когда второе нажатие
        # проходило проверку до старта первой корутины. Сбрасываем в finally.
        try:
            await self._do_load_more_history()
        finally:
            self._loading_history = False

    async def _do_load_more_history(self):
        if not self._current_service:
            return
        entry = get_registry().get(self._current_service)
        if not entry:
            return
        try:
            lv = self.query_one("#lv", RichLog)
        except Exception:
            return
        lv.write("[cyan]⏳ Загрузка дополнительных строк...[/cyan]")
        try:
            raw = await tail(entry.unit, 200)  # [ИСПРАВЛЕНО v2.3] было 500
            if raw and not raw.startswith("[error"):
                lines = [l for l in raw.splitlines() if l.strip()]
                # FIX H-3: добавляем явный разделитель чтобы пользователь
                # понимал: строки ниже — это ИСТОРИЯ (старше текущего стрима),
                # а не продолжение. RichLog не поддерживает prepend в Textual 0.67.
                lv.write("[dim cyan]─── ↑ ИСТОРИЯ (200 строк, старше текущего стрима) ↑ ───[/dim cyan]")
                for line in lines:
                    color = self._colorize_line(line)
                    lv.write(f"[dim][{color}]{escape(line)}[/{color}][/dim]")
                lv.write("[dim cyan]─── ↑ конец истории ───[/dim cyan]")
                # FIX L-2: добавляем загруженные строки в _log_buffer чтобы
                # экспорт включал историю, загруженную кнопкой «+200 строк».
                for line in lines:
                    self._log_buffer.append(line)
                self.app.throttled_notify(
                    f"✓ Загружено {len(lines)} строк истории",
                    severity="information"
                )
            else:
                self.app.throttled_notify("Нет строк в журнале", severity="warning")
        except Exception as e:
            self.app.throttled_notify(f"Ошибка загрузки: {e}", severity="error")

    async def _export_logs(self):
        """Сохраняет содержимое _log_buffer в файл /var/log/gopanel/exports/."""
        if not self._log_buffer:
            self.app.throttled_notify("Нет логов для экспорта", severity="warning")
            return
        export_dir = Path("/var/log/gopanel/exports")
        try:
            export_dir.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            self.app.throttled_notify(f"Не удалось создать директорию: {e}", severity="error")
            return
        timestamp = int(time.time())
        safe_name = re.sub(r'[^a-zA-Z0-9_.\-]', '_', self._current_service or "unknown")
        filename = export_dir / f"{safe_name}_logs_{timestamp}.txt"
        # Копируем буфер в список до передачи в поток —
        # deque может изменяться в event loop пока поток пишет
        lines_snapshot = list(self._log_buffer)
        try:
            # FIX H-1: ранее open/write вызывались напрямую в async def —
            # синхронный I/O блокировал event loop Textual на 50-500ms при
            # записи 5000 строк (~1MB). TUI зависал: кнопки не реагировали.
            # Исправление: выносим запись в thread pool через asyncio.to_thread.
            await asyncio.to_thread(self._do_export_sync, filename, lines_snapshot)
            self.app.throttled_notify(f"✓ Сохранено: {filename}", severity="information")
            # FIX L-3: убран захардкоженный user@server — пользователь должен
            # знать свой IP/hostname сам. Даём универсальную инструкцию.
            self.app.throttled_notify(
                f"📥 Файл: {filename}  (скачайте через scp или sftp)",
                severity="information"
            )
        except Exception as e:
            self.app.throttled_notify(f"Ошибка экспорта: {e}", severity="error")

    def _do_export_sync(self, filename: Path, lines: list[str]) -> None:
        """Синхронная запись лога в файл — вызывать только через asyncio.to_thread."""
        with open(filename, "w", encoding="utf-8") as f:
            for line in lines:
                f.write(line + "\n")

    async def _reload_current(self):
        if self._current_service:
            # FIX LOGS-TASK-2 + FIX LOGS-SELF-CANCEL: аналогично on_screen_resume —
            # используем _launcher_task, не self._task, чтобы не вызвать
            # self-cancellation внутри _start_logs.
            self._launcher_task = asyncio.create_task(self._start_logs(self._current_service))
        else:
            try:
                self.query_one("#lv", RichLog).write("[yellow]⚠ Сервис не выбран[/yellow]")
            except Exception:
                pass

    def _colorize_line(self, line: str) -> str:
        """Определяет цвет строки лога по уровню.

        Вынесено в отдельный метод для повторного использования
        в _stream_logs и _load_more_history.
        """
        # Внутренние ошибки GoPanel — красным
        if line.startswith("[error:"):
            return "red"
        upper = line.upper()
        # Приоритет: ERROR/FATAL/CRIT > WARN > DEBUG/TRACE > ключевые слова
        if any(w in upper for w in ("ERROR", "FATAL", "CRIT", "EMERG", "ALERT")):
            return "#ff3366"
        if "WARN" in upper:
            return "#ffaa00"
        if "DEBUG" in upper:
            return "#6b7280"
        if "TRACE" in upper:
            return "#4b5563"
        # Дополнительные ключевые слова в нижнем регистре
        lower = line.lower()
        if any(w in lower for w in ("exception", "traceback", "failed", "denied", "refused")):
            return "#ff3366"
        return "white"

    async def _start_logs(self, name: str):
        if self._task and not self._task.done():
            self._stop_event.set()
            self._task.cancel()
            try:
                await asyncio.wait_for(self._task, timeout=1.0)
            except (asyncio.CancelledError, asyncio.TimeoutError):
                pass

        self._current_service = name
        self._stop_event = asyncio.Event()
        self._log_buffer.clear()
        self._auto_scroll = True

        try:
            lv = self.query_one("#lv", RichLog)
        except Exception:
            return

        lv.clear()
        lv.write(f"[cyan]📋 Журнал сервиса [bold]{escape(name)}[/bold][/cyan]")
        lv.write("[dim]⏳ Подключение к journalctl...[/dim]")

        entry = get_registry().get(name)
        if not entry:
            lv.write("[red]Сервис не найден в реестре[/red]")
            return

        try:
            # 1.1: увеличено с 5 до 200 строк для полноценного контекста диагностики
            init = await tail(entry.unit, 200)
        except Exception as ex:
            lv.write(f"[red]Ошибка: {escape(str(ex))}[/red]")
            return

        if "[error:" in init:
            lv.write(f"[red]{escape(init)}[/red]")
            return

        init_lines = [l for l in init.splitlines() if l.strip()]
        for line in init_lines:
            color = self._colorize_line(line)
            lv.write(f"[dim][{color}]{escape(line)}[/{color}][/dim]")
            self._log_buffer.append(line)

        lv.write(f"[green]✓ Подключено. Загружено {len(init_lines)} строк истории.[/green]")
        lv.write("[cyan]─── ▶ Получаю новые записи в реальном времени ───[/cyan]\n")
        # Используем retry-wrapper для надёжности при обрывах стрима
        self._task = asyncio.create_task(self._stream_logs_with_retry(entry.unit, lv))

    async def _stream_logs_with_retry(self, unit, lv):
        """Wrapper с retry-логикой вокруг _stream_logs.

        При обрыве journalctl (перезапуск systemd, временный сбой)
        автоматически повторяет подключение с экспоненциальной задержкой.
        """
        max_retries = 5
        for attempt in range(max_retries):
            if self._stop_event.is_set():
                return
            try:
                await self._stream_logs(unit, lv)
                # _stream_logs вернулся без исключения — штатное завершение
                # (stop_event установлен или LT-3 перезапуск уже запланирован)
                return
            except asyncio.CancelledError:
                raise
            except Exception as e:
                if attempt < max_retries - 1 and not self._stop_event.is_set():
                    wait = min(2 ** attempt, 10)
                    # [ИСПРАВЛЕНО v2.6] обрыв стрима logs раньше был виден только
                    # в UI и исчезал бесследно — теперь фиксируется в логе
                    log.warning("Log stream for %s lost (attempt %d/%d): %s", unit, attempt + 1, max_retries, e)
                    try:
                        lv.write(f"[yellow]⚠ Потеря соединения. Повтор через {wait}с...[/yellow]")
                    except Exception:
                        pass
                    await asyncio.sleep(wait)
                else:
                    log.warning("Log stream for %s failed after %d attempts: %s", unit, max_retries, e)  # [ИСПРАВЛЕНО v2.6]
                    try:
                        lv.write(
                            f"[red]❌ Не удалось восстановить соединение "
                            f"после {max_retries} попыток: {escape(str(e))}[/red]"
                        )
                    except Exception:
                        pass
                    return

    async def _stream_logs(self, unit, lv):
        """Стримит логи с batch-записью для предотвращения фризов UI.

        Без батчинга каждый lv.write() вызывает перерисовку Textual.
        При 500+ строк/сек это замораживает TUI на секунды.
        Батчинг: flush каждые 50мс ИЛИ каждые 30 строк.
        """
        batch: list[str] = []
        last_flush = time.monotonic()

        async def _flush(force: bool = False):
            nonlocal last_flush
            # [ИСПРАВЛЕНО v2.1-34] "if not batch: return" раньше стояла ПЕРЕД
            # проверкой _clear_pending — если "Очистить экран" нажали в момент,
            # когда batch уже пуст (типичный случай, очистка обычно не совпадает
            # с активным потоком строк), _flush() выходил здесь и НИКОГДА не
            # снимал _clear_pending. Следующая же пачка НОВЫХ строк (уже после
            # очистки) молча отбрасывалась следующим вызовом _flush(), т.к. флаг
            # оставался истинным. Проверяем _clear_pending первой.
            if self._clear_pending:
                batch.clear()
                self._clear_pending = False
                last_flush = time.monotonic()
                return
            if not batch:
                return
            # FIX B5: если пользователь нажал "🗑 Очистить экран" пока
            # батч накапливался — сбрасываем батч без записи в RichLog.
            # Без этой проверки накопленные строки записывались в уже
            # очищенный виджет через 50мс после нажатия кнопки.
            now = time.monotonic()
            if force or len(batch) >= _BATCH_SIZE or (now - last_flush) >= _FLUSH_INTERVAL:
                for item in batch:
                    lv.write(item)
                if self._auto_scroll:
                    lv.scroll_end(animate=False)
                batch.clear()
                last_flush = now

        try:
            async for line in follow(unit, stop_event=self._stop_event):
                if self._stop_event.is_set():
                    return
                # Буферизуем для экспорта — deque(maxlen) автоматически
                # вытесняет старые строки без явного pop(0)
                self._log_buffer.append(line)
                color = self._colorize_line(line)
                batch.append(f"[{color}]{escape(line)}[/{color}]")
                # FIX B4: если journalctl вернул строку-ошибку (нет прав,
                # юнит не найден и т.д.), follow() завершается нормально —
                # без исключения. _stream_logs_with_retry считал это штатным
                # завершением и не делал retry. Пользователь видел одну строку
                # [error: ...] и застывший экран навсегда.
                # Исправление: при получении [error:-строки делаем flush,
                # чтобы ошибка отобразилась, и поднимаем исключение —
                # это запустит retry-логику в _stream_logs_with_retry.
                if line.startswith("[error:"):
                    await _flush(force=True)
                    raise RuntimeError(f"journalctl error: {line}")
                await _flush()

            # Финальный flush остатка батча
            await _flush(force=True)

            # FIX LT-3: follow() вышел штатно — это происходит после истечения
            # MAX_FOLLOW_SECONDS (1 час). Ранее стрим молча останавливался:
            # RichLog застывал без каких-либо признаков, пользователь не понимал
            # что логи перестали обновляться.
            # Исправление: если stop_event не установлен (то есть пользователь
            # не переключился и не закрыл экран), показываем сообщение и
            # автоматически перезапускаем стрим. Используем _launcher_task
            # (не self._task) чтобы избежать self-cancellation в _start_logs.
            if not self._stop_event.is_set() and self._current_service:
                try:
                    lv.write(
                        "[dim cyan]─── ↻ Стрим завершён (достигнут лимит сессии 1ч). "
                        "Перезапуск... ───[/dim cyan]"
                    )
                except Exception:
                    pass
                # FIX M-2: обнуляем self._task ДО создания _launcher_task.
                # Race condition: _stream_logs_with_retry ещё не вернулся
                # (self._task.done() == False) в момент когда _start_logs
                # начинает выполняться и проверяет self._task. Без обнуления
                # _start_logs мог попытаться отменить _stream_logs_with_retry
                # что привело бы к двойному рестарту или отмене нового стрима.
                self._task = None
                self._launcher_task = asyncio.create_task(
                    self._start_logs(self._current_service)
                )
        except asyncio.CancelledError:
            await _flush(force=True)
            raise
        except Exception as e:
            await _flush(force=True)
            try:
                lv.write(f"[red]Ошибка стрима: {escape(str(e))}[/red]")
            except Exception:
                pass
            raise
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

    # FIX C-4: Метод должен быть async, так как reg.add() и reg.update() —
    # это async def (они вызывают await self._flush_async() внутри).
    # Без async/await вызов возвращал coroutine-объект, который никогда
    # не выполнялся: сервис не добавлялся, файл не записывался.
    # Textual 0.67.1 полностью поддерживает async event handlers.
    async def on_button_pressed(self, ev):
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

        # [ИСПРАВЛЕНО v2.1] manual_restarts не переносился из существующей записи
        # при сохранении формы редактирования и всегда обнулялся (Field default=0),
        # т.к. `e` из compose() недоступна здесь. Перечитываем текущую запись
        # реестра, чтобы сохранить её manual_restarts при mode == "edit".
        # [ИСПРАВЛЕНО v2.1-32] конструирование ServiceEntry раньше было ВНЕ
        # try/except — если group (max_length=32) или description
        # (max_length=256) превышали лимит Pydantic-модели, ValidationError
        # был необработанным и ронял всё приложение Textual (silent crash,
        # см. Textualize/textual issue #2027 — необработанное исключение в
        # обработчике события валит весь TUI, не только текущий экран).
        try:
            _existing = get_registry().get(self._name) if self.mode == "edit" and self._name else None
            entry = ServiceEntry(
                name=n,
                unit=u,
                group=self.query_one("#fg", Input).value.strip() or "default",
                description=self.query_one("#fd", Input).value.strip(),
                critical=self.query_one("#fc", Switch).value,
                tags=[],
                manual_restarts=_existing.manual_restarts if _existing else 0
            )
        except Exception as ex:
            self.notify(str(ex), severity="error")
            return
        reg = get_registry()
        try:
            if self.mode == "add":
                # FIX C-4: await обязателен — reg.add() async, без него
                # coroutine создаётся но не запускается (RuntimeWarning + потеря данных)
                await reg.add(entry)
            else:
                # FIX C-4: аналогично для update
                await reg.update(entry)
        except Exception as ex:
            self.notify(str(ex), severity="error")
            return
        self.dismiss(True)

    def action_cancel(self):
        self.dismiss(False)
PY

write_file "$APP_DIR/src/gopanel/ui/screens/container_form.py" <<'PY'
# [ФИЧА v2.1-4] Форма добавления/редактирования Docker-контейнера — зеркалит
# service_form.py (та же структура, тот же паттерн FIX C-4: async кнопка,
# перенос данных из существующей записи при edit), но для DockerEntry.
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Footer, Input, Label, Switch, Static
from ...registry import DockerEntry, get_registry
from ...utils import is_safe_name


class ContainerFormScreen(ModalScreen[bool]):
    BINDINGS = [("escape", "cancel", "Отмена")]

    def __init__(self, mode, name=None):
        super().__init__()
        self.mode = mode
        self._name = name

    def compose(self):
        c = get_registry().get_container(self._name) if self._name and self.mode == "edit" else None
        t = "✏ Редактирование контейнера" if self.mode == "edit" else "➕ Добавление Docker-контейнера"
        with Vertical(id="form"):
            yield Static(t)
            yield Label("Имя контейнера (только латиница, цифры, _.-):")
            yield Input(value=c.name if c else "", placeholder="redis-1", id="cn", disabled=self.mode == "edit")
            yield Label("Образ (например redis:7-alpine):")
            yield Input(value=c.image if c else "", placeholder="redis:7-alpine", id="ci")
            yield Label("Группа:")
            yield Input(value=c.group if c else "default", id="cg")
            yield Label("Описание (можно кириллицей):")
            yield Input(value=c.description if c else "", id="cd")
            yield Label("Критический (уведомления при падении):")
            yield Switch(value=c.critical if c else False, id="cc")
            yield Button("💾 Сохранить", id="save", variant="primary")
            yield Button("❌ Отмена", id="cancel")
        yield Footer()

    async def on_button_pressed(self, ev):
        if ev.button.id == "cancel":
            self.dismiss(False)
            return
        try:
            n = self.query_one("#cn", Input).value.strip()
            img = self.query_one("#ci", Input).value.strip()
        except Exception:
            self.notify("Ошибка формы", severity="error")
            return

        if not n:
            self.notify("❌ Заполните поле «Имя»", severity="error")
            return
        if not is_safe_name(n):
            self.notify(f"❌ Имя «{n}» недопустимо: только латиница, цифры, _.-", severity="error")
            return
        if not img:
            self.notify("❌ Заполните поле «Образ»", severity="error")
            return

        # [ИСПРАВЛЕНО v2.1-32] см. тот же фикс в service_form.py — конструирование
        # DockerEntry было вне try/except, превышение max_length у group/description
        # роняло весь TUI необработанным ValidationError.
        try:
            entry = DockerEntry(
                name=n,
                image=img,
                group=self.query_one("#cg", Input).value.strip() or "default",
                description=self.query_one("#cd", Input).value.strip(),
                critical=self.query_one("#cc", Switch).value,
                tags=[],
            )
        except Exception as ex:
            self.notify(str(ex), severity="error")
            return
        reg = get_registry()
        try:
            if self.mode == "add":
                await reg.add_container(entry)
            else:
                await reg.update_container(entry)
        except Exception as ex:
            self.notify(str(ex), severity="error")
            return
        self.dismiss(True)

    def action_cancel(self):
        self.dismiss(False)
PY

# ======================== PYTHON SOURCE — БОТ ========================

write_file "$APP_DIR/src/gopanel/bot/__init__.py" <<'PY'
"""GoPanel Telegram Bot"""
__version__ = "2.1"
PY

write_file "$APP_DIR/src/gopanel/bot/config.py" <<'PY'
"""Конфигурация Telegram-бота"""
from __future__ import annotations
import json
import logging
from pathlib import Path
from typing import Optional

log = logging.getLogger("gopanel.bot.config")

class BotConfig:
    def __init__(self, config_path: Optional[Path] = None):
        self.config_path = config_path or Path("/etc/gopanel/bot.json")
        self.telegram_token: str = ""
        self.authorized_users: list[int] = []
        self.enable_alerts: bool = True
        self.status_cache_ttl_sec: int = 5
        self.max_log_lines: int = 50
        self.pagination_threshold: int = 10
        self.log_level: str = "INFO"
        self.load()

    def load(self):
        if not self.config_path.exists():
            log.warning("Config file %s not found, using defaults", self.config_path)
            return
        try:
            with open(self.config_path, encoding="utf-8") as f:
                data = json.load(f)
            self.telegram_token = data.get("telegram_token", "")
            self.authorized_users = data.get("authorized_users", [])
            self.enable_alerts = data.get("enable_alerts", True)
            self.status_cache_ttl_sec = data.get("status_cache_ttl_sec", 5)
            self.max_log_lines = data.get("max_log_lines", 50)
            self.pagination_threshold = data.get("pagination_threshold", 10)
            self.log_level = data.get("log_level", "INFO")
            log.info("Config loaded from %s", self.config_path)
        except Exception as e:
            log.error("Failed to load config: %s", e)

    def save(self):
        raise NotImplementedError(
            "Direct config save not supported. "
            "Use 'sudo /usr/local/bin/gopanel-save-bot-config' wrapper."
        )

    def validate(self) -> bool:
        if not self.telegram_token or self.telegram_token == "YOUR_BOT_TOKEN_HERE":
            log.error("telegram_token not configured")
            return False
        if not self.authorized_users:
            log.error("authorized_users is empty")
            return False
        return True

config = BotConfig()
PY

write_file "$APP_DIR/src/gopanel/bot/cache.py" <<'PY'
"""Кэширование статусов сервисов"""
from __future__ import annotations
import time
import asyncio
from ..systemd import batch_show, UnitStatus
from .config import config

class StatusCache:
    def __init__(self):
        self._cache: dict[str, UnitStatus] = {}
        self._timestamp: float = 0
        self._lock: asyncio.Lock | None = None
        # FIX CACHE-2: добавляем per-key временные метки для корректной
        # очистки устаревших записей. Глобальный self._timestamp обновляется
        # при каждом запросе и не отражает когда КОНКРЕТНЫЙ ключ обновлялся.
        # При первом вызове (self._timestamp=0) условие now-0 > threshold
        # немедленно удаляло все ключи не из текущего запроса —
        # воспроизводя оригинальный баг cache-перезаписи.
        self._key_timestamps: dict[str, float] = {}

    def _get_lock(self) -> asyncio.Lock:
        if self._lock is None:
            self._lock = asyncio.Lock()
        return self._lock

    async def get_statuses(self, units: list[str]) -> dict[str, UnitStatus]:
        async with self._get_lock():
            now = time.time()
            # [ИСПРАВЛЕНО v2.1-35] свежесть проверялась по глобальному
            # self._timestamp (обновляется на КАЖДЫЙ вызов) — частые запросы
            # к одним юнитам (AlertMonitor опрашивает critical каждые 5с)
            # держали self._timestamp свежим, из-за чего юнит, давно не
            # запрашивавшийся напрямую, мог отдаваться из кэша как "свежий"
            # при редком запросе (например, /status для всех сервисов).
            # Проверяем свежесть КАЖДОГО запрошенного юнита по его собственной
            # записи в _key_timestamps, не по общей метке.
            stale_or_missing = [
                u for u in units
                if u not in self._cache
                or now - self._key_timestamps.get(u, 0) >= config.status_cache_ttl_sec
            ]
            if not stale_or_missing:
                return {u: self._cache[u] for u in units if u in self._cache}
            new_statuses = await batch_show(units)
            # FIX CACHE-1: ранее здесь стояло:
            #   self._cache = {k: v for k, v in self._cache.items() if k in units}
            # Это перезаписывало весь кэш, оставляя только юниты текущего запроса.
            # При смешанных запросах (AlertMonitor запрашивает 5 critical-сервисов,
            # бот запрашивает все 15) каждый запрос сокращал кэш до своего subset'а.
            # Следующий запрос снова видел "missing_units" и снова делал batch_show.
            # Кэш был полностью неэффективен при параллельном использовании бота и
            # AlertMonitor'а.
            #
            # Правильная логика: обновляем только то что запросили, НЕ трогаем
            # остальное. Дополнительно чистим записи по per-key временным меткам
            # (FIX CACHE-2) — удаляем только ключи не обновлявшиеся дольше TTL*10.
            stale_threshold = config.status_cache_ttl_sec * 10
            for k in list(self._cache.keys()):
                key_age = now - self._key_timestamps.get(k, 0)
                if k not in units and key_age > stale_threshold:
                    # Удаляем запись только если она давно не обновлялась
                    # (т.е. сервис, скорее всего, удалён из реестра)
                    del self._cache[k]
                    self._key_timestamps.pop(k, None)
            self._cache.update(new_statuses)
            # Обновляем временные метки для всех только что полученных ключей
            for k in new_statuses:
                self._key_timestamps[k] = now
            self._timestamp = now
            return {u: self._cache[u] for u in units if u in self._cache}

status_cache = StatusCache()
PY

write_file "$APP_DIR/src/gopanel/bot/auth.py" <<'PY'
"""Авторизация пользователей"""
from __future__ import annotations
import logging
from aiogram import types
from .config import config

log = logging.getLogger("gopanel.bot.auth")

async def check_authorization(message: types.Message) -> bool:
    # [ИСПРАВЛЕНО v2.1-22] chat.type не проверялся — авторизованный пользователь
    # мог вызвать команды бота в групповом чате, и статусы/логи/PID сервисов
    # уходили бы в группу, видимую остальным участникам. Админ-команды — только
    # в private chat, без ответа в остальных типах чатов (чтобы не палить сам
    # факт наличия бота другим участникам группы).
    if message.chat.type != "private":
        return False
    user_id = message.from_user.id
    if user_id not in config.authorized_users:
        await message.reply("⛔ Доступ запрещён")
        log.warning("Unauthorized access attempt from user %d", user_id)
        return False
    log.info("User %d authorized", user_id)
    return True

async def check_callback_authorization(callback: types.CallbackQuery) -> bool:
    # [ИСПРАВЛЕНО v2.1-22] см. check_authorization выше — та же причина.
    if callback.message is None or callback.message.chat.type != "private":
        return False
    user_id = callback.from_user.id
    if user_id not in config.authorized_users:
        await callback.answer("⛔ Доступ запрещён", show_alert=True)
        log.warning("Unauthorized callback from user %d", user_id)
        return False
    return True
PY

write_file "$APP_DIR/src/gopanel/bot/keyboards.py" <<'PY'
"""Создание inline-клавиатур"""
from __future__ import annotations
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton
# [ИСПРАВЛЕНО v2.1-22] для встраивания отпечатка реестра в callback_data —
# см. Registry.fingerprint() и проверку в bot/handlers/callbacks.py.
from ..registry import get_registry

def _truncate_utf8(s: str, max_bytes: int) -> str:
    encoded = s.encode("utf-8")
    if len(encoded) <= max_bytes:
        return s
    # FIX UTF8-1: простое encoded[:max_bytes].decode(errors="ignore") режет
    # многобайтовые символы (кириллица = 2 байта) пополам. decode(errors="ignore")
    # молча выбрасывает осиротевший байт — последний символ имени исчезает.
    # Для callback_data это критично: имя в кнопке не совпадёт с ключом реестра,
    # нажатие кнопки вернёт "сервис не найден".
    # Правильный алгоритм: откатываемся назад от точки обрезки, пока не окажемся
    # на границе UTF-8 символа (continuation bytes имеют маску 0b10xxxxxx = 0x80).
    truncated = bytearray(encoded[:max_bytes])
    # Убираем хвостовые continuation bytes (0x80-0xBF)
    while truncated and (truncated[-1] & 0xC0) == 0x80:
        truncated.pop()
    # Если остался одиночный leading byte многобайтового символа — убираем и его
    if truncated and (truncated[-1] & 0x80) != 0 and (truncated[-1] & 0xC0) != 0xC0:
        truncated.pop()
    return bytes(truncated).decode("utf-8", errors="ignore")

def create_service_keyboard(service_name: str) -> InlineKeyboardMarkup:
    """Полная клавиатура управления сервисом — для уведомлений и инфо."""
    # [ИСПРАВЛЕНО v2.1-22, доп. правка] 48 + ":"+fp(6) с длинными префиксами
    # ("confirm_restart:") превышало лимит callback_data в 64 байта. Реальные
    # имена сервисов ограничены 32 байтами (NAME_RE), 48 было запасом с нуля.
    MAX_NAME = 32
    safe = _truncate_utf8(service_name, MAX_NAME)
    # [ИСПРАВЛЕНО v2.1-22] отпечаток текущего реестра — обработчик start/stop/
    # restart сверяет его перед выполнением действия (см. registry.fingerprint()).
    fp = get_registry().fingerprint()
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="▶ Запуск", callback_data=f"start:{safe}:{fp}", style="success"),
            InlineKeyboardButton(text="⏹ Стоп", callback_data=f"stop:{safe}:{fp}", style="danger"),
            InlineKeyboardButton(text="🔄 Рестарт", callback_data=f"restart:{safe}:{fp}", style="primary"),
        ],
        [
            InlineKeyboardButton(text="📜 Логи", callback_data=f"logs:{safe}"),
            InlineKeyboardButton(text="ℹ️ Инфо", callback_data=f"info:{safe}"),
        ]
    ])

def create_alert_keyboard(service_name: str) -> InlineKeyboardMarkup:
    """Клавиатура для уведомления о ПАДЕНИИ: без кнопки Стоп."""
    # [ИСПРАВЛЕНО v2.1-22, доп. правка] см. create_service_keyboard выше.
    MAX_NAME = 32
    safe = _truncate_utf8(service_name, MAX_NAME)
    # [ИСПРАВЛЕНО v2.1-22] см. create_service_keyboard выше.
    fp = get_registry().fingerprint()
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="▶ Запуск", callback_data=f"start:{safe}:{fp}", style="success"),
            InlineKeyboardButton(text="🔄 Рестарт", callback_data=f"restart:{safe}:{fp}", style="primary"),
        ],
        [
            InlineKeyboardButton(text="📜 Логи", callback_data=f"logs:{safe}"),
            InlineKeyboardButton(text="ℹ️ Инфо", callback_data=f"info:{safe}"),
        ]
    ])

def create_recovery_keyboard(service_name: str) -> InlineKeyboardMarkup:
    """Клавиатура для уведомления о ВОССТАНОВЛЕНИИ: без кнопки Запуск."""
    # [ИСПРАВЛЕНО v2.1-22, доп. правка] см. create_service_keyboard выше.
    MAX_NAME = 32
    safe = _truncate_utf8(service_name, MAX_NAME)
    # [ИСПРАВЛЕНО v2.1-22] см. create_service_keyboard выше.
    fp = get_registry().fingerprint()
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="⏹ Стоп", callback_data=f"stop:{safe}:{fp}", style="danger"),
            InlineKeyboardButton(text="🔄 Рестарт", callback_data=f"restart:{safe}:{fp}", style="primary"),
        ],
        [
            InlineKeyboardButton(text="📜 Логи", callback_data=f"logs:{safe}"),
            InlineKeyboardButton(text="ℹ️ Инфо", callback_data=f"info:{safe}"),
        ]
    ])
PY

write_file "$APP_DIR/src/gopanel/bot/handlers/__init__.py" <<'PY'
"""Обработчики команд бота"""
from . import commands, callbacks, alerts, bulk, docker

__all__ = ["commands", "callbacks", "alerts", "bulk", "docker"]
PY

write_file "$APP_DIR/src/gopanel/bot/handlers/alerts.py" <<'PY'
"""Мониторинг падений сервисов"""
from __future__ import annotations
import asyncio
import logging
import time
from aiogram import Bot
from aiogram.exceptions import TelegramForbiddenError, TelegramRetryAfter
from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup  # [ИСПРАВЛЕНО v2.1-38]
from ..config import config
from ..keyboards import create_service_keyboard, create_alert_keyboard, create_recovery_keyboard
from ...registry import get_registry
from ...systemd import batch_show
from ...docker import docker_ps  # [ИСПРАВЛЕНО v2.1-38]

log = logging.getLogger("gopanel.bot.handlers.alerts")


def escape_html(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

escape_md = escape_html


class AlertMonitor:
    def __init__(self, bot: Bot):
        self.bot = bot
        self._previous_statuses: dict[str, str] = {}
        self._previous_restarts: dict[str, int] = {}
        self._previous_enter_ts: dict[str, int] = {}
        # FIX SLOW-RESTART-3: отдельный словарь для enter_ts последнего
        # АКТИВНОГО состояния. _previous_enter_ts обновляется каждый poll,
        # включая промежуточные статусы (activating, deactivating) где
        # ActiveEnterTimestampMonotonic = 0. При проверке activating → active
        # сравниваем с enter_ts из последнего раза когда сервис был active,
        # а не из фазы activating где ts = 0.
        self._last_active_enter_ts: dict[str, int] = {}
        # [ИСПРАВЛЕНО v2.1-10] pending-restart больше не хранится здесь — см.
        # Registry.mark_pending_restart/get_pending_restarts (registry.py).
        # Раньше TUI и бот (разные ОС-процессы) не видели pending-флаг друг
        # друга: рестарт через TUI отображался в боте как "остановлен"+
        # "восстановлен" вместо одного "перезапущен", и наоборот.
        # [ИСПРАВЛЕНО v2.1-15] 30с -> 120с, см. подробный комментарий в
        # dashboard.py (DashboardScreen.__init__) — нагрузочный тест показал
        # возврат исходного бага именно под нагрузкой при старом значении.
        self._pending_restart_timeout = 120.0
        self._running = False
        self._first_check = True
        self._last_alert_time: dict[str, float] = {}
        self._alert_cooldown = 15
        self._recovery_cooldown = 15
        self._check_lock = asyncio.Lock()
        # [ИСПРАВЛЕНО v2.1-23] ссылка на текущую задачу _check_statuses —
        # раньше stop() лишь выставлял _running=False и не мог прервать уже
        # выполняющуюся проверку (systemctl/run_exec), из-за чего graceful
        # shutdown бота мог упереться в TimeoutStopSec и получить SIGKILL.
        self._current_task: asyncio.Task | None = None
        # [ИСПРАВЛЕНО v2.1-38] (Medium): состояние детекции падений critical-контейнеров.
        self._container_bad: dict[str, int] = {}
        self._container_alerted: set[str] = set()
        self._container_last_sent: dict[str, float] = {}
        # [ИСПРАВЛЕНО v2.1-39]: pending-флаг общий для TUI и бота (разные процессы). Раньше
        # тот, кто первым увидел "перезапущен", удалял флаг из БД целиком, и
        # второй процесс оставался без защиты: вместо "перезапущен" он
        # показывал "остановлен"/"восстановлен" либо ничего. Теперь каждый
        # процесс помнит, какую метку флага он уже обработал, и не трогает флаг
        # в БД (его снимает таймаут либо неуспешный control()).
        self._handled_pending: dict[str, float] = {}

    async def mark_pending_restart(self, unit: str) -> None:
        # [ИСПРАВЛЕНО v2.1-10] делегирует в общую БД — виден и TUI
        try:
            await get_registry().mark_pending_restart(unit)
        except Exception as e:
            log.warning("Failed to mark pending restart for %s: %s", unit, e)

    async def clear_pending_restart(self, unit: str) -> None:
        # [ИСПРАВЛЕНО v2.1-10] делегирует в общую БД — виден и TUI
        try:
            await get_registry().clear_pending_restart(unit)
        except Exception as e:
            log.warning("Failed to clear pending restart for %s: %s", unit, e)

    async def start(self):
        if not config.enable_alerts:
            log.info("Alerts disabled in config")
            # [ИСПРАВЛЕНО v2.1-38] (High): раньше здесь был сразу return, и main()
            # (asyncio.wait FIRST_COMPLETED) считал это завершением бота -> polling
            # отменялся, процесс выходил с кодом 0. Теперь монитор ждёт отмены.
            await asyncio.Event().wait()
            return
        self._running = True
        log.info("Starting alert monitor")
        while self._running:
            try:
                if not self._check_lock.locked():
                    async with self._check_lock:
                        # [ИСПРАВЛЕНО v2.1-23] запускаем проверку как отдельную
                        # Task и держим на неё ссылку — stop() теперь может
                        # реально отменить именно эту задачу, а не просто выйти
                        # из цикла на следующей итерации.
                        self._current_task = asyncio.ensure_future(self._check_statuses())
                        try:
                            await self._current_task
                        finally:
                            self._current_task = None
                        # [ИСПРАВЛЕНО v2.1-38] (Medium): проверка critical-контейнеров после
                        # systemd, чтобы медленный docker не задерживал systemd-алерты.
                        self._current_task = asyncio.ensure_future(self._check_containers())
                        try:
                            await self._current_task
                        finally:
                            self._current_task = None
                await asyncio.sleep(5)
            except Exception as e:
                log.error("Alert monitor error: %s", e)
                await asyncio.sleep(5)

    async def stop(self):
        self._running = False
        # [ИСПРАВЛЕНО v2.1-23] активно отменяем уже выполняющуюся проверку
        # (а не просто ждём, пока она сама доработает до конца) — см.
        # run_exec() в utils.py, который теперь корректно убивает дочерний
        # процесс при CancelledError.
        if self._current_task is not None and not self._current_task.done():
            self._current_task.cancel()
            try:
                await self._current_task
            except asyncio.CancelledError:
                pass
            except Exception as e:
                log.warning("Error while cancelling in-flight check: %s", e)
        log.info("Alert monitor stopped")

    async def _check_statuses(self):
        registry = get_registry()
        await asyncio.to_thread(registry.reload)
        entries = registry.list()
        if not entries:
            return
        units = [e.unit for e in entries]

        # Прямой вызов batch_show, минуя кэш
        statuses = await batch_show(units)

        # Очищаем состояния удалённых сервисов — предотвращаем утечку памяти
        active_units = set(units)
        for stale in set(self._previous_statuses) - active_units:
            self._previous_statuses.pop(stale, None)
            self._previous_restarts.pop(stale, None)
            self._previous_enter_ts.pop(stale, None)
            self._last_active_enter_ts.pop(stale, None)
            # [ИСПРАВЛЕНО v2.1-10] _pending_restarts здесь больше нет — флаг
            # теперь в общей таблице settings (registry.py). Осиротевшая
            # запись для удалённого сервиса самоочищается по тайм-ауту 30с
            # (см. проверку ниже), отдельная очистка не нужна.

        # FIX MEMLEAK-1: очищаем кулдаун-записи для удалённых сервисов.
        # _last_alert_time хранит ключи вида "name:alert", "name:recovery",
        # "name:restart". При удалении сервиса из реестра эти ключи ранее
        # оставались навсегда, вызывая медленный рост словаря.
        # active_names — имена сервисов (не unit-имена), берём из entries.
        active_names = {e.name for e in entries}
        for key in list(self._last_alert_time.keys()):
            # Ключ имеет формат "service_name:suffix" — берём часть до последнего ":"
            name_part = key.rsplit(":", 1)[0]
            if name_part not in active_names:
                del self._last_alert_time[key]

        # [ИСПРАВЛЕНО v2.1-10] один SELECT за цикл опроса вместо in-memory
        # словаря — тот же флаг виден и TUI (см. registry.py)
        pending_map = await asyncio.to_thread(registry.get_pending_restarts)

        for entry in entries:
            st = statuses.get(entry.unit)
            if not st:
                continue

            current_status = st.active
            current_restarts = st.restarts
            current_enter_ts = st.enter_timestamp
            previous_status = self._previous_statuses.get(entry.unit)
            previous_restarts = self._previous_restarts.get(entry.unit)
            previous_enter_ts = self._previous_enter_ts.get(entry.unit, 0)

            if self._first_check:
                self._previous_statuses[entry.unit] = current_status
                self._previous_restarts[entry.unit] = current_restarts
                self._previous_enter_ts[entry.unit] = current_enter_ts
                if current_status == "active":
                    self._last_active_enter_ts[entry.unit] = current_enter_ts
                # При первом запуске сообщаем если сервис уже в проблемном состоянии.
                # [ИСПРАВЛЕНО v2.1-31] Алерт о "failed" теперь тоже только для
                # critical — симметрично с основным циклом (см. "Явное падение"
                # ниже, гейт по critical добавлен там же в рамках Варианта B).
                # Алерт об "inactive" — только для critical, т.к. inactive для
                # некритических сервисов является нормальным состоянием.
                if current_status == "failed" and entry.critical:
                    await self._send_alert(entry.name, st, "failed")
                elif current_status == "inactive" and entry.critical:
                    await self._send_alert(entry.name, st, "inactive")
                continue

            # [ИСПРАВЛЕНО v2.4] если для этого unit'а ожидается ручной рестарт
            # (см. mark_pending_restart / callback_confirm_restart), не гадаем
            # по фазе systemd — подавляем "остановлен"/"failed" для любых
            # промежуточных состояний и по возврату в active отправляем ОДНО
            # уведомление о рестарте. Раньше это зависело от того, какую именно
            # фазу поймает 5-секундный опрос (activating часто слишком короткая),
            # из-за чего рестарт нередко выглядел как "остановлен" + "восстановлен".
            pending_since = pending_map.get(entry.unit)
            if pending_since is not None and time.time() - pending_since > self._pending_restart_timeout:
                await self.clear_pending_restart(entry.unit)
                pending_since = None
            # [ИСПРАВЛЕНО v2.1-39]: флаг этой метки уже обработан данным процессом.
            if pending_since is None:
                self._handled_pending.pop(entry.unit, None)
            elif self._handled_pending.get(entry.unit) == pending_since:
                pending_since = None
            if pending_since is not None:
                # [ИСПРАВЛЕНО v2.1-36] раньше здесь проверялся только сам факт
                # current_status == "active", без сверки enter_timestamp — в
                # отличие от соседней ветки ниже (elif active/active), которая
                # именно так и определяет "ручной рестарт". Из-за этого узкое
                # окно между mark_pending_restart() (TUI) и фактическим стартом
                # systemctl restart могло попасть под опрос бота, который видел
                # СТАРЫЙ активный процесс (ещё не перезапущенный) и НЕМЕДЛЕННО
                # снимал pending-флаг как "уже перезапущен". Настоящий рестарт,
                # случившийся чуть позже, происходил уже без флага-защиты и
                # ошибочно классифицировался как обычное inactive→active
                # ("восстановлен") — это и есть симптом с прода.
                if current_status == "active" and (current_enter_ts != previous_enter_ts or previous_status != "active"):
                    # [ИСПРАВЛЕНО v2.1-39]: флаг в БД не удаляем - его ещё ждёт другой процесс.
                    self._handled_pending[entry.unit] = pending_since
                    log.info("Restart detected for %s: ручной рестарт (pending-flag)", entry.name)
                    # [ИСПРАВЛЕНО v2.1-28] Вариант B (выбран пользователем):
                    # restart-notice в Telegram теперь только для critical —
                    # симметрично с TUI, который для некритических сервисов
                    # уведомления о рестарте не показывает вовсе.
                    if entry.critical:
                        await self._send_restart_notice(entry.name, st)
                # [ИСПРАВЛЕНО v2.1-38] (High): "failed" на двух опросах подряд при
                # pending-флаге - это не промежуточное состояние рестарта, а реальное
                # падение. Снимаем флаг и сообщаем (иначе после снятия флага
                # previous уже "failed" и алерт не придёт никогда).
                # [ИСПРАВЛЕНО v2.1-40]: при рестарте УЖЕ упавшего сервиса между постановкой флага и
                # реальным стартом (спавн sudo/systemctl) опрос видит прежний "failed" -
                # это не новое падение. Требуем, чтобы "failed" держался дольше 5 с после флага.
                elif current_status == "failed" and previous_status == "failed" and time.time() - pending_since > 5.0:
                    # [ИСПРАВЛЕНО v2.1-39]: то же - только локальная отметка, флаг в БД остаётся.
                    self._handled_pending[entry.unit] = pending_since
                    log.info("Restart of %s ended in failed state", entry.name)
                    if entry.critical:
                        await self._send_alert(entry.name, st, "failed")
                self._previous_statuses[entry.unit] = current_status
                self._previous_restarts[entry.unit] = current_restarts
                self._previous_enter_ts[entry.unit] = current_enter_ts
                if current_status == "active" and current_enter_ts != 0:
                    self._last_active_enter_ts[entry.unit] = current_enter_ts
                continue

            # --- Определение событий ---

            # Явное падение: любой статус → failed
            if current_status == "failed" and previous_status != "failed":
                # [ИСПРАВЛЕНО v2.1-31] Вариант B (по аналогии с restart-notice,
                # v2.1-28): failed/recovery в Telegram теперь тоже только для
                # critical — TUI для некритических сервисов эти события вообще
                # не публикует (ранний continue в _do_refresh), рассинхронизация
                # была не устранена вместе с restart-notice в прошлый раз.
                if entry.critical:
                    await self._send_alert(entry.name, st, "failed")

            # Восстановление: failed → active
            elif previous_status == "failed" and current_status == "active":
                # [ИСПРАВЛЕНО v2.1-31] см. комментарий выше у "failed".
                if entry.critical:
                    await self._send_recovery(entry.name, st)

            elif current_status == "active" and previous_status == "active":
                restarts_grew = (previous_restarts is not None
                                 and current_restarts > previous_restarts)
                # Ручной рестарт: enter_timestamp изменился (новый запуск)
                # NRestarts не растёт при ручном stop+start
                ts_changed = (current_enter_ts != 0
                              and previous_enter_ts != 0
                              and current_enter_ts != previous_enter_ts)

                if restarts_grew or ts_changed:
                    reason = f"restarts +{current_restarts - previous_restarts}" if restarts_grew else "ручной рестарт"
                    log.info("Restart detected for %s: %s", entry.name, reason)
                    # [ИСПРАВЛЕНО v2.1-28] Вариант B — см. комментарий выше у
                    # pending-flag ветки.
                    if entry.critical:
                        await self._send_restart_notice(entry.name, st)

            # FIX SLOW-RESTART-1: медленный рестарт (>5 сек) — сервис успевает
            # пройти через activating перед тем как вернуться в active.
            # Ветка active→active с ts_changed не срабатывает т.к. previous_status
            # становится "activating", а не "active". Детектируем рестарт здесь.
            # Используем _last_active_enter_ts (ts из последнего активного состояния),
            # а не previous_enter_ts (который в фазе activating = 0).
            elif current_status == "active" and previous_status == "activating":
                last_active_ts = self._last_active_enter_ts.get(entry.unit, 0)
                ts_changed = (current_enter_ts != 0
                              and last_active_ts != 0
                              and current_enter_ts != last_active_ts)
                restarts_grew = (previous_restarts is not None
                                 and current_restarts > previous_restarts)
                if restarts_grew or ts_changed:
                    log.info("Slow restart detected for %s (via activating)", entry.name)
                    # [ИСПРАВЛЕНО v2.1-28] Вариант B — см. комментарий выше у
                    # pending-flag ветки.
                    if entry.critical:
                        await self._send_restart_notice(entry.name, st)
                elif entry.critical:
                    # enter_ts не изменился — первый запуск после стопа
                    await self._send_recovery(entry.name, st)

            # Критический сервис начал останавливаться: active → deactivating
            elif (previous_status == "active"
                  and current_status == "deactivating"
                  and entry.critical):
                await self._send_alert(entry.name, st, "inactive")

            # Критический сервис штатно остановлен: active/deactivating → inactive
            elif (previous_status in ("active", "deactivating")
                  and current_status == "inactive"
                  and entry.critical):
                # Алерт уже мог быть отправлен при deactivating — не дублируем
                if previous_status == "active":
                    await self._send_alert(entry.name, st, "inactive")

            # Критический сервис восстановлен из inactive/deactivating
            # (activating → active уже обработан выше в FIX SLOW-RESTART-1)
            elif (previous_status in ("inactive", "deactivating")
                  and current_status == "active"
                  and entry.critical):
                await self._send_recovery(entry.name, st)

            # Всегда обновляем состояние
            self._previous_statuses[entry.unit] = current_status
            self._previous_restarts[entry.unit] = current_restarts
            self._previous_enter_ts[entry.unit] = current_enter_ts
            # Обновляем last_active_enter_ts только когда сервис реально активен
            if current_status == "active" and current_enter_ts != 0:
                self._last_active_enter_ts[entry.unit] = current_enter_ts

        self._first_check = False

    # [ИСПРАВЛЕНО v2.1-38] (Medium): детекция падений critical-контейнеров. Падение
    # подтверждается двумя опросами подряд (~10 с): штатный `docker restart` в
    # состоянии "не running" проводит миллисекунды и ложных алертов не даёт.
    # Пустой ответ docker_ps трактуется как "docker недоступен" - цикл пропускается.
    async def _check_containers(self):
        try:
            containers = [c for c in get_registry().list_containers() if c.critical]
            names = {c.name for c in containers}
            for stale in set(self._container_bad) - names:
                self._container_bad.pop(stale, None)
                self._container_alerted.discard(stale)
            for key in [k for k in self._container_last_sent if k.rsplit(":", 1)[0] not in names]:
                self._container_last_sent.pop(key, None)
            if not containers:
                return
            statuses = await docker_ps()
            if not statuses:
                return
            for c in containers:
                cst = statuses.get(c.name)
                state = cst.active if cst else "inactive"
                if state == "active":
                    if c.name in self._container_alerted:
                        self._container_alerted.discard(c.name)
                        await self._send_container_notice(c, cst, "recovery")
                    self._container_bad[c.name] = 0
                    continue
                self._container_bad[c.name] = self._container_bad.get(c.name, 0) + 1
                if self._container_bad[c.name] >= 2 and c.name not in self._container_alerted:
                    self._container_alerted.add(c.name)
                    await self._send_container_notice(c, cst, "alert")
        except Exception as e:
            log.warning("Container check failed: %s", e)

    async def _send_container_notice(self, container, cstatus, kind: str):
        now = time.time()
        cooldown_key = f"{container.name}:{kind}"
        if now - self._container_last_sent.get(cooldown_key, 0) < self._alert_cooldown:
            return
        self._container_last_sent[cooldown_key] = now
        safe_name = escape_html(container.name)
        status_text = escape_html(cstatus.status_text) if cstatus and cstatus.status_text else "не найден в docker"
        dfp = get_registry().container_fingerprint()
        cn = container.name
        if kind == "alert":
            # [ИСПРАВЛЕНО v2.1-41]: Exited (0) - штатная остановка (как "СЕРВИС ОСТАНОВЛЕН" у
            # systemd), ненулевой код выхода / restarting / не найден - падение.
            # [ИСПРАВЛЕНО v2.1-45]: обычный `docker stop` шлёт SIGTERM, и процесс без своего
            # обработчика завершается с кодом 143 (128+15), а не 0 - это тоже штатная остановка.
            # Код 137 (SIGKILL) намеренно остаётся "падением": так выглядит и OOM-kill.
            title = ("⚠️ <b>КОНТЕЙНЕР ОСТАНОВЛЕН</b>"
                     if cstatus and (cstatus.status_text or "").startswith(("Exited (0)", "Exited (143)"))
                     else "🔥 <b>КРИТИЧЕСКОЕ ПАДЕНИЕ КОНТЕЙНЕРА</b>")
            text = (f"{title}\n\n"
                    f"Контейнер: <b>{safe_name}</b>\nСтатус: {status_text}")
            first = [
                InlineKeyboardButton(text="▶ Запуск", callback_data=f"docker:start:{cn}:{dfp}", style="success"),
                InlineKeyboardButton(text="🔄 Рестарт", callback_data=f"docker:restart:{cn}:{dfp}", style="primary"),
            ]
        else:
            text = (f"✅ <b>КОНТЕЙНЕР ВОССТАНОВЛЕН</b>\n\n"
                    f"Контейнер: <b>{safe_name}</b>\nСтатус: {status_text}")
            first = [
                InlineKeyboardButton(text="⏹ Стоп", callback_data=f"docker:stop:{cn}:{dfp}", style="danger"),
                InlineKeyboardButton(text="🔄 Рестарт", callback_data=f"docker:restart:{cn}:{dfp}", style="primary"),
            ]
        keyboard = InlineKeyboardMarkup(inline_keyboard=[first, [
            InlineKeyboardButton(text="📜 Логи", callback_data=f"docker:logs:{cn}"),
            InlineKeyboardButton(text="ℹ️ Инфо", callback_data=f"docker:info:{cn}"),
        ]])
        for user_id in config.authorized_users:
            try:
                await self.bot.send_message(user_id, text, parse_mode="HTML", reply_markup=keyboard)
            except TelegramRetryAfter as e:
                log.warning("Rate limited sending container notice to %s: retry in %ss", user_id, e.retry_after)
            except TelegramForbiddenError:
                log.warning("User %s blocked the bot", user_id)
            except Exception as e:
                log.error("Failed to send container notice to %s: %s", user_id, e)

    async def _send_alert(self, service_name: str, status, alert_type: str):
        now = time.time()
        # [ИСПРАВЛЕНО v2.1-38] (Low): ключ по типу события, иначе "inactive" подавляет "failed".
        cooldown_key = f"{service_name}:{alert_type}"
        last_alert = self._last_alert_time.get(cooldown_key, 0)
        if now - last_alert < self._alert_cooldown:
            log.debug("Alert cooldown active for %s, skipping", service_name)
            return
        memory_str = f"{status.memory_bytes / 1048576:.1f} MB" if status.memory_bytes > 0 else "—"
        if alert_type == "failed":
            emoji = "🔥"
            title = "КРИТИЧЕСКОЕ ПАДЕНИЕ"
        else:
            emoji = "⚠️"
            title = "СЕРВИС ОСТАНОВЛЕН"
        safe_name = escape_html(service_name)
        text = (
            f"{emoji} <b>{escape_html(title)}</b>\n\n"
            f"Сервис: <b>{safe_name}</b>\n"
            # FIX DEF-07: status.active и status.sub приходят от systemd и используются
            # напрямую в HTML-строке без экранирования. Хотя типичные значения
            # (running, dead, failed) безопасны, экранирование обязательно для
            # любых данных из внешних источников в HTML-контексте.
            f"Статус: {escape_html(status.active)} ({escape_html(status.sub)})\n"
            f"PID: {status.main_pid or '—'}\n"
            f"Memory: {memory_str}\n\n"
            f"Действия:"
        )
        keyboard = create_alert_keyboard(service_name)
        # FIX C-7: кулдаун выставляем ДО цикла по пользователям, независимо от
        # результата доставки. Если выставлять внутри try (только при успехе),
        # то при временном сбое Telegram API (все send_message падают) кулдаун
        # не выставляется и монитор повторяет попытку каждые 5 секунд бесконечно,
        # засоряя bot.log тысячами ошибок. Ошибки доставки по-прежнему логируются.
        self._last_alert_time[cooldown_key] = now
        # FIX H-1: убираем принудительный сброс recovery-кулдауна.
        # Ранее здесь стояло: self._last_alert_time[f"{service_name}:recovery"] = 0
        # Намерение было правильным: дать recovery-уведомлению дойти даже в период
        # recovery-кулдауна. Но _check_statuses уже гарантирует, что _send_recovery
        # вызывается только при реальном изменении статуса (previous != current) —
        # дополнительный сброс кулдауна избыточен.
        # Побочный эффект был вреден: при флапе (down→up→down→up) каждый
        # _send_alert сбрасывал recovery-кулдаун в 0, каждый _send_recovery
        # сбрасывал alert-кулдаун в 0 — весь cooldown-механизм обходился
        # на флапающем сервисе, генерируя спам в Telegram вплоть до rate-limit
        # 429, после чего бот замолкал и на реальные инциденты.
        for user_id in config.authorized_users:
            try:
                await self.bot.send_message(user_id, text, parse_mode="HTML", reply_markup=keyboard)
                log.info("Alert sent to user %d for service %s", user_id, service_name)
            except TelegramRetryAfter as e:
                # FIX ST-5: Telegram вернул FloodWait (429 Too Many Requests).
                # Оригинальный код ловил это как generic Exception и логировал ошибку,
                # затем через 5 секунд (следующий poll) снова пытался отправить —
                # получая очередной 429. Это создавало бесконечный цикл ошибок.
                # Исправление: явно ждём retry_after секунд из ответа Telegram,
                # затем пропускаем отправку этому пользователю в текущем цикле
                # (cooldown уже выставлен, следующая попытка — через _alert_cooldown).
                # [ИСПРАВЛЕНО v2.1-22] await asyncio.sleep(e.retry_after) здесь
                # блокировал весь AlertMonitor: эта корутина вызывается напрямую
                # из _check_statuses, поэтому сон на retry_after (иногда десятки
                # секунд) останавливал опрос systemd для ВСЕХ сервисов на это
                # время. При этом повторной отправки после сна всё равно не было —
                # цикл просто продолжался к следующему пользователю. Убрали сон:
                # результат доставки для этого пользователя не меняется (как и
                # раньше, просто не отправлено в этом цикле), но polling больше
                # не блокируется.
                log.warning(
                    "Telegram FloodWait %ds for user %d — skipping this cycle (not blocking poll loop)",
                    e.retry_after, user_id
                )
            except TelegramForbiddenError:
                # FIX FORBIDDEN-1: пользователь заблокировал бота.
                # Без явной обработки каждый цикл AlertMonitor (каждые 5 сек)
                # пишет "Forbidden" в bot.log — тысячи строк за сутки, риск
                # попадания под спам-фильтр Telegram. Логируем однократно как
                # warning и пропускаем — бот не может отправить заблокированному.
                log.warning(
                    "User %d has blocked the bot — skipping alert for service %s",
                    user_id, service_name
                )
            except Exception as e:
                log.error("Failed to send alert to user %d: %s", user_id, e)

    async def _send_recovery(self, service_name: str, status):
        now = time.time()
        cooldown_key = f"{service_name}:recovery"
        last_alert = self._last_alert_time.get(cooldown_key, 0)
        if now - last_alert < self._recovery_cooldown:
            log.debug("Recovery cooldown active for %s, skipping", service_name)
            return
        uptime_str = "—"
        if status.uptime_sec is not None:
            sec = int(status.uptime_sec)
            uptime_str = f"{sec // 86400}д {(sec % 86400) // 3600:02d}:{(sec % 3600) // 60:02d}"
        safe_name = escape_html(service_name)
        text = (
            f"✅ <b>СЕРВИС ВОССТАНОВЛЕН</b>\n\n"
            f"Сервис: <b>{safe_name}</b>\n"
            # FIX DEF-07: status.active и status.sub приходят от systemd и используются
            # напрямую в HTML-строке без экранирования. Хотя типичные значения
            # (running, dead, failed) безопасны, экранирование обязательно для
            # любых данных из внешних источников в HTML-контексте.
            f"Статус: {escape_html(status.active)} ({escape_html(status.sub)})\n"
            f"Uptime: {uptime_str}\n\n"
            f"Действия:"
        )
        keyboard = create_recovery_keyboard(service_name)
        # FIX C-7: аналогично _send_alert — кулдаун выставляем ДО цикла,
        # чтобы при сбое Telegram API не возникал retry-storm.
        self._last_alert_time[cooldown_key] = now
        # FIX H-1: убираем принудительный сброс alert-кулдауна.
        # Ранее здесь стояло: self._last_alert_time[f"{service_name}:alert"] = 0
        # Намерение: дать следующему alert-уведомлению дойти сразу после recovery.
        # Но это создавало симметричный обход кулдауна при флапе (см. комментарий
        # в _send_alert). _check_statuses вызывает _send_alert только при реальном
        # переходе статуса в "failed" — дополнительный сброс здесь не нужен.
        for user_id in config.authorized_users:
            try:
                await self.bot.send_message(user_id, text, parse_mode="HTML", reply_markup=keyboard)
                log.info("Recovery notification sent to user %d for service %s", user_id, service_name)
            except TelegramRetryAfter as e:
                # FIX ST-5: Telegram вернул FloodWait (429 Too Many Requests).
                # Оригинальный код ловил это как generic Exception и логировал ошибку,
                # затем через 5 секунд (следующий poll) снова пытался отправить —
                # получая очередной 429. Это создавало бесконечный цикл ошибок.
                # Исправление: явно ждём retry_after секунд из ответа Telegram,
                # затем пропускаем отправку этому пользователю в текущем цикле
                # (cooldown уже выставлен, следующая попытка — через _alert_cooldown).
                # [ИСПРАВЛЕНО v2.1-22] await asyncio.sleep(e.retry_after) здесь
                # блокировал весь AlertMonitor: эта корутина вызывается напрямую
                # из _check_statuses, поэтому сон на retry_after (иногда десятки
                # секунд) останавливал опрос systemd для ВСЕХ сервисов на это
                # время. При этом повторной отправки после сна всё равно не было —
                # цикл просто продолжался к следующему пользователю. Убрали сон:
                # результат доставки для этого пользователя не меняется (как и
                # раньше, просто не отправлено в этом цикле), но polling больше
                # не блокируется.
                log.warning(
                    "Telegram FloodWait %ds for user %d — skipping this cycle (not blocking poll loop)",
                    e.retry_after, user_id
                )
            except TelegramForbiddenError:
                # FIX FORBIDDEN-1 (recovery): аналогично _send_alert.
                log.warning(
                    "User %d has blocked the bot — skipping recovery for service %s",
                    user_id, service_name
                )
            except Exception as e:
                log.error("Failed to send recovery to user %d: %s", user_id, e)


    async def _send_restart_notice(self, service_name: str, status):
        """Уведомление о плановом рестарте — не тревога, а информация."""
        now = time.time()
        cooldown_key = f"{service_name}:restart"
        if now - self._last_alert_time.get(cooldown_key, 0) < self._recovery_cooldown:
            log.debug("Restart notice cooldown active for %s, skipping", service_name)
            return
        uptime_str = "—"
        if status.uptime_sec is not None:
            sec = int(status.uptime_sec)
            uptime_str = f"{sec // 86400}д {(sec % 86400) // 3600:02d}:{(sec % 3600) // 60:02d}"
        safe_name = escape_html(service_name)
        text = (
            f"🔄 <b>СЕРВИС ПЕРЕЗАПУЩЕН</b>\n\n"
            f"Сервис: <b>{safe_name}</b>\n"
            # FIX DEF-07: status.active и status.sub приходят от systemd и используются
            # напрямую в HTML-строке без экранирования. Хотя типичные значения
            # (running, dead, failed) безопасны, экранирование обязательно для
            # любых данных из внешних источников в HTML-контексте.
            f"Статус: {escape_html(status.active)} ({escape_html(status.sub)})\n"
            f"Uptime: {uptime_str}\n\n"
            f"Действия:"
        )
        keyboard = create_recovery_keyboard(service_name)
        # FIX C-7: кулдаун выставляем ДО цикла по пользователям —
        # аналогично _send_alert и _send_recovery. Без этого при сбое
        # Telegram API уведомление о рестарте повторялось бы каждые 5 сек.
        self._last_alert_time[cooldown_key] = now
        for user_id in config.authorized_users:
            try:
                await self.bot.send_message(user_id, text, parse_mode="HTML", reply_markup=keyboard)
                log.info("Restart notice sent to user %d for service %s", user_id, service_name)
            except TelegramRetryAfter as e:
                # FIX ST-5: Telegram вернул FloodWait (429 Too Many Requests).
                # Оригинальный код ловил это как generic Exception и логировал ошибку,
                # затем через 5 секунд (следующий poll) снова пытался отправить —
                # получая очередной 429. Это создавало бесконечный цикл ошибок.
                # Исправление: явно ждём retry_after секунд из ответа Telegram,
                # затем пропускаем отправку этому пользователю в текущем цикле
                # (cooldown уже выставлен, следующая попытка — через _alert_cooldown).
                # [ИСПРАВЛЕНО v2.1-22] await asyncio.sleep(e.retry_after) здесь
                # блокировал весь AlertMonitor: эта корутина вызывается напрямую
                # из _check_statuses, поэтому сон на retry_after (иногда десятки
                # секунд) останавливал опрос systemd для ВСЕХ сервисов на это
                # время. При этом повторной отправки после сна всё равно не было —
                # цикл просто продолжался к следующему пользователю. Убрали сон:
                # результат доставки для этого пользователя не меняется (как и
                # раньше, просто не отправлено в этом цикле), но polling больше
                # не блокируется.
                log.warning(
                    "Telegram FloodWait %ds for user %d — skipping this cycle (not blocking poll loop)",
                    e.retry_after, user_id
                )
            except TelegramForbiddenError:
                # FIX FORBIDDEN-1 (restart notice): аналогично _send_alert.
                log.warning(
                    "User %d has blocked the bot — skipping restart notice for service %s",
                    user_id, service_name
                )
            except Exception as e:
                log.error("Failed to send restart notice to user %d: %s", user_id, e)


alert_monitor: AlertMonitor | None = None

def create_alert_monitor(bot: Bot) -> AlertMonitor:
    global alert_monitor
    alert_monitor = AlertMonitor(bot)
    return alert_monitor
PY

write_file "$APP_DIR/src/gopanel/bot/handlers/commands.py" <<'PY'
"""Обработчики текстовых команд"""
from __future__ import annotations
import asyncio
import logging
import os
from aiogram import Router
from aiogram.exceptions import TelegramRetryAfter
from aiogram.types import (
    Message, InlineKeyboardMarkup, InlineKeyboardButton,
    ReplyKeyboardMarkup, KeyboardButton, FSInputFile
)
from aiogram.filters import Command, CommandStart
from ..auth import check_authorization
from ..cache import status_cache
from ...registry import get_registry
from ...systemd import control
from ...journal import tail
from ...utils import run_exec
from .alerts import escape_html

log = logging.getLogger("gopanel.bot.handlers.commands")
router = Router()

# Постоянная клавиатура под полем ввода
MAIN_KEYBOARD = ReplyKeyboardMarkup(
    keyboard=[
        [KeyboardButton(text="🎛 Сервисы"), KeyboardButton(text="📊 Статус")],
        [KeyboardButton(text="📸 Скриншот"), KeyboardButton(text="⚡ Массовые")],
        [KeyboardButton(text="📖 Помощь")],
    ],
    resize_keyboard=True,
    persistent=True,
    input_field_placeholder="Выберите действие или введите команду…"
)

def _truncate_utf8(s: str, max_bytes: int) -> str:
    encoded = s.encode("utf-8")
    if len(encoded) <= max_bytes:
        return s
    # FIX UTF8-1: простое encoded[:max_bytes].decode(errors="ignore") режет
    # многобайтовые символы (кириллица = 2 байта) пополам. decode(errors="ignore")
    # молча выбрасывает осиротевший байт — последний символ имени исчезает.
    # Для callback_data это критично: имя в кнопке не совпадёт с ключом реестра,
    # нажатие кнопки вернёт "сервис не найден".
    # Правильный алгоритм: откатываемся назад от точки обрезки, пока не окажемся
    # на границе UTF-8 символа (continuation bytes имеют маску 0b10xxxxxx = 0x80).
    truncated = bytearray(encoded[:max_bytes])
    # Убираем хвостовые continuation bytes (0x80-0xBF)
    while truncated and (truncated[-1] & 0xC0) == 0x80:
        truncated.pop()
    # Если остался одиночный leading byte многобайтового символа — убираем и его
    if truncated and (truncated[-1] & 0x80) != 0 and (truncated[-1] & 0xC0) != 0xC0:
        truncated.pop()
    return bytes(truncated).decode("utf-8", errors="ignore")

def _format_logs_html(raw: str) -> str:
    """Форматирует вывод journalctl в читаемый HTML для Telegram."""
    lines = raw.strip().splitlines()
    result = []
    for line in lines:
        # Формат short: Jun 04 21:51:01 host unit[pid]: message
        # Берём только время (часть 2) и сообщение (часть 4+)
        parts = line.split(" ", 4)
        if len(parts) >= 5:
            ts = parts[2]          # HH:MM:SS
            msg = parts[4]
            # Убираем имя юнита из начала сообщения если есть (unit[pid]: )
            if "]: " in msg:
                msg = msg.split("]: ", 1)[1]
            msg_esc = escape_html(msg)
            ts_esc = escape_html(ts)
            if any(w in msg.lower() for w in ("error", "fail", "fatal", "critical", "exception")):
                result.append(f"🔴 <code>{ts_esc}</code> {msg_esc}")
            elif any(w in msg.lower() for w in ("warn", "warning")):
                result.append(f"🟡 <code>{ts_esc}</code> {msg_esc}")
            else:
                result.append(f"<code>{ts_esc}</code> {msg_esc}")
        else:
            result.append(f"<code>{escape_html(line)}</code>")
    return "\n".join(result)


async def _send_services_panel(message: Message):
    """Отправляет инлайн-панель со списком сервисов."""
    registry = get_registry()
    # FIX RELOAD-1: registry.reload() — синхронный блокирующий вызов:
    # открывает файл, читает JSON, валидирует Pydantic-модели.
    # При большом реестре (50+ сервисов) блокирует event loop бота на
    # 50-200ms, замораживая обработку всех других команд и отправку
    # алертов. Выносим в thread pool через asyncio.to_thread().
    await asyncio.to_thread(registry.reload)
    entries = registry.list()
    # [ИСПРАВЛЕНО v2.1-22] отпечаток реестра для start/stop/restart-кнопок — см. _parse_name_fp в callbacks.py.
    fp = registry.fingerprint()
    rows = []
    for entry in entries:
        # [ИСПРАВЛЕНО v2.1-22, доп. правка] 48->32 — см. keyboards.py, тот же лимит 64 байт callback_data.
        safe = _truncate_utf8(entry.name, 32)
        # Строка 1: название сервиса как неактивная кнопка
        rows.append([
            InlineKeyboardButton(text=f"⚙️ {entry.name}", callback_data=f"info:{safe}"),
        ])
        # Строка 2: кнопки управления с цветами
        rows.append([
            InlineKeyboardButton(text="▶ Запуск",    callback_data=f"start:{safe}:{fp}",   style="success"),
            InlineKeyboardButton(text="⏹ Стоп",     callback_data=f"stop:{safe}:{fp}",    style="danger"),
            InlineKeyboardButton(text="🔄 Рестарт",  callback_data=f"restart:{safe}:{fp}", style="primary"),
            InlineKeyboardButton(text="📜 Логи",     callback_data=f"logs:{safe}"),
        ])
    # [ФИЧА v2.1-4] Docker-секция после systemd. Имя контейнера уже
    # ограничено NAME_RE (см. registry.py DockerEntry), поэтому вставляется
    # в callback_data без дополнительного усечения — 32 байта имени +
    # префикс заведомо укладываются в лимит Telegram (64 байта).
    # [ИСПРАВЛЕНО v2.1-29] с учётом добавленного ":{dfp}" (см. ниже) худший
    # случай "docker:confirm_restart:" + 32 + ":" + 6 = 62 байта — по-прежнему
    # в пределах 64.
    containers = registry.list_containers()
    if containers:
        rows.append([InlineKeyboardButton(text="── 🐳 Docker ──", callback_data="noop")])
        # [ИСПРАВЛЕНО v2.1-29] отпечаток Docker-реестра для start/stop/restart —
        # см. Registry.container_fingerprint() и проверку в docker_router.
        dfp = registry.container_fingerprint()
        for c in containers:
            rows.append([
                InlineKeyboardButton(text=f"🐳 {c.name}", callback_data=f"docker:info:{c.name}"),
            ])
            rows.append([
                InlineKeyboardButton(text="▶ Запуск",    callback_data=f"docker:start:{c.name}:{dfp}",   style="success"),
                InlineKeyboardButton(text="⏹ Стоп",     callback_data=f"docker:stop:{c.name}:{dfp}",    style="danger"),
                InlineKeyboardButton(text="🔄 Рестарт",  callback_data=f"docker:restart:{c.name}:{dfp}", style="primary"),
                InlineKeyboardButton(text="📜 Логи",     callback_data=f"docker:logs:{c.name}"),
            ])
    keyboard = InlineKeyboardMarkup(inline_keyboard=rows) if rows else None
    text = "🎛 <b>Панель управления</b>" if rows else "📭 Нет сервисов в реестре"
    # [ИСПРАВЛЕНО v2.1-38] (Medium): лимит Telegram - 100 кнопок на клавиатуру. Делим панель на
    # несколько сообщений; разрыв только перед блоком (однокнопочная строка),
    # блок = заголовок + 4 действия, разделитель не остаётся в конце сообщения.
    chunks: list[list] = []
    cur: list = []
    cnt = 0
    for r in rows:
        if cur and len(r) == 1 and cnt + 5 > 100 and cur[-1][0].callback_data != "noop":
            chunks.append(cur)
            cur, cnt = [], 0
        cur.append(r)
        cnt += len(r)
    if cur:
        chunks.append(cur)
    if len(chunks) > 1:
        for i, chunk in enumerate(chunks):
            await message.answer(
                text if i == 0 else f"{text} (продолжение)",
                parse_mode="HTML",
                reply_markup=InlineKeyboardMarkup(inline_keyboard=chunk),
            )
        return
    await message.answer(text, parse_mode="HTML", reply_markup=keyboard)


@router.message(CommandStart())
async def cmd_start(message: Message):
    if not await check_authorization(message):
        return
    # Сначала отправляем постоянную клавиатуру
    await message.answer(
        "👋 <b>GoPanel Bot</b>\nПанель управления сервисами готова.",
        parse_mode="HTML",
        reply_markup=MAIN_KEYBOARD
    )
    # Затем инлайн-список сервисов
    await _send_services_panel(message)


@router.message(lambda m: m.text == "🎛 Сервисы")
async def btn_services(message: Message):
    if not await check_authorization(message):
        return
    await _send_services_panel(message)


@router.message(lambda m: m.text == "📊 Статус")
async def btn_status(message: Message):
    if not await check_authorization(message):
        return
    await cmd_status(message)


@router.message(lambda m: m.text == "📖 Помощь")
async def btn_help(message: Message):
    if not await check_authorization(message):
        return
    await cmd_help(message)


@router.message(lambda m: m.text == "📸 Скриншот")
async def btn_screenshot(message: Message):
    # [ФИЧА v2.1-5] tmux capture-pane -> PNG через gopanel-screenshot.
    # sudo=False: бот и tmux.sock оба принадлежат monitor, повышение
    # привилегий не требуется (в отличие от gopanel-systemctl/journalctl).
    if not await check_authorization(message):
        return
    status_msg = await message.reply("📸 Делаю снимок панели...")
    code, out, err = await run_exec(["/usr/local/bin/gopanel-screenshot"], sudo=False, timeout=15)
    if code != 0:
        detail = (err.strip() or out.strip() or f"exit={code}")[:300]
        try:
            await status_msg.edit_text(f"❌ Не удалось сделать снимок:\n{escape_html(detail)}", parse_mode="HTML")
        except Exception:
            pass
        return
    path = out.strip()
    try:
        await message.reply_photo(photo=FSInputFile(path), caption="📸 Состояние панели")
        try:
            await status_msg.delete()
        except Exception:
            pass
    except Exception as e:
        log.warning("Failed to send screenshot: %s", e)
        try:
            await status_msg.edit_text(f"❌ Не удалось отправить снимок: {escape_html(str(e)[:200])}", parse_mode="HTML")
        except Exception:
            pass
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


@router.message(Command("help"))
async def cmd_help(message: Message):
    if not await check_authorization(message):
        return
    await message.reply(
        "📖 <b>Справка по командам:</b>\n\n"
        "/start — панель управления сервисами\n"
        "/status — статус всех сервисов\n"
        "/info &lt;имя&gt; — детальная информация\n"
        "/logs &lt;имя&gt; — последние 30 строк логов\n"
        "/start_service &lt;имя&gt; — запустить сервис\n"
        "/stop_service &lt;имя&gt; — остановить (с подтверждением)\n"
        "/restart_service &lt;имя&gt; — перезапустить (с подтверждением)\n"
        "⚡ Массовые — групповой рестарт/стоп (все / critical / по группе)\n"
        "📸 Скриншот — снимок текущего состояния TUI-панели\n"
        "/help — эта справка",
        parse_mode="HTML"
    )


@router.message(Command("status"))
async def cmd_status(message: Message):
    if not await check_authorization(message):
        return
    registry = get_registry()
    entries = registry.list()
    if not entries:
        await message.reply("📭 Нет сервисов в реестре")
        return
    units = [e.unit for e in entries]
    statuses = await status_cache.get_statuses(units)
    lines = [f"📊 <b>Статус сервисов ({len(entries)}):</b>\n"]
    for entry in entries:
        st = statuses.get(entry.unit)
        if not st:
            continue
        emoji = {"active": "🟢", "failed": "🔴", "inactive": "⚪"}.get(st.active, "❓")
        uptime_str = "—"
        if st.uptime_sec is not None:
            sec = int(st.uptime_sec)
            uptime_str = f"{sec // 86400}д {(sec % 86400) // 3600:02d}:{(sec % 3600) // 60:02d}"
        safe_name = escape_html(entry.name)
        lines.append(f"\n{emoji} <b>{safe_name}</b>")
        lines.append(# FIX DEF-07-COMMANDS: escape_html для полей st.active и st.sub в списке сервисов
            f"   Статус: {escape_html(st.active)} ({escape_html(st.sub)})")
        lines.append(f"   Uptime: {uptime_str}")
        lines.append(f"   PID: {st.main_pid or '—'}")
        lines.append(f"   Memory: {st.memory_bytes / 1048576:.1f} MB" if st.memory_bytes > 0 else "   Memory: —")
    text = "\n".join(lines)
    if len(text) > 4000:
        # FIX C-1: ранее использовалось text[i:i+4000] — нарезка по байтовым
        # позициям. Граница 4000 могла попасть внутрь HTML-тега (<b>, </b>),
        # Telegram возвращал BadRequest "can't parse entities" для всех chunk'ов
        # кроме первого. При 15+ сервисах пользователь видел только часть статуса.
        # Исправление: разбиваем по полным блокам сервисов (каждый начинается с
        # пустой строки + emoji). Блок добавляется целиком или начинается новый chunk.
        chunks: list[str] = []
        current_chunk_lines: list[str] = []
        current_len = 0
        # Первая строка — заголовок "📊 Статус сервисов (N):"
        header = lines[0] if lines else ""
        for line in lines:
            # Каждый сервис начинается с пустой строки перед emoji
            # Проверяем: если добавление этой строки превысит 4000 — flush
            add_len = len(line) + 1  # +1 на \n
            if current_len + add_len > 4000 and current_chunk_lines:
                chunks.append("\n".join(current_chunk_lines))
                # Следующий chunk начинаем с заголовка для контекста
                current_chunk_lines = [header, ""]
                current_len = len(header) + 1
            current_chunk_lines.append(line)
            current_len += add_len
        if current_chunk_lines:
            chunks.append("\n".join(current_chunk_lines))
        for chunk in chunks:
            # FIX ST-1A: при отправке нескольких chunk'ов (50+ сервисов)
            # Telegram может вернуть FloodWait (429 Too Many Requests).
            # Ранее TelegramRetryAfter не обрабатывался — исключение попадало
            # в вызывающий dispatcher aiogram и chunk'и после FloodWait терялись.
            # Исправление: явно ждём retry_after секунд и повторяем отправку.
            # Единственная попытка после ожидания — если снова FloodWait,
            # следующий except поймает и залогирует.
            try:
                await message.reply(chunk, parse_mode="HTML")
            except TelegramRetryAfter as e:
                log.warning("FloodWait %ds while sending /status chunk — waiting", e.retry_after)
                await asyncio.sleep(e.retry_after)
                try:
                    await message.reply(chunk, parse_mode="HTML")
                except Exception as e2:
                    log.error("Failed to send /status chunk after retry: %s", e2)
            except Exception as e:
                log.error("Failed to send /status chunk: %s", e)
    else:
        await message.reply(text, parse_mode="HTML")


@router.message(Command("info"))
async def cmd_info(message: Message):
    if not await check_authorization(message):
        return
    args = message.text.split()
    if len(args) < 2:
        await message.reply("❌ Используйте: /info &lt;имя_сервиса&gt;", parse_mode="HTML")
        return
    service_name = args[1]
    entry = get_registry().get(service_name)
    if not entry:
        await message.reply(f"❌ Сервис '{escape_html(service_name)}' не найден", parse_mode="HTML")
        return
    statuses = await status_cache.get_statuses([entry.unit])
    st = statuses.get(entry.unit)
    if not st:
        await message.reply(f"❌ Не удалось получить статус {escape_html(entry.unit)}", parse_mode="HTML")
        return
    uptime_str = "—"
    if st.uptime_sec is not None:
        sec = int(st.uptime_sec)
        uptime_str = f"{sec // 86400}д {(sec % 86400) // 3600:02d}:{(sec % 3600) // 60:02d}"
    memory_str = f"{st.memory_bytes / 1048576:.1f} MB" if st.memory_bytes > 0 else "—"
    text = (
        f"ℹ️ <b>{escape_html(entry.name)}</b>\n\n"
        f"Unit: <code>{escape_html(entry.unit)}</code>\n"
        f"Описание: {escape_html(entry.description) if entry.description else '—'}\n"
        f"Группа: {escape_html(entry.group)}\n"
        f"Критический: {'Да' if entry.critical else 'Нет'}\n\n"
        # FIX DEF-07: escape_html для st.active и st.sub
        f"Статус: {escape_html(st.active)} ({escape_html(st.sub)})\n"
        f"Uptime: {uptime_str}\n"
        f"PID: {st.main_pid or '—'}\n"
        f"Memory: {memory_str}\n"
        f"Restarts: {st.restarts}"
    )
    await message.reply(text, parse_mode="HTML")


@router.message(Command("logs"))
async def cmd_logs(message: Message):
    if not await check_authorization(message):
        return
    args = message.text.split()
    if len(args) < 2:
        await message.reply("❌ Используйте: /logs &lt;имя_сервиса&gt;", parse_mode="HTML")
        return
    service_name = args[1]
    entry = get_registry().get(service_name)
    if not entry:
        await message.reply(f"❌ Сервис '{escape_html(service_name)}' не найден", parse_mode="HTML")
        return
    try:
        # 1.3: увеличено с 10 до 30 строк для лучшего контекста диагностики
        raw = await tail(entry.unit, n=30)   # последние 30 строк
    except Exception as e:
        await message.reply(f"❌ Ошибка получения логов: {escape_html(str(e))}", parse_mode="HTML")
        return
    if not raw or raw.startswith("[error"):
        await message.reply(f"📭 Логи для <b>{escape_html(entry.name)}</b> пусты", parse_mode="HTML")
        return
    formatted = _format_logs_html(raw)
    # FIX DEF-02: ранее здесь стояло formatted[-4000:], что обрезало уже
    # отформатированный HTML по байтовой позиции. Если граница 4000 символов
    # попадала внутрь тега <code>...</code>, Telegram возвращал BadRequest
    # "can't parse entities" — сообщение с логами вообще не отправлялось.
    # Исправление: обрезаем RAW строки ДО форматирования, чтобы итоговый
    # HTML всегда содержал только полные теги.
    if len(formatted) > 4000:
        raw_lines = raw.strip().splitlines()
        # Берём строки с конца, пока суммарный объём не превысит лимит
        selected: list[str] = []
        budget = 3800  # запас на префикс заголовка сообщения
        for line in reversed(raw_lines):
            # Форматируем одну строку для оценки её размера
            estimated = len(_format_logs_html(line)) + 1  # +1 на \n
            if budget - estimated < 0:
                break
            selected.insert(0, line)
            budget -= estimated
        formatted = _format_logs_html("\n".join(selected)) if selected else _format_logs_html(raw_lines[-1][:3800] if raw_lines else "")
    await message.reply(
        f"📜 <b>Логи {escape_html(entry.name)}</b> (последние 30 строк):\n\n{formatted}",
        parse_mode="HTML"
    )


@router.message(Command("start_service"))
async def cmd_start_service(message: Message):
    if not await check_authorization(message):
        return
    args = message.text.split()
    if len(args) < 2:
        await message.reply("❌ Используйте: /start_service &lt;имя_сервиса&gt;", parse_mode="HTML")
        return
    service_name = args[1]
    entry = get_registry().get(service_name)
    if not entry:
        await message.reply(f"❌ Сервис '{escape_html(service_name)}' не найден", parse_mode="HTML")
        return
    await message.reply(f"▶ Запуск <b>{escape_html(entry.name)}</b>…", parse_mode="HTML")
    ok, msg = await control("start", entry.unit)
    if ok:
        await message.reply(f"✅ <b>{escape_html(entry.name)}</b> запущен", parse_mode="HTML")
    else:
        await message.reply(f"❌ Ошибка запуска <b>{escape_html(entry.name)}</b>:\n<code>{escape_html(str(msg))}</code>", parse_mode="HTML")


@router.message(Command("stop_service"))
async def cmd_stop_service(message: Message):
    if not await check_authorization(message):
        return
    args = message.text.split()
    if len(args) < 2:
        await message.reply("❌ Используйте: /stop_service &lt;имя_сервиса&gt;", parse_mode="HTML")
        return
    service_name = args[1]
    entry = get_registry().get(service_name)
    if not entry:
        await message.reply(f"❌ Сервис '{escape_html(service_name)}' не найден", parse_mode="HTML")
        return
    # [ИСПРАВЛЕНО v2.1-22, доп. правка] 51->32 — с суффиксом ":fp" превышало 64 байта callback_data.
    safe_name = _truncate_utf8(service_name, 32)
    fp = get_registry().fingerprint()
    keyboard = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Да, остановить", callback_data=f"confirm_stop:{safe_name}:{fp}"),
        InlineKeyboardButton(text="❌ Отмена", callback_data=f"cancel_stop:{safe_name}")
    ]])
    await message.reply(
        f"⚠️ <b>Подтверждение</b>\n\nОстановить <b>{escape_html(entry.name)}</b>?",
        parse_mode="HTML", reply_markup=keyboard
    )


@router.message(Command("restart_service"))
async def cmd_restart_service(message: Message):
    if not await check_authorization(message):
        return
    args = message.text.split()
    if len(args) < 2:
        await message.reply("❌ Используйте: /restart_service &lt;имя_сервиса&gt;", parse_mode="HTML")
        return
    service_name = args[1]
    entry = get_registry().get(service_name)
    if not entry:
        await message.reply(f"❌ Сервис '{escape_html(service_name)}' не найден", parse_mode="HTML")
        return
    # [ИСПРАВЛЕНО v2.1-22, доп. правка] 48->32 — с суффиксом ":fp" и длинным префиксом "confirm_restart:" превышало 64 байта.
    safe_name = _truncate_utf8(service_name, 32)
    fp = get_registry().fingerprint()
    keyboard = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Да, перезапустить", callback_data=f"confirm_restart:{safe_name}:{fp}"),
        InlineKeyboardButton(text="❌ Отмена", callback_data=f"cancel_restart:{safe_name}")
    ]])
    await message.reply(
        f"⚠️ <b>Подтверждение</b>\n\nПерезапустить <b>{escape_html(entry.name)}</b>?",
        parse_mode="HTML", reply_markup=keyboard
    )
PY

write_file "$APP_DIR/src/gopanel/bot/handlers/callbacks.py" <<'PY'
"""Обработчики inline-кнопок"""
from __future__ import annotations
import logging
import time
from aiogram import Router, F
from aiogram.types import CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton
from aiogram.exceptions import TelegramBadRequest
from ..auth import check_callback_authorization
from ..cache import status_cache
from ...registry import get_registry
from ...systemd import control
from ...journal import tail
from .alerts import escape_html
from . import alerts as _alerts_mod  # [ИСПРАВЛЕНО v2.4] доступ к живому alert_monitor
from .commands import _format_logs_html

log = logging.getLogger("gopanel.bot.handlers.callbacks")
router = Router()

def _truncate_utf8(s: str, max_bytes: int) -> str:
    encoded = s.encode("utf-8")
    if len(encoded) <= max_bytes:
        return s
    # FIX UTF8-1: простое encoded[:max_bytes].decode(errors="ignore") режет
    # многобайтовые символы (кириллица = 2 байта) пополам. decode(errors="ignore")
    # молча выбрасывает осиротевший байт — последний символ имени исчезает.
    # Для callback_data это критично: имя в кнопке не совпадёт с ключом реестра,
    # нажатие кнопки вернёт "сервис не найден".
    # Правильный алгоритм: откатываемся назад от точки обрезки, пока не окажемся
    # на границе UTF-8 символа (continuation bytes имеют маску 0b10xxxxxx = 0x80).
    truncated = bytearray(encoded[:max_bytes])
    # Убираем хвостовые continuation bytes (0x80-0xBF)
    while truncated and (truncated[-1] & 0xC0) == 0x80:
        truncated.pop()
    # Если остался одиночный leading byte многобайтового символа — убираем и его
    if truncated and (truncated[-1] & 0x80) != 0 and (truncated[-1] & 0xC0) != 0xC0:
        truncated.pop()
    return bytes(truncated).decode("utf-8", errors="ignore")

def _ans(text: str, limit: int = 195) -> str:
    return text if len(text) <= limit else text[:limit - 1] + "…"

# [ИСПРАВЛЕНО v2.1-14] у TUI уже была защита от дублей (_last_control/
# CONTROL_COOLDOWN в dashboard.py), у бота — не было. Хаос-тест показал: при
# 3 быстрых нажатиях одной и той же кнопки (нетерпеливый повторный тап, пока
# Telegram не успел обновить сообщение — обычное поведение живого человека,
# не говоря о ребёнке) aiogram обрабатывает каждый callback_query в отдельной
# задаче конкурентно, и все 3 успевают вызвать control() ДО того, как первый
# успевает отредактировать сообщение/убрать клавиатуру.
_last_control: dict[str, float] = {}
_CONTROL_COOLDOWN = 2.0

def _cooldown_ok(key: str) -> bool:
    now = time.monotonic()
    if now - _last_control.get(key, 0.0) < _CONTROL_COOLDOWN:
        return False
    _last_control[key] = now
    return True

# [ИСПРАВЛЕНО v2.1-22] callback_data теперь содержит отпечаток реестра на
# момент создания кнопки (см. Registry.fingerprint(), keyboards.py). Если имя
# сервиса удалили и пересоздали (или состав/unit сервисов изменился) между
# показом кнопки и нажатием, отпечаток не совпадёт — действие отклоняется
# вместо выполнения над другой текущей записью с тем же именем.
def _parse_name_fp(tail: str) -> tuple[str, str]:
    name, _, fp = tail.rpartition(":")
    return (name, fp) if name else (tail, "")

async def _reject_stale(callback: CallbackQuery) -> None:
    try:
        await callback.answer(_ans("⚠️ Список сервисов изменился, обновите панель"), show_alert=True)
    except TelegramBadRequest:
        pass

@router.callback_query(F.data.startswith("start:"))
async def callback_start(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    service_name, _fp = _parse_name_fp(callback.data.split(":", 1)[1])
    entry = get_registry().get(service_name)
    if not entry:
        try:
            await callback.answer(_ans(f"❌ Сервис '{service_name}' не найден"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    if _fp != get_registry().fingerprint():
        await _reject_stale(callback)
        return
    if not _cooldown_ok(f"start:{entry.unit}"):
        try:
            await callback.answer(_ans("⏳ Уже выполняется, подождите"), show_alert=False)
        except TelegramBadRequest:
            pass
        return
    try:
        await callback.answer(_ans(f"▶ Запуск {entry.name}..."))
    except TelegramBadRequest:
        pass
    # [ИСПРАВЛЕНО v2.5] явный start отменяет ожидание предыдущего рестарта
    if _alerts_mod.alert_monitor is not None:
        await _alerts_mod.alert_monitor.clear_pending_restart(entry.unit)
    ok, msg = await control("start", entry.unit)
    if ok:
        await callback.message.edit_text(f"✅ {entry.name} запущен", parse_mode=None)
    else:
        await callback.message.edit_text(f"❌ Ошибка запуска {entry.name}:\n{msg}", parse_mode=None)

@router.callback_query(F.data.startswith("stop:"))
async def callback_stop(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    service_name, _fp = _parse_name_fp(callback.data.split(":", 1)[1])
    entry = get_registry().get(service_name)
    if not entry:
        try:
            await callback.answer(_ans(f"❌ Сервис '{service_name}' не найден"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    if _fp != get_registry().fingerprint():
        await _reject_stale(callback)
        return
    # [ИСПРАВЛЕНО v2.1-22, доп. правка] 51->32 — см. cmd_stop_service.
    safe_name = _truncate_utf8(service_name, 32)
    confirm_fp = get_registry().fingerprint()
    keyboard = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Да, остановить", callback_data=f"confirm_stop:{safe_name}:{confirm_fp}"),
        InlineKeyboardButton(text="❌ Отмена", callback_data=f"cancel_stop:{safe_name}")
    ]])
    await callback.message.edit_text(
        f"⚠️ <b>Подтверждение действия</b>\n\nВы действительно хотите остановить <b>{escape_html(entry.name)}</b>?\n\nЭто действие остановит сервис.",
        parse_mode="HTML", reply_markup=keyboard
    )
    try:
        await callback.answer()
    except TelegramBadRequest:
        pass

@router.callback_query(F.data.startswith("restart:"))
async def callback_restart(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    service_name, _fp = _parse_name_fp(callback.data.split(":", 1)[1])
    entry = get_registry().get(service_name)
    if not entry:
        try:
            await callback.answer(_ans(f"❌ Сервис '{service_name}' не найден"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    if _fp != get_registry().fingerprint():
        await _reject_stale(callback)
        return
    # [ИСПРАВЛЕНО v2.1-22, доп. правка] 48->32 — см. cmd_stop_service.
    safe_name = _truncate_utf8(service_name, 32)
    confirm_fp = get_registry().fingerprint()
    keyboard = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Да, перезапустить", callback_data=f"confirm_restart:{safe_name}:{confirm_fp}"),
        InlineKeyboardButton(text="❌ Отмена", callback_data=f"cancel_restart:{safe_name}")
    ]])
    await callback.message.edit_text(
        f"⚠️ <b>Подтверждение действия</b>\n\nВы действительно хотите перезапустить <b>{escape_html(entry.name)}</b>?\n\nЭто действие перезапустит сервис.",
        parse_mode="HTML", reply_markup=keyboard
    )
    try:
        await callback.answer()
    except TelegramBadRequest:
        pass

@router.callback_query(F.data.startswith("confirm_stop:"))
async def callback_confirm_stop(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    service_name, _fp = _parse_name_fp(callback.data.split(":", 1)[1])
    entry = get_registry().get(service_name)
    if not entry:
        try:
            await callback.answer(_ans(f"❌ Сервис '{service_name}' не найден"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    if _fp != get_registry().fingerprint():
        await _reject_stale(callback)
        return
    if not _cooldown_ok(f"stop:{entry.unit}"):
        try:
            await callback.answer(_ans("⏳ Уже выполняется, подождите"), show_alert=False)
        except TelegramBadRequest:
            pass
        return
    try:
        await callback.answer(_ans(f"⏹ Остановка {entry.name}..."))
    except TelegramBadRequest:
        pass
    # [ИСПРАВЛЕНО v2.5] явный stop отменяет ожидание предыдущего рестарта
    if _alerts_mod.alert_monitor is not None:
        await _alerts_mod.alert_monitor.clear_pending_restart(entry.unit)
    ok, msg = await control("stop", entry.unit)
    if ok:
        await callback.message.edit_text(f"✅ {entry.name} остановлен", parse_mode=None)
    else:
        await callback.message.edit_text(f"❌ Ошибка остановки {entry.name}:\n{msg}", parse_mode=None)

@router.callback_query(F.data.startswith("confirm_restart:"))
async def callback_confirm_restart(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    service_name, _fp = _parse_name_fp(callback.data.split(":", 1)[1])
    entry = get_registry().get(service_name)
    if not entry:
        try:
            await callback.answer(_ans(f"❌ Сервис '{service_name}' не найден"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    if _fp != get_registry().fingerprint():
        await _reject_stale(callback)
        return
    if not _cooldown_ok(f"restart:{entry.unit}"):
        try:
            await callback.answer(_ans("⏳ Уже выполняется, подождите"), show_alert=False)
        except TelegramBadRequest:
            pass
        return
    try:
        await callback.answer(_ans(f"🔄 Перезапуск {entry.name}..."))
    except TelegramBadRequest:
        pass
    # [ИСПРАВЛЕНО v2.4] помечаем ДО control(), чтобы AlertMonitor не поймал
    # промежуточное inactive/deactivating как отдельное "падение"
    if _alerts_mod.alert_monitor is not None:
        await _alerts_mod.alert_monitor.mark_pending_restart(entry.unit)
    ok, msg = await control("restart", entry.unit)
    if ok:
        await callback.message.edit_text(f"✅ {entry.name} перезапущен", parse_mode=None)
    else:
        # [ИСПРАВЛЕНО v2.5] control() не удался — снимаем флаг, иначе он до
        # 30с подавляет алерты о реальном падении сервиса
        if _alerts_mod.alert_monitor is not None:
            await _alerts_mod.alert_monitor.clear_pending_restart(entry.unit)
        await callback.message.edit_text(f"❌ Ошибка перезапуска {entry.name}:\n{msg}", parse_mode=None)

@router.callback_query(F.data.startswith("cancel_stop:"))
async def callback_cancel_stop(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    service_name = callback.data.split(":", 1)[1]
    await callback.message.edit_text(f"❌ Остановка {service_name} отменена", parse_mode=None)
    try:
        await callback.answer()
    except TelegramBadRequest:
        pass

@router.callback_query(F.data.startswith("cancel_restart:"))
async def callback_cancel_restart(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    service_name = callback.data.split(":", 1)[1]
    await callback.message.edit_text(f"❌ Перезапуск {service_name} отменён", parse_mode=None)
    try:
        await callback.answer()
    except TelegramBadRequest:
        pass

@router.callback_query(F.data.startswith("logs:"))
async def callback_logs(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    service_name = callback.data.split(":", 1)[1]
    entry = get_registry().get(service_name)
    if not entry:
        try:
            await callback.answer(_ans(f"❌ Сервис '{service_name}' не найден"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    try:
        await callback.answer(_ans(f"📜 Загрузка логов {entry.name}..."))
    except TelegramBadRequest:
        pass
    try:
        # 1.3: увеличено с 10 до 30 строк для лучшего контекста диагностики
        logs = await tail(entry.unit, n=30)
    except Exception as e:
        await callback.message.reply(f"❌ Ошибка получения логов: {escape_html(str(e))}", parse_mode="HTML")
        return
    if not logs or logs.startswith("[error"):
        await callback.message.reply(f"📭 Логи для <b>{escape_html(entry.name)}</b> пусты", parse_mode="HTML")
        return
    formatted = _format_logs_html(logs)
    # FIX DEF-02-CALLBACKS: аналог исправления в commands.py (cmd_logs).
    # Оригинальный formatted[-4000:] резал уже отформатированный HTML —
    # граница 4000 символов могла попасть внутрь <code>...</code>,
    # Telegram возвращал BadRequest "can't parse entities".
    # Исправление: то же что в cmd_logs — обрезаем raw строки ДО форматирования.
    if len(formatted) > 4000:
        raw_lines = logs.strip().splitlines()
        selected: list[str] = []
        budget = 3800
        for line in reversed(raw_lines):
            estimated = len(_format_logs_html(line)) + 1
            if budget - estimated < 0:
                break
            selected.insert(0, line)
            budget -= estimated
        formatted = _format_logs_html("\n".join(selected)) if selected else _format_logs_html(raw_lines[-1][:3800] if raw_lines else "")
    await callback.message.reply(
        f"📜 <b>Логи {escape_html(entry.name)}</b> (последние 30 строк):\n\n{formatted}",
        parse_mode="HTML"
    )

@router.callback_query(F.data.startswith("info:"))
async def callback_info(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    service_name = callback.data.split(":", 1)[1]
    entry = get_registry().get(service_name)
    if not entry:
        try:
            await callback.answer(_ans(f"❌ Сервис '{service_name}' не найден"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    from ..cache import status_cache  # already imported at module level
    statuses = await status_cache.get_statuses([entry.unit])
    st = statuses.get(entry.unit)
    if not st:
        try:
            await callback.answer(_ans(f"❌ Не удалось получить статус {entry.unit}"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    uptime_str = "—"
    if st.uptime_sec is not None:
        sec = int(st.uptime_sec)
        uptime_str = f"{sec // 86400}д {(sec % 86400) // 3600:02d}:{(sec % 3600) // 60:02d}"
    memory_str = f"{st.memory_bytes / 1048576:.1f} MB" if st.memory_bytes > 0 else "—"
    safe_name = escape_html(entry.name)
    safe_desc = escape_html(entry.description) if entry.description else "—"
    safe_group = escape_html(entry.group)
    text = (
        f"ℹ️ <b>{safe_name}</b>\n\n"
        f"Unit: <code>{escape_html(entry.unit)}</code>\n"
        f"Описание: {safe_desc}\n"
        f"Группа: {safe_group}\n"
        f"Критический: {'Да' if entry.critical else 'Нет'}\n\n"
        # FIX DEF-07: escape_html для st.active и st.sub
        f"Статус: {escape_html(st.active)} ({escape_html(st.sub)})\n"
        f"Uptime: {uptime_str}\n"
        f"PID: {st.main_pid or '—'}\n"
        f"Memory: {memory_str}\n"
        f"Restarts: {st.restarts}"
    )
    await callback.message.reply(text, parse_mode="HTML")
    try:
        await callback.answer()
    except TelegramBadRequest:
        pass
PY

write_file "$APP_DIR/src/gopanel/bot/handlers/bulk.py" <<'PY'
"""[ФИЧА v2.1-3] Массовые операции над сервисами (рестарт/стоп: все / critical / по группе)"""
from __future__ import annotations
import logging
from aiogram import Router, F
from aiogram.types import Message, CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton
from aiogram.exceptions import TelegramBadRequest
from ..auth import check_authorization, check_callback_authorization
from ...registry import get_registry
from ...systemd import control
from ...docker import docker_control
from .alerts import escape_html
from . import alerts as _alerts_mod
from .callbacks import _cooldown_ok  # [ИСПРАВЛЕНО v2.1-38]

log = logging.getLogger("gopanel.bot.handlers.bulk")
router = Router()

_MAX_LISTED = 20


def _ans(text: str, limit: int = 195) -> str:
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _sorted_groups() -> list[str]:
    return sorted({e.group for e in get_registry().list()})


def _targets_for(scope: str, group: str | None = None) -> list:
    if scope == "docker_all":
        # [ИСПРАВЛЕНО v2.1-10] контейнеры Docker в массовых операциях
        return list(get_registry().list_containers())
    entries = get_registry().list()
    if scope == "critical":
        return [e for e in entries if e.critical]
    if scope == "group":
        return [e for e in entries if e.group == group]
    return list(entries)


def _scope_label(scope: str, group: str | None = None) -> str:
    if scope == "critical":
        return "критических сервисов"
    if scope == "group":
        return f"сервисов группы «{escape_html(group or '')}»"
    if scope == "docker_all":
        return "Docker-контейнеров"
    return "всех сервисов"


def _bulk_menu_keyboard() -> InlineKeyboardMarkup:
    entries = get_registry().list()
    critical_count = sum(1 for e in entries if e.critical)
    total_count = len(entries)
    # [ИСПРАВЛЕНО v2.1-10] контейнеры Docker в массовых операциях
    container_count = len(get_registry().list_containers())
    rows = [
        [InlineKeyboardButton(text=f"🔄 Перезапустить CRITICAL ({critical_count})",
                               callback_data="bulk:restart:critical", style="primary")],
        [InlineKeyboardButton(text=f"⏹ Остановить CRITICAL ({critical_count})",
                               callback_data="bulk:stop:critical", style="danger")],
        [InlineKeyboardButton(text="🔄 Перезапустить группу...", callback_data="bulk:restart:group_select")],
        [InlineKeyboardButton(text="⏹ Остановить группу...", callback_data="bulk:stop:group_select")],
        [InlineKeyboardButton(text=f"🔄 Перезапустить ВСЕ ({total_count})",
                               callback_data="bulk:restart:all", style="primary")],
        [InlineKeyboardButton(text=f"⏹ Остановить ВСЕ ({total_count})",
                               callback_data="bulk:stop:all", style="danger")],
    ]
    if container_count:
        rows.append([InlineKeyboardButton(text=f"🐳 Перезапустить контейнеры ({container_count})",
                                           callback_data="bulk:restart:docker_all", style="primary")])
        rows.append([InlineKeyboardButton(text=f"🐳 Остановить контейнеры ({container_count})",
                                           callback_data="bulk:stop:docker_all", style="danger")])
    rows.append([InlineKeyboardButton(text="❌ Отмена", callback_data="bulk:cancel")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def _group_select_keyboard(act: str) -> InlineKeyboardMarkup:
    # [ФИЧА v2.1-3] group без regex-ограничений (в отличие от name) — не
    # встраиваем текст группы в callback_data напрямую (не только из-за
    # лимита 64 байт, но и риска ":" в имени группы ломающего наш парсинг
    # по split(":")). Вместо этого — индекс в отсортированном списке групп,
    # список пересчитывается заново при нажатии (см. bulk_router).
    # [ИСПРАВЛЕНО v2.1-22] индекс сам по себе не защищает от случая, когда
    # список групп изменился (добавили/удалили сервис/группу) между показом
    # клавиатуры и нажатием — тот же индекс мог начать указывать на другую
    # группу без IndexError. Добавлен отпечаток реестра (см. Registry.fingerprint()).
    groups = _sorted_groups()
    fp = get_registry().fingerprint()
    entries = get_registry().list()
    counts: dict[str, int] = {}
    for e in entries:
        counts[e.group] = counts.get(e.group, 0) + 1
    rows: list[list[InlineKeyboardButton]] = []
    row: list[InlineKeyboardButton] = []
    for i, group in enumerate(groups):
        row.append(InlineKeyboardButton(text=f"{group} ({counts.get(group, 0)})",
                                         callback_data=f"bulk:{act}:group:{i}:{fp}"))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append([InlineKeyboardButton(text="← Назад", callback_data="bulk:menu")])
    rows.append([InlineKeyboardButton(text="❌ Отмена", callback_data="bulk:cancel")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


async def _show_confirmation(callback: CallbackQuery, act: str, scope: str, targets: list,
                              group: str | None, group_idx: str | None = None):
    if not targets:
        try:
            await callback.answer(_ans("📭 Нет сервисов, подпадающих под выбор"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    verb = "Перезапустить" if act == "restart" else "Остановить"
    listed = "\n".join(f"  • {escape_html(e.name)}" for e in targets[:_MAX_LISTED])
    if len(targets) > _MAX_LISTED:
        listed += f"\n  ... и ещё {len(targets) - _MAX_LISTED}"
    label = _scope_label(scope, group)
    do_data = f"bulk:do:{act}:{scope}"
    if scope == "group":
        do_data += f":{group_idx}"
    else:
        # [ИСПРАВЛЕНО v2.1-30] all/critical/docker_all не имели отпечатка —
        # тот же класс TOCTOU, что уже закрыт для group: между показом
        # подтверждения и нажатием «Да» состав сервисов/контейнеров мог
        # измениться, а bulk_router пересчитывал targets заново без проверки.
        # docker_all сверяется по container_fingerprint(), остальные — по
        # обычному fingerprint() сервисов.
        do_data += f":{get_registry().container_fingerprint() if scope == 'docker_all' else get_registry().fingerprint()}"
    keyboard = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=f"✅ Да, {verb.lower()}", callback_data=do_data,
                               style="primary" if act == "restart" else "danger")],
        [InlineKeyboardButton(text="❌ Отмена", callback_data="bulk:cancel")],
    ])
    await callback.message.edit_text(
        f"⚠️ <b>Подтверждение</b>\n\n{verb} {len(targets)} {label}?\n\n{listed}",
        parse_mode="HTML", reply_markup=keyboard,
    )


@router.message(lambda m: m.text == "⚡ Массовые")
async def btn_bulk(message: Message):
    if not await check_authorization(message):
        return
    await message.reply("⚡ <b>Массовые операции</b>\n\nЧто выполнить?",
                         parse_mode="HTML", reply_markup=_bulk_menu_keyboard())


@router.callback_query(F.data.startswith("bulk:"))
async def bulk_router(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    parts = callback.data.split(":")
    action = parts[1]

    if action == "menu":
        try:
            await callback.answer()
        except TelegramBadRequest:
            pass
        await callback.message.edit_text("⚡ <b>Массовые операции</b>\n\nЧто выполнить?",
                                          parse_mode="HTML", reply_markup=_bulk_menu_keyboard())
        return

    if action == "cancel":
        try:
            await callback.answer()
        except TelegramBadRequest:
            pass
        await callback.message.edit_text("❌ Массовые операции отменены", parse_mode="HTML")
        return

    if action in ("restart", "stop") and len(parts) == 3 and parts[2] in ("critical", "all", "docker_all"):
        scope = parts[2]
        try:
            await callback.answer()
        except TelegramBadRequest:
            pass
        await _show_confirmation(callback, action, scope, _targets_for(scope), group=None)
        return

    if action in ("restart", "stop") and len(parts) == 3 and parts[2] == "group_select":
        try:
            await callback.answer()
        except TelegramBadRequest:
            pass
        await callback.message.edit_text(
            f"{'🔄 Перезапустить' if action == 'restart' else '⏹ Остановить'} группу\n\nВыберите группу:",
            parse_mode="HTML", reply_markup=_group_select_keyboard(action),
        )
        return

    if action in ("restart", "stop") and len(parts) == 5 and parts[2] == "group":
        # [ИСПРАВЛЕНО v2.1-22] сначала проверяем отпечаток реестра — если он
        # изменился с момента показа клавиатуры, тот же индекс мог начать
        # указывать на другую группу без IndexError.
        if parts[4] != get_registry().fingerprint():
            try:
                await callback.answer(_ans("⚠️ Список групп изменился, попробуйте снова"), show_alert=True)
            except TelegramBadRequest:
                pass
            await callback.message.edit_text("⚡ <b>Массовые операции</b>\n\nЧто выполнить?",
                                              parse_mode="HTML", reply_markup=_bulk_menu_keyboard())
            return
        try:
            idx = int(parts[3])
            group = _sorted_groups()[idx]
        except (ValueError, IndexError):
            try:
                await callback.answer(_ans("⚠️ Список групп изменился, попробуйте снова"), show_alert=True)
            except TelegramBadRequest:
                pass
            await callback.message.edit_text("⚡ <b>Массовые операции</b>\n\nЧто выполнить?",
                                              parse_mode="HTML", reply_markup=_bulk_menu_keyboard())
            return
        try:
            await callback.answer()
        except TelegramBadRequest:
            pass
        await _show_confirmation(callback, action, "group", _targets_for("group", group=group),
                                  group=group, group_idx=f"{parts[3]}:{parts[4]}")
        return

    if action == "do":
        act = parts[2]
        scope = parts[3]
        group = None
        if scope == "group":
            # [ИСПРАВЛЕНО v2.1-22] тот же отпечаток, что и на шаге выбора группы —
            # если реестр изменился уже ПОСЛЕ выбора группы, но ДО подтверждения,
            # операция тоже отклоняется, а не выполняется над другой группой.
            # [ИСПРАВЛЕНО v2.1-31] не было проверки длины перед parts[5] —
            # в отличие от else-ветки ниже (len(parts) < 5). Устаревшая кнопка
            # из версии до v2.1-22 (5 полей вместо 6) валила бы IndexError.
            if len(parts) < 6 or parts[5] != get_registry().fingerprint():
                try:
                    await callback.answer(_ans("⚠️ Список групп изменился"), show_alert=True)
                except TelegramBadRequest:
                    pass
                return
            try:
                idx = int(parts[4])
                group = _sorted_groups()[idx]
            except (ValueError, IndexError):
                try:
                    await callback.answer(_ans("⚠️ Список групп изменился"), show_alert=True)
                except TelegramBadRequest:
                    pass
                return
        else:
            # [ИСПРАВЛЕНО v2.1-30] см. комментарий у do_data в _show_confirmation.
            expected_fp = get_registry().container_fingerprint() if scope == "docker_all" else get_registry().fingerprint()
            if len(parts) < 5 or parts[4] != expected_fp:
                try:
                    await callback.answer(_ans("⚠️ Список изменился, попробуйте снова"), show_alert=True)
                except TelegramBadRequest:
                    pass
                return
        targets = _targets_for(scope, group=group)
        if not targets:
            try:
                await callback.answer(_ans("📭 Нет сервисов, подпадающих под выбор"), show_alert=True)
            except TelegramBadRequest:
                pass
            return
        # [ИСПРАВЛЕНО v2.1-38] (Medium): защита от двойного тапа - иначе два параллельных
        # прохода перезапускают каждый сервис/контейнер дважды.
        if not _cooldown_ok(f"bulk:{act}:{scope}:{group}"):
            try:
                await callback.answer(_ans("⏳ Уже выполняется"), show_alert=False)
            except TelegramBadRequest:
                pass
            return
        noun = "контейнеров" if scope == "docker_all" else "сервисов"
        try:
            await callback.answer(_ans(f"⏳ Выполняю для {len(targets)} {noun}..."))
        except TelegramBadRequest:
            pass
        await callback.message.edit_text(
            f"⏳ {'Перезапускаю' if act == 'restart' else 'Останавливаю'} {len(targets)} {noun}...",
            parse_mode="HTML",
        )

        results = []
        # [ИСПРАВЛЕНО v2.1-10] контейнеры используют docker_control(name), у
        # них нет .unit — и pending-restart флаг для них не нужен (детекция
        # рестарта в _do_refresh/_check_statuses работает только для systemd)
        # [ИСПРАВЛЕНО v2.1-41] примечание к комментарию выше: с v2.1-38 падения critical-контейнеров
        # детектируются отдельно (alerts.py: _check_containers, подтверждение двумя
        # опросами), поэтому штатный рестарт ложных алертов не даёт и флаг по-прежнему не нужен.
        is_docker = scope == "docker_all"
        for entry in targets:
            if not is_docker and act == "restart" and entry.critical and _alerts_mod.alert_monitor is not None:
                # [ИСПРАВЛЕНО v2.1-30] флаг раньше ставился для ЛЮБОГО сервиса,
                # включая некритические — хотя TUI._ctrl (v2.5) ставит его
                # только для critical, и сам restart-notice всё равно гейтуется
                # critical (v2.1-28). Для некритических флаг был архитектурно
                # лишним: жил в SQLite до истечения таймаута без какого-либо
                # потребителя. Добавлено entry.critical — симметрично с TUI.
                # [ФИЧА v2.1-3] помечаем ПЕРЕД control() для КАЖДОГО сервиса
                # индивидуально (а не всех сразу до цикла) — та же защита от
                # ложного "остановлен"+"восстановлен" вместо "рестарт", что и
                # в одиночном рестарте (v2.4-v2.5), но с полным 30с окном на
                # сервис независимо от его очереди в списке.
                await _alerts_mod.alert_monitor.mark_pending_restart(entry.unit)
            if is_docker:
                ok, msg = await docker_control(act, entry.name)
            else:
                ok, msg = await control(act, entry.unit)
                # [ИСПРАВЛЕНО v2.1-18] при неуспешном control() флаг не
                # снимался (в отличие от одиночного restart, см. v2.5 в
                # callbacks.py) — реальное падение сервиса до 120с подавлялось
                # AlertMonitor'ом как "ожидаемый рестарт".
                if not ok and act == "restart" and _alerts_mod.alert_monitor is not None:
                    await _alerts_mod.alert_monitor.clear_pending_restart(entry.unit)
            results.append((entry.name, ok, msg))

        success = [r for r in results if r[1]]
        failed = [r for r in results if not r[1]]

        report_lines = [f"✅ Успешно: {len(success)}"]
        if failed:
            report_lines.append(f"❌ Ошибки: {len(failed)}")
            for name, _ok, msg in failed[:5]:
                report_lines.append(f"  • {escape_html(name)}: {escape_html(str(msg)[:60])}")
            if len(failed) > 5:
                report_lines.append(f"  ... и ещё {len(failed) - 5}")

        await callback.message.edit_text(
            "⚡ <b>Результат</b>\n\n" + "\n".join(report_lines),
            parse_mode="HTML",
        )
        return

    try:
        await callback.answer(_ans("Неизвестное действие"), show_alert=True)
    except TelegramBadRequest:
        pass
PY

write_file "$APP_DIR/src/gopanel/bot/handlers/docker.py" <<'PY'
"""[ФИЧА v2.1-4] Секция бота для Docker-контейнеров — та же структура
взаимодействия, что у одиночного управления сервисом (start сразу,
stop/restart через подтверждение, logs, info), но единым роутером
F.data.startswith("docker:") по аналогии с bulk.py."""
from __future__ import annotations
import logging
from aiogram import Router, F
from aiogram.types import Message, CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton
from aiogram.exceptions import TelegramBadRequest
from ..auth import check_callback_authorization
from ...registry import get_registry
from ...docker import docker_control, docker_logs
from .alerts import escape_html
from .commands import _format_logs_html
# [ИСПРАВЛЕНО v2.1-18] у systemd-обработчиков (callbacks.py, v2.1-14) уже
# есть защита от повторных конкурентных нажатий — у Docker-кнопок её не было,
# 2-3 быстрых тапа "Да, перезапустить" запускали столько же параллельных
# docker restart. Переиспользуем тот же _cooldown_ok/_last_control.
from .callbacks import _cooldown_ok, _parse_name_fp, _reject_stale

log = logging.getLogger("gopanel.bot.handlers.docker")
router = Router()


def _ans(text: str, limit: int = 195) -> str:
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _not_found(name: str) -> str:
    return f"❌ Контейнер '{name}' не найден в реестре"


@router.callback_query(F.data == "noop")
async def callback_noop(callback: CallbackQuery):
    # [ФИЧА v2.1-4] заголовок-разделитель "── 🐳 Docker ──" в панели —
    # без обработчика Telegram держал бы "часики" на кнопке до таймаута
    try:
        await callback.answer()
    except TelegramBadRequest:
        pass


@router.callback_query(F.data.startswith("docker:"))
async def docker_router(callback: CallbackQuery):
    if not await check_callback_authorization(callback):
        return
    parts = callback.data.split(":", 2)
    if len(parts) != 3:
        try:
            await callback.answer(_ans("Некорректные данные кнопки"), show_alert=True)
        except TelegramBadRequest:
            pass
        return
    _, action, tail = parts
    # [ИСПРАВЛЕНО v2.1-29] info/logs/cancel не несут отпечаток (не выполняют
    # действий над контейнером), start/stop/restart/confirm_* несут — см.
    # _parse_name_fp (переиспользован из callbacks.py, тот же импорт, что и
    # _cooldown_ok выше).
    name, _dfp = _parse_name_fp(tail)
    c = get_registry().get_container(name)
    if not c:
        try:
            await callback.answer(_ans(_not_found(name)), show_alert=True)
        except TelegramBadRequest:
            pass
        return

    if action == "start":
        if _dfp != get_registry().container_fingerprint():
            await _reject_stale(callback)
            return
        # [ИСПРАВЛЕНО v2.1-18] anti-double-tap, см. импорт _cooldown_ok выше
        if not _cooldown_ok(f"docker:{c.name}"):
            try:
                await callback.answer()
            except TelegramBadRequest:
                pass
            return
        try:
            await callback.answer(_ans(f"▶ Запуск {c.name}..."))
        except TelegramBadRequest:
            pass
        ok, msg = await docker_control("start", c.name)
        text = f"✅ {c.name} запущен" if ok else f"❌ Ошибка запуска {c.name}:\n{msg}"
        await callback.message.edit_text(text, parse_mode=None)
        return

    if action in ("stop", "restart"):
        if _dfp != get_registry().container_fingerprint():
            await _reject_stale(callback)
            return
        verb = "остановить" if action == "stop" else "перезапустить"
        confirm_dfp = get_registry().container_fingerprint()
        keyboard = InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text=f"✅ Да, {verb}", callback_data=f"docker:confirm_{action}:{c.name}:{confirm_dfp}"),
            InlineKeyboardButton(text="❌ Отмена", callback_data=f"docker:cancel:{c.name}"),
        ]])
        await callback.message.edit_text(
            f"⚠️ <b>Подтверждение действия</b>\n\nВы действительно хотите {verb} <b>{escape_html(c.name)}</b>?",
            parse_mode="HTML", reply_markup=keyboard,
        )
        try:
            await callback.answer()
        except TelegramBadRequest:
            pass
        return

    if action in ("confirm_stop", "confirm_restart"):
        if _dfp != get_registry().container_fingerprint():
            await _reject_stale(callback)
            return
        act = "stop" if action == "confirm_stop" else "restart"
        # [ИСПРАВЛЕНО v2.1-18] anti-double-tap, см. импорт _cooldown_ok выше
        if not _cooldown_ok(f"docker:{c.name}"):
            try:
                await callback.answer()
            except TelegramBadRequest:
                pass
            return
        verb = "Останавливаю" if act == "stop" else "Перезапускаю"
        try:
            await callback.answer(_ans(f"⏳ {verb} {c.name}..."))
        except TelegramBadRequest:
            pass
        ok, msg = await docker_control(act, c.name)
        done_verb = "остановлен" if act == "stop" else "перезапущен"
        text = f"✅ {c.name} {done_verb}" if ok else f"❌ Ошибка ({act}) {c.name}:\n{msg}"
        await callback.message.edit_text(text, parse_mode=None)
        return

    if action == "cancel":
        try:
            await callback.answer(_ans("Отменено"))
        except TelegramBadRequest:
            pass
        await callback.message.edit_text(f"❌ Действие для {c.name} отменено", parse_mode=None)
        return

    if action == "logs":
        try:
            await callback.answer(_ans(f"📜 Загрузка логов {c.name}..."))
        except TelegramBadRequest:
            pass
        try:
            logs = await docker_logs(c.name)
        except Exception as e:
            await callback.message.reply(f"❌ Ошибка получения логов: {escape_html(str(e))}", parse_mode="HTML")
            return
        if not logs or logs.startswith("[error"):
            await callback.message.reply(f"📭 Логи для <b>{escape_html(c.name)}</b> пусты или недоступны", parse_mode="HTML")
            return
        formatted = _format_logs_html(logs)
        # [ФИЧА v2.1-4] тот же приём, что в callback_logs (systemd): режем
        # RAW-строки ДО HTML-форматирования, а не готовый HTML, иначе граница
        # 4000 символов может попасть внутрь <code>...</code>
        if len(formatted) > 4000:
            raw_lines = logs.strip().splitlines()
            selected: list[str] = []
            budget = 3800
            for line in reversed(raw_lines):
                estimated = len(_format_logs_html(line)) + 1
                if budget - estimated < 0:
                    break
                selected.insert(0, line)
                budget -= estimated
            formatted = _format_logs_html("\n".join(selected)) if selected else _format_logs_html(raw_lines[-1][:3800] if raw_lines else "")
        await callback.message.reply(
            f"📜 <b>Логи {escape_html(c.name)}</b> (последние 200 строк):\n\n{formatted}",
            parse_mode="HTML",
        )
        return

    if action == "info":
        try:
            await callback.answer()
        except TelegramBadRequest:
            pass
        text = (
            f"🐳 <b>{escape_html(c.name)}</b>\n\n"
            f"Образ: <code>{escape_html(c.image)}</code>\n"
            f"Группа: {escape_html(c.group)}\n"
            f"Критический: {'Да' if c.critical else 'Нет'}\n"
            f"Описание: {escape_html(c.description) if c.description else '—'}"
        )
        await callback.message.reply(text, parse_mode="HTML")
        return

    try:
        await callback.answer(_ans("Неизвестное действие"), show_alert=True)
    except TelegramBadRequest:
        pass
PY

write_file "$APP_DIR/src/gopanel/bot/main.py" <<'PY'
"""Точка входа Telegram-бота"""
from __future__ import annotations
import asyncio
import logging
import sys
from pathlib import Path
from aiogram import Bot, Dispatcher
from aiogram.enums import ParseMode
from aiogram.client.default import DefaultBotProperties
from aiogram.types import BotCommand, BotCommandScopeAllPrivateChats
from .config import config
from .handlers import commands, callbacks, alerts, bulk, docker as docker_handlers

log = logging.getLogger("gopanel.bot")

def setup_logging():
    log_path = Path("/var/log/gopanel/bot.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    fmt = "%(asctime)s %(levelname)-7s %(name)s: %(message)s"
    # FIX LOG-ROTATE: заменяем RotatingFileHandler на FileHandler.
    # RotatingFileHandler переименовывал bot.log → bot.log.1 при 5MB,
    # создавая конфликт с logrotate (copytruncate). Оба механизма
    # ротировали независимо, засоряя /var/log/gopanel смешанными артефактами.
    # Ротация целиком делегирована logrotate — copytruncate обнуляет файл
    # на месте, Python продолжает писать в тот же fd без переоткрытия.
    handlers = [
        logging.StreamHandler(sys.stderr),
        logging.FileHandler(log_path, encoding="utf-8")
    ]
    log_level = getattr(logging, config.log_level.upper(), logging.INFO)
    logging.basicConfig(level=log_level, format=fmt, handlers=handlers)
    logging.getLogger("asyncio").setLevel(logging.WARNING)
    logging.getLogger("aiogram").setLevel(logging.WARNING)

async def setup_bot_commands(bot: Bot):
    """Регистрирует команды в меню бота — кнопка / в поле ввода."""
    await bot.set_my_commands(
        [
            BotCommand(command="start",           description="🎛 Панель управления сервисами"),
            BotCommand(command="status",          description="📊 Статус всех сервисов"),
            BotCommand(command="help",            description="📖 Справка"),
        ],
        scope=BotCommandScopeAllPrivateChats()
    )
    log.info("Bot commands registered")

async def main():
    setup_logging()
    log.info("Starting GoPanel Bot v2.1")
    if not config.validate():
        log.error("Invalid configuration, exiting")
        sys.exit(1)
    bot = Bot(
        token=config.telegram_token,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML)
    )
    dp = Dispatcher()
    dp.include_router(commands.router)
    dp.include_router(callbacks.router)
    dp.include_router(bulk.router)
    dp.include_router(docker_handlers.router)
    log.info("Handlers registered")

    await setup_bot_commands(bot)

    alert_monitor = alerts.create_alert_monitor(bot)
    try:
        log.info("Starting bot polling and alert monitor")
        async def _safe_monitor():
            # FIX DEF-01: оригинальный _safe_monitor() логировал исключение
            # и завершался молча. asyncio.gather() продолжал работу с polling,
            # но мониторинг был мёртв — алерты переставали приходить без
            # каких-либо видимых признаков в боте.
            # Исправление: цикл автоперезапуска с экспоненциальной задержкой.
            # После 5 подряд упавших попыток за короткое время — завершаем
            # _safe_monitor и даём systemd перезапустить весь процесс бота.
            MAX_CRASHES = 5
            CRASH_WINDOW = 60.0   # секунд — окно подсчёта частых сбоев
            crash_times: list[float] = []
            delay = 5.0
            while True:
                try:
                    await alert_monitor.start()
                    # start() вернулся без исключения — штатное завершение
                    log.info("Alert monitor exited cleanly")
                    return
                except asyncio.CancelledError:
                    # Отмена при завершении приложения — выходим без перезапуска
                    log.info("Alert monitor cancelled, stopping")
                    return
                except Exception as e:
                    now = asyncio.get_running_loop().time()
                    crash_times.append(now)
                    # Убираем старые записи за пределами окна
                    crash_times = [t for t in crash_times if now - t < CRASH_WINDOW]
                    log.error(
                        "Alert monitor crashed (attempt %d/%d): %s",
                        len(crash_times), MAX_CRASHES, e, exc_info=True
                    )
                    if len(crash_times) >= MAX_CRASHES:
                        log.critical(
                            "Alert monitor crashed %d times in %.0f seconds — "
                            "giving up, systemd will restart the bot",
                            MAX_CRASHES, CRASH_WINDOW
                        )
                        # Завершаем весь процесс чтобы systemd перезапустил бота.
                        # Простой return из _safe_monitor оставил бы dp.start_polling
                        # работать, и systemd не получил бы сигнала о сбое.
                        raise SystemExit(1)
                    log.info("Restarting alert monitor in %.0f seconds...", delay)
                    await asyncio.sleep(delay)
                    delay = min(delay * 2, 120.0)  # экспоненциальная задержка, макс 2 мин
        # [ИСПРАВЛЕНО v2.1-25] asyncio.gather() ждёт ОБЕ задачи. aiogram сам
        # ловит SIGTERM и корректно завершает dp.start_polling(), но
        # _safe_monitor() при этом продолжает крутиться в alert_monitor.start()
        # — а именно stop(), который мог бы его остановить, лежит в finally,
        # куда gather() не передаёт управление, пока НЕ завершены ОБЕ задачи.
        # Круговая зависимость подтверждена эмпирически: реальный SIGTERM
        # против реального aiogram — polling останавливается мгновенно, но
        # процесс живёт до SIGKILL, finally не достигается никогда.
        # Fix: ждём, пока завершится ПЕРВАЯ из задач (обычно polling — как
        # раз он реагирует на сигнал), и явно отменяем оставшуюся, вместо
        # того чтобы полагаться на gather(), которому нужны обе.
        _poll_task = asyncio.ensure_future(dp.start_polling(bot))
        _mon_task = asyncio.ensure_future(_safe_monitor())
        try:
            _done, _pending = await asyncio.wait(
                [_poll_task, _mon_task], return_when=asyncio.FIRST_COMPLETED
            )
        except BaseException:
            # [ИСПРАВЛЕНО v2.1-26, уточнено] проверено изолированным тестом:
            # asyncio.wait() для обычных Exception действительно возвращается
            # штатно с (done, pending) — здесь DeepSeek прав, это
            # задокументированное поведение. Но SystemExit(1) из _safe_monitor
            # (защита от crash-loop, см. FIX DEF-01 выше) — BaseException, и
            # Task._step его не глотает: он пробивает прямо через
            # run_until_complete()/_run_once() событийного цикла, минуя
            # обычный протокол Task/Future — на практике в этот except
            # попадает CancelledError, доставленный текущей корутине как
            # побочный эффект этого прерывания, а не сам SystemExit. Сам
            # SystemExit(1) при этом всё равно долетает наружу до
            # asyncio.run() с кодом 1 — независимо от этого except.
            # Тут нам важно только: код ниже (отмена/разбор _done) в этом
            # случае не выполняется, поэтому отменяем и дожидаемся обеих
            # задач здесь же — это и "читает" исключение _mon_task через
            # return_exceptions=True, убирая "Task exception was never
            # retrieved" в логах. finally по-прежнему отрабатывает штатно.
            for _t in (_poll_task, _mon_task):
                if not _t.done():
                    _t.cancel()
            await asyncio.gather(_poll_task, _mon_task, return_exceptions=True)
            raise
        for _t in _pending:
            _t.cancel()
        if _pending:
            await asyncio.gather(*_pending, return_exceptions=True)
        for _t in _done:
            exc = _t.exception()
            if exc is not None and not isinstance(exc, asyncio.CancelledError):
                raise exc
    except Exception as e:
        log.error("Bot error: %s", e)
        raise
    finally:
        log.info("Shutting down...")
        # [ИСПРАВЛЕНО v2.1-23] оба вызова раньше не имели верхнего таймаута —
        # если alert_monitor.stop() или закрытие aiohttp-сессии подвисали,
        # graceful shutdown упирался в TimeoutStopSec systemd и завершался
        # по SIGKILL (наблюдалось в production: "stop-sigterm timed out").
        try:
            await asyncio.wait_for(alert_monitor.stop(), timeout=5.0)
        except asyncio.TimeoutError:
            log.warning("Alert monitor stop timed out, continuing shutdown")
        try:
            await asyncio.wait_for(bot.session.close(), timeout=5.0)
        except asyncio.TimeoutError:
            log.warning("Bot session close timed out")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("Interrupted by user")
    except Exception as e:
        log.error("Fatal error: %s", e)
        sys.exit(1)
PY

write_file "$APP_DIR/src/gopanel/ui/screens/bot_settings.py" <<'PY'
"""Экран настроек Telegram-бота"""
from __future__ import annotations
import asyncio
import json
import logging
import subprocess
from pathlib import Path
from textual.app import ComposeResult
from textual.containers import Vertical, Horizontal
from textual.screen import Screen
from textual.widgets import Footer, Static, Input, Button, Switch, Label, Select
from ... import __version__

log = logging.getLogger("gopanel.bot_settings")

class BotSettingsScreen(Screen):
    BINDINGS = [("escape", "go_back", "Назад")]

    def __init__(self):
        super().__init__()
        self.config_path = Path("/etc/gopanel/bot.json")

    def compose(self) -> ComposeResult:
        yield Static(
            "[bold #00ffaa]Центр мониторинга и управления сервисами[/]",  # [ФИЧА v2.1-6]
            id="bot-settings-title",
            classes="large-header"
        )
        yield Static(f"v{__version__}", classes="version-subtitle")
        with Vertical():
            yield Static("⚙ Настройки Telegram-бота", classes="panel")
            config_data = self._load_config()
            yield Label("Telegram токен:")
            yield Input(
                value=config_data.get("telegram_token", ""),
                placeholder="123456789:ABCdefGHIjklMNOpqrsTUVwxyz",
                id="bot-token",
                password=True
            )
            yield Label("Авторизованные пользователи (ID через запятую):")
            auth_users = ",".join(str(u) for u in config_data.get("authorized_users", []))
            yield Input(value=auth_users, placeholder="123456789,987654321", id="bot-users")
            yield Label("Уведомления о падениях:")
            yield Switch(value=config_data.get("enable_alerts", True), id="bot-alerts")
            yield Label("Уровень логирования:")
            current_level = config_data.get("log_level", "INFO")
            yield Select(
                options=[
                    ("DEBUG — подробный отладочный вывод", "DEBUG"),
                    ("INFO — стандартный уровень", "INFO"),
                    ("WARNING — только предупреждения", "WARNING"),
                    ("ERROR — только ошибки", "ERROR"),
                ],
                value=current_level,
                id="bot-log-level",
            )
            with Horizontal():
                yield Button("💾 Сохранить настройки", id="btn-save-bot-config", variant="primary")
                yield Button("🔄 Перезапустить бота", id="btn-restart-bot", variant="default")
                yield Button("← Назад на панель", id="btn-back-to-dashboard", variant="default")
        yield Footer()

    def _load_config(self) -> dict:
        try:
            with open(self.config_path, encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            log.error("Failed to load bot config: %s", e)
            return {}

    def action_go_back(self):
        self.app.switch_screen("dashboard")

    def on_button_pressed(self, ev: Button.Pressed) -> None:
        if ev.button.id == "btn-back-to-dashboard":
            self.app.switch_screen("dashboard")
        elif ev.button.id == "btn-save-bot-config":
            asyncio.get_running_loop().create_task(self._save_config())
        elif ev.button.id == "btn-restart-bot":
            self._restart_bot()

    async def _save_config(self):
        try:
            token = self.query_one("#bot-token", Input).value
            users_str = self.query_one("#bot-users", Input).value
            alerts = self.query_one("#bot-alerts", Switch).value
            log_level = self.query_one("#bot-log-level", Select).value
            if not log_level or log_level == Select.BLANK:
                log_level = "INFO"
            log_level_upper = str(log_level).upper()
            if not token:
                self.app.throttled_notify("Токен не может быть пустым", severity="error")
                return
            user_ids = []
            for uid in users_str.split(","):
                uid = uid.strip()
                if uid and uid.isdigit():
                    user_ids.append(int(uid))
            if not user_ids:
                self.app.throttled_notify("Укажите хотя бы один Telegram ID", severity="error")
                return
            config_data = {
                "telegram_token": token,
                "authorized_users": user_ids,
                "enable_alerts": alerts,
                "status_cache_ttl_sec": 5,
                "max_log_lines": 50,
                "pagination_threshold": 10,
                "log_level": log_level_upper
            }
            config_json = json.dumps(config_data, indent=2)
            proc = await asyncio.create_subprocess_exec(
                "sudo", "-n", "/usr/local/bin/gopanel-save-bot-config",
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            _, stderr_data = await asyncio.wait_for(
                proc.communicate(config_json.encode()), timeout=10
            )
            if proc.returncode != 0:
                raise PermissionError(f"Failed to save config: {stderr_data.decode()}")
            self.app.throttled_notify(
                "✓ Настройки сохранены. Нажмите «🔄 Перезапустить бота» для применения.",
                severity="information"
            )
        except PermissionError as e:
            log.error("Permission error saving bot config: %s", e)
            self.app.throttled_notify(f"Ошибка прав: {e}.", severity="error")
        except asyncio.TimeoutError:
            # [ИСПРАВЛЕНО v2.1-33] wait_for на таймауте не убивал сам subprocess
            # (тот же класс проблемы, что уже исправлен в run_exec() из utils.py,
            # но здесь был отдельный ad-hoc вызов без переиспользования хелпера) —
            # gopanel-save-bot-config оставался висеть после того, как TUI уже
            # сообщил пользователю об ошибке.
            proc.kill()
            await proc.wait()
            log.error("Timed out saving bot config")
            self.app.throttled_notify("Ошибка сохранения: превышено время ожидания", severity="error")
        except Exception as e:
            log.error("Failed to save bot config: %s", e)
            self.app.throttled_notify(f"Ошибка сохранения: {e}", severity="error")

    def _restart_bot(self):
        self.app.throttled_notify("Перезапуск бота...", severity="information")
        import asyncio
        asyncio.get_running_loop().create_task(self._do_restart_bot())

    async def _do_restart_bot(self):
        import asyncio
        loop = asyncio.get_running_loop()
        try:
            result = await loop.run_in_executor(
                None,
                lambda: subprocess.run(
                    ["sudo", "-n", "/usr/local/bin/gopanel-restart-bot"],
                    capture_output=True, text=True, timeout=15
                )
            )
            if result.returncode == 0:
                self.app.throttled_notify("✓ Бот перезапущен", severity="information")
            else:
                err_msg = result.stderr.strip() or "неизвестная ошибка"
                log.error("Failed to restart bot: %s", err_msg)
                self.app.throttled_notify(f"Ошибка перезапуска: {err_msg}", severity="error")
        except subprocess.TimeoutExpired:
            log.error("Bot restart timed out")
            self.app.throttled_notify("Таймаут перезапуска бота", severity="error")
        except Exception as e:
            log.error("Failed to restart bot: %s", e)
            self.app.throttled_notify(f"Ошибка перезапуска: {e}", severity="error")
PY

# ======================== PYPROJECT.TOML ========================

VERSION="2.1"
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
    "textual==0.67.1",
    "psutil>=5.9.8,<6.0.0",
    "pydantic==2.7.0",
    "pydantic-settings==2.2.1",
    # [ИСПРАВЛЕНО v2.1-24] зафиксировано на 3.20.0 вместо открытого диапазона
    # <4.0.0: измерил реальный VmRSS после "import aiogram.types" на каждой
    # версии 3.20.0-3.31.0 — рост монотонный, 155MB на 3.20.0 против 400MB на
    # 3.31.0 (известная проблема pydantic-core со схемами для большого числа
    # моделей, см. aiogram issue #1513). API, используемое GoPanel, проверено
    # на 3.20.0 — полностью совместимо.
    "aiogram==3.20.0",
    "packaging"
]

[project.scripts]
gopanel = "gopanel.cli:main"
gopanel-tui = "gopanel.__main__:main"

[tool.setuptools.packages.find]
where = ["src"]

[tool.setuptools.package-data]
gopanel = ["ui/*.tcss"]
TOML


# ======================== КОНФИГИ ========================

# [ФИЧА v2.1-1] SQLite-реестр вместо services.json. При обновлении
# существующей установки — миграция данных, старый файл переименовывается
# в services.json.bak (не удаляется).
DB_FILE="$CONF_DIR/gopanel.db"
OLD_JSON="$CONF_DIR/services.json"

if [[ ! -f "$DB_FILE" ]]; then
    info "Создание SQLite-реестра ($DB_FILE)..."
    python3 - "$DB_FILE" "$OLD_JSON" <<'PYMIGRATE'
import json, sqlite3, sys, os

db_path, old_json = sys.argv[1], sys.argv[2]

conn = sqlite3.connect(db_path)
conn.executescript("""
CREATE TABLE IF NOT EXISTS services (
    name            TEXT PRIMARY KEY,
    unit            TEXT NOT NULL UNIQUE,
    group_name      TEXT NOT NULL DEFAULT 'default',
    description     TEXT NOT NULL DEFAULT '',
    critical        INTEGER NOT NULL DEFAULT 0,
    tags            TEXT NOT NULL DEFAULT '[]',
    manual_restarts INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS containers (
    name            TEXT PRIMARY KEY,
    image           TEXT NOT NULL,
    group_name      TEXT NOT NULL DEFAULT 'default',
    description     TEXT NOT NULL DEFAULT '',
    critical        INTEGER NOT NULL DEFAULT 0,
    tags            TEXT NOT NULL DEFAULT '[]',
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_services_group ON services(group_name);
CREATE INDEX IF NOT EXISTS idx_services_critical ON services(critical);
CREATE INDEX IF NOT EXISTS idx_containers_group ON containers(group_name);
""")

if os.path.isfile(old_json):
    migrated = 0
    try:
        with open(old_json, encoding="utf-8") as f:
            raw = json.load(f)
        items = raw.get("services", []) if isinstance(raw, dict) else []
        for s in items:
            conn.execute(
                "INSERT OR IGNORE INTO services "
                "(name, unit, group_name, description, critical, tags, manual_restarts) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    s.get("name", ""), s.get("unit", ""), s.get("group", "default"),
                    s.get("description", ""), int(bool(s.get("critical", False))),
                    json.dumps(s.get("tags", []), ensure_ascii=False),
                    int(s.get("manual_restarts", 0)),
                ),
            )
            migrated += 1
        conn.commit()
        os.rename(old_json, old_json + ".bak")
        print(f"Мигрировано сервисов из services.json: {migrated}")
    except Exception as e:
        # [ИСПРАВЛЕНО v2.1-12] раньше сбой миграции (битый JSON, элемент не
        # словарь и т.п.) только печатал предупреждение и продолжал как ни в
        # чём не бывало: gopanel.db создавался с ПУСТОЙ таблицей services,
        # старый services.json НЕ переименовывался (оставался осиротевшим,
        # т.к. повторный запуск блокируется проверкой "[[ ! -f $DB_FILE ]]"),
        # а установщик завершался с кодом 0 — администратор молча терял
        # видимость всех сервисов, апгрейд выглядел успешным. Теперь сбой
        # фатален — включает уже отлаженный откат установщика (rsync
        # --delete из BACKUP_DIR восстанавливает исходный services.json).
        print(f"Migration FAILED: {e}", file=sys.stderr)
        sys.exit(1)
else:
    conn.execute(
        "INSERT OR IGNORE INTO services (name, unit, group_name, description, critical, tags) "
        "VALUES ('sshd', 'ssh.service', 'infra', 'SSH сервер', 1, '[]')"
    )
    conn.commit()
conn.close()
PYMIGRATE
fi
chown root:"$APP_USER" "$DB_FILE"
chmod 0640 "$DB_FILE" 2>/dev/null || true

# Конфиг бота (с введёнными данными)
info "Создание конфига bot.json..."
cat > "$CONF_DIR/bot.json" <<EOF
{
  "telegram_token": "$telegram_token",
  "authorized_users": $authorized_users_json,
  "enable_alerts": $enable_alerts,
  "status_cache_ttl_sec": 5,
  "max_log_lines": 50,
  "pagination_threshold": 10,
  "log_level": "INFO"
}
EOF
chmod 0640 "$CONF_DIR/bot.json"
chown root:monitor "$CONF_DIR/bot.json"
ok "Конфиг бота создан: $CONF_DIR/bot.json"


# ======================== VENV И ЗАВИСИМОСТИ ========================

info "Recreating Python virtual environment..."
rm -rf "$APP_DIR/venv"
sudo -u "$APP_USER" "$PY" -m venv "$APP_DIR/venv"
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -q --no-cache-dir --no-warn-script-location --upgrade pip wheel

info "Установка Python-зависимостей (панель + бот)..."
# [ИСПРАВЛЕНО v2.1-24] версия aiogram зафиксирована — см. обоснование у
# зависимости в pyproject.toml выше по файлу.
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -q --no-cache-dir --no-warn-script-location \
    "textual==0.67.1" \
    "psutil>=5.9.8,<6.0.0" \
    pydantic==2.7.0 \
    pydantic-settings==2.2.1 \
    "aiogram==3.20.0" \
    packaging
# Editable install: создаёт .pth-файл, src/ используется напрямую.
# Не ломает pip RECORD в отличие от rsync в site-packages.
# [ИСПРАВЛЕНО v2.1] exit 1 внутри `||{}` не активирует trap ERR (_install_failed) —
# автооткат не срабатывал при сбое editable install. Заменено на false, как уже
# сделано для проверки VERSION выше по коду.
sudo -u "$APP_USER" "$APP_DIR/venv/bin/pip" install -q --no-cache-dir -e "$APP_DIR" || { err "pip install -e failed"; false; }
ok "Editable install complete (src/ подключён напрямую)"

# ======================== LOGROTATE ========================

write_file /etc/logrotate.d/gopanel 0644 <<'LOGROTATE'
/var/log/gopanel/gopanel.log
/var/log/gopanel/bot.log
{
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    # copytruncate: logrotate обнуляет файл на месте вместо переименования.
    # Python logging.FileHandler держит fd открытым на тот же inode —
    # copytruncate позволяет ротировать без сигналов и без переоткрытия
    # файла процессом. Небольшое окно потери данных (~байты) допустимо.
    copytruncate
    create 0640 monitor monitor
}
LOGROTATE
ok "logrotate настроен (/etc/logrotate.d/gopanel)"

# ======================== ВСПОМОГАТЕЛЬНЫЕ ДИРЕКТОРИИ ========================

mkdir -p "$APP_DIR/cache" "$APP_DIR/config" "$APP_DIR/data"
chown -R "$APP_USER:$APP_USER" "$APP_DIR/cache" "$APP_DIR/config" "$APP_DIR/data"

# ======================== СКРИПТ ЗАПУСКА TMUX ========================

write_file "$APP_DIR/start-tmux.sh" 0755 <<'SH'
#!/bin/bash
SOCKET="/opt/gopanel/tmux.sock"
EXIT_CODE_FILE="$(mktemp /tmp/gopanel-exit-XXXXXX)"

cleanup() {
    tmux -S "$SOCKET" kill-session -t gopanel 2>/dev/null || true
    # FIX H-6: удаляем временный файл при любом выходе (нормальном или по сигналу).
    # Без этого каждый рестарт сервиса оставлял осиротевший файл в /tmp.
    # За 6 месяцев эксплуатации накапливаются тысячи файлов gopanel-exit-*.
    rm -f "$EXIT_CODE_FILE"
}
trap cleanup EXIT

tmux -S "$SOCKET" kill-session -t gopanel 2>/dev/null || true
# [ИСПРАВЛЕНО v2.1-19] `$?` внутри двойных кавычек разворачивался ЭТИМ (внешним)
# shell в момент построения строки для tmux — т.е. кодом предыдущей команды
# (`kill-session ... || true` => всегда 0), а не кодом возврата gopanel-tui из
# внутреннего `bash -c`. В exit-файл всегда писался "0" — systemd видел "чистое"
# завершение и Restart=on-failure никогда не срабатывал. `\$?` откладывает
# раскрытие до внутреннего bash -c.
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

# ======================== WRAPPER-СКРИПТЫ ========================

write_file /usr/local/bin/gopanel-systemctl 0755 <<'SH'
#!/usr/bin/env python3
import sys
import sqlite3
import re
import os
import time

UNIT_RE = re.compile(r"^[A-Za-z0-9_@][A-Za-z0-9_.@\-]{0,253}\.service$")
ALLOWED_ACTIONS = {"status", "is-active", "show", "start", "stop", "restart", "list-unit-files"}

if not os.path.exists("/usr/bin/systemctl"):
    print("Error: /usr/bin/systemctl not found", file=sys.stderr)
    sys.exit(1)

args = sys.argv[1:]
if len(args) < 1:
    sys.exit(1)

action = args[0]
if action not in ALLOWED_ACTIONS:
    print(f"Blocked action: {action}", file=sys.stderr)
    sys.exit(1)

# list-unit-files не требует юнитов — ранняя проверка len(args) < 2 блокировала её
if len(args) < 2 and action not in {"list-unit-files"}:
    sys.exit(1)

units = [a for a in args[1:] if a.endswith(".service")]
# [ФИЧА v2.1-1] SQLite вместо services.json
db_file = "/etc/gopanel/gopanel.db"

allowed_units = set()
last_err = None
for attempt in range(3):
    try:
        conn = sqlite3.connect(db_file, timeout=2)
        try:
            allowed_units = {row[0] for row in conn.execute("SELECT unit FROM services")}
        finally:
            conn.close()
        last_err = None
        break
    except sqlite3.Error as e:
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

# FIX DEF-05: ранее передавался весь sys.argv[1:] в os.execv без проверки
# промежуточных флагов. Флаги типа --root, --host, --machine, --firmware-setup
# передавались в systemctl без валидации (CWE-88: Argument Injection).
# os.execv исключает shell injection, но не argument injection.
#
# Исправление: явный whitelist флагов на каждое действие.
# - show: разрешены --no-pager и --property=<безопасное значение>
# - start/stop/restart/status/is-active: флаги запрещены полностью
# - list-unit-files: флаги запрещены
# Неизвестные флаги блокируются с ошибкой.
PROPERTY_RE = re.compile(r"^--property=[A-Za-z,]+$")
ALLOWED_FLAGS_BY_ACTION: dict[str, set[str]] = {
    "show": {"--no-pager"},
}

flags = [a for a in args[1:] if a.startswith("-")]
allowed_flags = ALLOWED_FLAGS_BY_ACTION.get(action, set())
for flag in flags:
    if flag in allowed_flags:
        continue
    if action == "show" and PROPERTY_RE.match(flag):
        continue
    print(f"Blocked flag: {flag}", file=sys.stderr)
    sys.exit(1)

# Строим безопасный argv: action + разрешённые флаги + валидированные юниты
safe_flags = [a for a in args[1:] if a.startswith("-")]  # уже проверены выше
if action == "list-unit-files":
    os.execv("/usr/bin/systemctl", ["systemctl", action])
else:
    os.execv("/usr/bin/systemctl", ["systemctl", action] + safe_flags + units)
SH

write_file /usr/local/bin/gopanel-journalctl 0755 <<'SH'
#!/usr/bin/env python3
import sys
import sqlite3
import re
import os
import time

UNIT_RE = re.compile(r"^[A-Za-z0-9_@][A-Za-z0-9_.@\-]{0,253}\.service$")
# [ФИЧА v2.1-1] SQLite вместо services.json
DB_FILE = "/etc/gopanel/gopanel.db"

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

allowed_units = set()
last_err = None
for attempt in range(3):
    try:
        conn = sqlite3.connect(DB_FILE, timeout=2)
        try:
            allowed_units = {row[0] for row in conn.execute("SELECT unit FROM services")}
        finally:
            conn.close()
        last_err = None
        break
    except sqlite3.Error as e:
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
has_n = False
has_f = False
i = 0
while i < len(args):
    arg = args[i]
    flag = arg.split("=")[0] if "=" in arg else arg
    if flag not in ALLOWED_FLAGS and arg.startswith("-"):
        print(f"Blocked flag: {arg}", file=sys.stderr)
        sys.exit(1)
    if arg in ("-f", "--follow"):
        has_f = True
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
    # [ИСПРАВЛЕНО v2.1-18] -n/--lines раньше пропускался без ограничения
    # значения (только имя флага проверялось) — `-n 100000000` заставлял
    # journalctl вычитывать и выводить весь журнал, DoS по CPU/IO/памяти.
    elif arg in ("-n", "--lines"):
        if i + 1 < len(args):
            try:
                if not (0 <= int(args[i + 1]) <= 10000):
                    sys.exit(1)
            except ValueError:
                sys.exit(1)
            has_n = True
            i += 2
            continue
    elif arg.startswith("--lines="):
        try:
            if not (0 <= int(arg.split("=", 1)[1]) <= 10000):
                sys.exit(1)
        except ValueError:
            sys.exit(1)
        has_n = True
        i += 1
        continue
    i += 1

if not has_u:
    sys.exit(1)

# [ИСПРАВЛЕНО v2.1-34] значение -n/--lines ограничивалось диапазоном 0-10000,
# но сам флаг не был обязательным — без него (например, только с --since)
# journalctl не имел вообще никакого верхнего предела строк, DoS по CPU/IO.
# Исключение — "-f"/"--follow": по умолчанию journalctl показывает лишь
# небольшой хвост перед переходом в режим слежения (как `tail -f`), это уже
# используется вызывающим кодом (см. tail() с -f в journal.py) без -n.
if not has_n and not has_f:
    sys.exit(1)

os.execv("/usr/bin/stdbuf", ["stdbuf", "-oL", "/usr/bin/journalctl"] + args)
SH

write_file /usr/local/bin/gopanel-save-bot-config 0755 <<'SH'
#!/usr/bin/env bash
set -eu

# [ИСПРАВЛЕНО v2.1-18] в отличие от gopanel-systemctl/journalctl/db, здесь не
# было явной проверки EUID — wrapper полагался только на то, что вызывается
# через sudo. Прямой запуск без sudo падал бы на chown, но это неявно.
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: This wrapper must be run as root (via sudo)." >&2
    exit 1
fi

CONFIG_FILE="/etc/gopanel/bot.json"
TMP_FILE=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")

cat > "$TMP_FILE"

if ! python3 -c "import json,sys; json.load(open('$TMP_FILE'))" 2>/dev/null; then
    rm -f "$TMP_FILE"
    echo "Error: invalid JSON, config not saved" >&2
    exit 1
fi

chmod 0640 "$TMP_FILE"
chown root:monitor "$TMP_FILE"
mv "$TMP_FILE" "$CONFIG_FILE"
SH

# [ИСПРАВЛЕНО v2.1-12] при апгрейде с v2.0 старый JSON-wrapper оставался
# сиротой на диске (из sudoers исключён — не опасен, но не должен висеть)
rm -f /usr/local/bin/gopanel-save-services

write_file /usr/local/bin/gopanel-db 0755 <<'PY'
#!/usr/bin/env python3
# [ФИЧА v2.1-1] Универсальный SQLite-wrapper реестра. Принимает JSON-команду
# из stdin, выполняет одну SQL-операцию в транзакции. Заменяет
# gopanel-save-services (перезапись всего services.json целиком).
import json
import os
import re
import sqlite3
import sys

DB_PATH = "/etc/gopanel/gopanel.db"
ALLOWED_ACTIONS = {
    "upsert_service", "delete_service",
    "upsert_container", "delete_container",
    "update_setting", "delete_setting",
}
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,31}$")
UNIT_RE = re.compile(r"^[A-Za-z0-9_@][A-Za-z0-9_.@\-]{0,253}\.service$")


def fail(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


if os.geteuid() != 0:
    fail("This wrapper must be run as root (via sudo).")

try:
    cmd = json.load(sys.stdin)
except json.JSONDecodeError as e:
    fail(f"invalid JSON: {e}")

if not isinstance(cmd, dict):
    fail("command must be a JSON object")

action = cmd.get("action")
if action not in ALLOWED_ACTIONS:
    fail(f"unknown action: {action!r}")

conn = sqlite3.connect(DB_PATH, timeout=5)
try:
    if action == "upsert_service":
        data = cmd.get("data") or {}
        if not NAME_RE.match(str(data.get("name", ""))):
            fail(f"invalid service name: {data.get('name')!r}")
        if not UNIT_RE.match(str(data.get("unit", ""))):
            fail(f"invalid unit: {data.get('unit')!r}")
        conn.execute(
            "INSERT INTO services (name, unit, group_name, description, critical, tags, manual_restarts, updated_at) "
            "VALUES (:name, :unit, :group_name, :description, :critical, :tags, :manual_restarts, datetime('now')) "
            "ON CONFLICT(name) DO UPDATE SET "
            "unit=excluded.unit, group_name=excluded.group_name, description=excluded.description, "
            "critical=excluded.critical, tags=excluded.tags, manual_restarts=excluded.manual_restarts, "
            "updated_at=datetime('now')",
            data,
        )
    elif action == "delete_service":
        name = str(cmd.get("name", ""))
        if not NAME_RE.match(name):
            fail(f"invalid service name: {name!r}")
        conn.execute("DELETE FROM services WHERE name = ?", (name,))
    elif action == "upsert_container":
        data = cmd.get("data") or {}
        if not NAME_RE.match(str(data.get("name", ""))):
            fail(f"invalid container name: {data.get('name')!r}")
        conn.execute(
            "INSERT INTO containers (name, image, group_name, description, critical, tags, updated_at) "
            "VALUES (:name, :image, :group_name, :description, :critical, :tags, datetime('now')) "
            "ON CONFLICT(name) DO UPDATE SET "
            "image=excluded.image, group_name=excluded.group_name, description=excluded.description, "
            "critical=excluded.critical, tags=excluded.tags, updated_at=datetime('now')",
            data,
        )
    elif action == "delete_container":
        name = str(cmd.get("name", ""))
        if not NAME_RE.match(name):
            fail(f"invalid container name: {name!r}")
        conn.execute("DELETE FROM containers WHERE name = ?", (name,))
    elif action == "update_setting":
        key = str(cmd.get("key", ""))
        value = cmd.get("value", "")
        # [ИСПРАВЛЕНО v2.1-10] лимит поднят с 64 до 300 — ключи вида
        # "pending_restart:<unit>.service" могут доходить до ~280 символов
        if not key or len(key) > 300:
            fail(f"invalid setting key: {key!r}")
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, str(value)),
        )
    elif action == "delete_setting":
        # [ИСПРАВЛЕНО v2.1-10] нужен для снятия pending_restart:<unit> флага
        key = str(cmd.get("key", ""))
        if not key or len(key) > 300:
            fail(f"invalid setting key: {key!r}")
        conn.execute("DELETE FROM settings WHERE key = ?", (key,))
    conn.commit()
except sqlite3.Error as e:
    conn.rollback()
    fail(f"database error: {e}")
finally:
    conn.close()
PY

write_file /usr/local/bin/gopanel-docker 0755 <<'PY'
#!/usr/bin/env python3
# [ФИЧА v2.1-4] Wrapper для docker CLI, аналог gopanel-systemctl. Проверяет
# контейнер по реестру SQLite перед выполнением, только зарегистрированные
# контейнеры и только разрешённые действия.
import os
import re
import sqlite3
import sys

DB_FILE = "/etc/gopanel/gopanel.db"
DOCKER_BIN = "/usr/bin/docker"
ALLOWED_ACTIONS = {"start", "stop", "restart", "logs", "inspect", "stats"}
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,31}$")


def fail(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


if not os.path.exists(DOCKER_BIN):
    fail("docker not found")

# [ИСПРАВЛЕНО v2.1-18] в отличие от gopanel-systemctl/journalctl/db здесь не
# было явной проверки EUID — wrapper полагался только на вызов через sudo.
if os.geteuid() != 0:
    fail("This wrapper must be run as root (via sudo).")

args = sys.argv[1:]
if not args:
    fail("Usage: gopanel-docker <ps|start|stop|restart|logs|inspect|stats> [container]")

action = args[0]

if action == "ps":
    if len(args) != 1:
        fail("ps takes no arguments")
    os.execv(DOCKER_BIN, ["docker", "ps", "-a", "--format", "{{json .}}"])

if action not in ALLOWED_ACTIONS:
    fail(f"Blocked action: {action}")

if len(args) != 2:
    fail(f"{action} requires exactly one container name")

container = args[1]
if not NAME_RE.match(container):
    fail(f"invalid container name: {container!r}")

allowed = set()
try:
    conn = sqlite3.connect(DB_FILE, timeout=2)
    try:
        allowed = {row[0] for row in conn.execute("SELECT name FROM containers")}
    finally:
        conn.close()
except sqlite3.Error as e:
    fail(f"registry read error: {e}")

if container not in allowed:
    fail(f"Blocked container: {container}")

if action == "logs":
    os.execv(DOCKER_BIN, ["docker", "logs", "--tail", "200", "--timestamps", container])
elif action == "inspect":
    os.execv(DOCKER_BIN, ["docker", "inspect", container])
elif action == "stats":
    os.execv(DOCKER_BIN, ["docker", "stats", "--no-stream", "--format", "{{json .}}", container])
else:  # start / stop / restart
    os.execv(DOCKER_BIN, ["docker", action, container])
PY

write_file /usr/local/bin/gopanel-screenshot 0755 <<'PY'
#!/usr/bin/env python3
# [ФИЧА v2.1-5] Захват состояния TUI-панели: tmux capture-pane -> рендер в
# PNG через Pillow. Без sudo — gopanel.service (tmux) и gopanel-bot.service
# оба работают от пользователя monitor и оба имеют доступ к tmux.sock,
# отдельного повышения привилегий здесь не требуется (в отличие от
# gopanel-systemctl/gopanel-journalctl/gopanel-docker, которым нужен root).
import subprocess
import sys
import tempfile
import os
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Error: Pillow (python3-pil) не установлен", file=sys.stderr)
    sys.exit(1)

SOCKET = "/opt/gopanel/tmux.sock"
SESSION = "gopanel"
FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
]
FONT_SIZE = 14
CHAR_W = 8
CHAR_H = 18
PADDING = 20
MAX_LINES = 200


def fail(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


try:
    result = subprocess.run(
        ["tmux", "-S", SOCKET, "capture-pane", "-p", "-t", SESSION],
        capture_output=True, text=True, timeout=10,
    )
except subprocess.TimeoutExpired:
    fail("tmux capture-pane timed out")
except FileNotFoundError:
    fail("tmux not found")

if result.returncode != 0:
    fail(f"tmux capture-pane failed: {result.stderr.strip()}")

pane_text = result.stdout
if not pane_text.strip():
    fail("empty pane capture — панель не запущена?")

lines = pane_text.split("\n")[:MAX_LINES]

font_path = next((c for c in FONT_CANDIDATES if Path(c).exists()), None)
try:
    font = ImageFont.truetype(font_path, FONT_SIZE) if font_path else ImageFont.load_default()
except Exception:
    font = ImageFont.load_default()

max_len = max((len(l) for l in lines), default=0)
width = max(PADDING * 2 + max_len * CHAR_W, 200)
height = max(PADDING * 2 + len(lines) * CHAR_H, 100)

img = Image.new("RGB", (width, height), color="#0a0e14")
draw = ImageDraw.Draw(img)
for i, line in enumerate(lines):
    draw.text((PADDING, PADDING + i * CHAR_H), line, font=font, fill="#e0e0e0")

# [ИСПРАВЛЕНО v2.1-18] раньше имя файла было предсказуемым
# (gopanel-screenshot-{unixtime}.png) и создавалось с правами по умолчанию
# (umask 0022 => 0644, читаемо всеми) — локальный пользователь мог угадать
# имя и прочитать скриншот TUI, пока файл не удалён. mkstemp даёт случайное
# имя и права 0600 сразу при создании.
fd, out_path = tempfile.mkstemp(prefix="gopanel-screenshot-", suffix=".png", dir="/tmp")
os.close(fd)
img.save(out_path)
print(out_path)
PY

write_file /usr/local/bin/gopanel-restart-bot 0755 <<'SH'
#!/usr/bin/env bash
set -eu
systemctl restart gopanel-bot
SH

# ======================== SUDOERS (единый файл) ========================

info "Настройка sudoers..."
# Объединяем оба sudoers-файла в один — убираем дубли
cat > /etc/sudoers.d/gopanel <<'SUDOERS'
# GoPanel sudoers — панель + бот
#
# [МОДЕЛЬ ДОВЕРИЯ] monitor — доверенный/полудоверенный оператор панели, а не
# изолированный от root потенциальный злоумышленник. GOPANEL_DB даёт monitor
# право регистрировать в реестре произвольный systemd-юнит (в рамках regex),
# после чего GOPANEL_SYSTEMCTL позволяет им управлять — то есть реестр здесь
# служит operational allowlist (защита от опечаток/случайных действий), а НЕ
# security-границей между monitor и systemd. Это осознанное архитектурное
# решение (панель по дизайну сама добавляет/редактирует/удаляет сервисы),
# а не недосмотр: если требуется security-граница именно на уровне "какие
# юниты вообще можно регистрировать" — нужна отдельная модель с
# предварительным одобрением root, и это уже другая архитектура.
Cmnd_Alias GOPANEL_SYSTEMCTL      = /usr/local/bin/gopanel-systemctl *
Cmnd_Alias GOPANEL_JOURNALCTL     = /usr/local/bin/gopanel-journalctl *
Cmnd_Alias GOPANEL_SAVE_BOT_CFG   = /usr/local/bin/gopanel-save-bot-config
Cmnd_Alias GOPANEL_DB             = /usr/local/bin/gopanel-db
Cmnd_Alias GOPANEL_DOCKER         = /usr/local/bin/gopanel-docker *
Cmnd_Alias GOPANEL_RESTART_BOT    = /usr/local/bin/gopanel-restart-bot
monitor ALL=(root) NOPASSWD: GOPANEL_SYSTEMCTL, GOPANEL_JOURNALCTL, GOPANEL_SAVE_BOT_CFG, GOPANEL_DB, GOPANEL_DOCKER, GOPANEL_RESTART_BOT
SUDOERS
chmod 0440 /etc/sudoers.d/gopanel
visudo -cf /etc/sudoers.d/gopanel >/dev/null || { err "Invalid sudoers"; exit 1; }
# Удаляем старый файл бота если он существует от предыдущей установки
rm -f /etc/sudoers.d/gopanel-bot
ok "sudoers настроены"

# ======================== SYSTEMD UNITS ========================

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
# MemoryDenyWriteExecute несовместим с pydantic-core (Rust/JIT) на Ubuntu 24.04 systemd v255
ProtectKernelModules=true

[Install]
WantedBy=multi-user.target
SYSTEMD

write_file /etc/systemd/system/gopanel-bot.service 0644 <<'SYSTEMD'
[Unit]
Description=GoPanel Telegram Bot
After=network.target

[Service]
Type=simple
User=monitor
WorkingDirectory=/opt/gopanel
Environment=HOME=/home/monitor
Environment=LANG=C.UTF-8
ExecStart=/opt/gopanel/venv/bin/python -m gopanel.bot.main
Restart=on-failure
RestartSec=10
TimeoutStopSec=15
KillMode=control-group
LimitNOFILE=65535

MemoryMax=512M
TasksMax=128

PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/etc/gopanel /var/log/gopanel /opt/gopanel
ProtectHome=yes
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
# MemoryDenyWriteExecute несовместим с pydantic-core (Rust/JIT) на Ubuntu 24.04 systemd v255
ProtectKernelModules=true

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable gopanel.service gopanel-bot.service

# ======================== ВЕРИФИКАЦИЯ ========================

info "Verifying installation..."
# Проверяем через false чтобы сработал trap ERR → _install_failed → автооткат
if ! sudo -u "$APP_USER" "$APP_DIR/venv/bin/python" -c "import gopanel; assert gopanel.__version__ == '$VERSION'" 2>/dev/null; then
    err "Verification failed — запускается автооткат..."
    false  # принудительно активирует trap ERR
fi

info "Проверка импорта Python-модулей бота..."
if ! sudo -u "$APP_USER" "$APP_DIR/venv/bin/python" -c "
import gopanel.bot.main
from gopanel.systemd import batch_show, control
from gopanel.journal import tail
from gopanel.registry import get_registry
from gopanel.ui.screens.bot_settings import BotSettingsScreen
" 2>/dev/null; then
    err "Ошибка импорта критических модулей"
    # [ИСПРАВЛЕНО v2.1] exit 1 внутри `if` не активирует trap ERR — автооткат
    # не срабатывал при сбое импорта модулей бота. Заменено на false, аналогично
    # проверке gopanel.__version__ выше.
    false  # принудительно активирует trap ERR
fi
ok "Все Python-модули импортируются успешно"

info "Проверка SQLite-реестра (gopanel list)..."
# [ФИЧА v2.1-1] реальная сквозная проверка: чтение gopanel.db от имени monitor
if ! sudo -u "$APP_USER" "$APP_DIR/venv/bin/gopanel" list >/dev/null 2>&1; then
    err "Реестр SQLite недоступен для пользователя $APP_USER"
    false  # принудительно активирует trap ERR
fi
ok "Реестр SQLite читается корректно"

# [ИСПРАВЛЕНО v2.1] Очистка backup перенесена в конец скрипта — после
# systemctl start и подтверждения активности обоих сервисов. Ранее backup
# удалялся здесь, ДО фактического запуска gopanel.service/gopanel-bot.service:
# при сбое старта (например, неверный токен, краш-луп бота) trap ERR /
# _install_failed уже не находил backup для отката — восстановление было
# невозможно ни автоматически, ни вручную. См. блок после запуска сервисов.

# ======================== ДОПОЛНИТЕЛЬНЫЕ КОМАНДЫ ========================

write_file /usr/local/bin/gopanel-attach 0755 <<'SH'
#!/usr/bin/env bash
SOCKET="/opt/gopanel/tmux.sock"
SESSION="gopanel"
[[ -t 0 ]] || { echo "❌ gopanel-attach требует интерактивного терминала (TTY)" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then
    SYSTEMCTL_CMD="systemctl"
else
    SYSTEMCTL_CMD="sudo systemctl"
fi

if ! $SYSTEMCTL_CMD is-active --quiet gopanel.service 2>/dev/null; then
    echo "Запуск сервиса gopanel.service..."
    $SYSTEMCTL_CMD start gopanel.service
    for i in {1..10}; do
        if sudo -u monitor tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
fi

if sudo -u monitor tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    # [ИСПРАВЛЕНО v2.2] фиксируем время фактического attach — панель
    # использует этот файл, чтобы обновить "Сессия с ..." при
    # переподключении к уже работающей tmux-сессии
    sudo -u monitor touch /opt/gopanel/data/last_attach 2>/dev/null || true
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
# [ИСПРАВЛЕНО v2.1-18] у двух следующих read (v2.1-16) уже есть </dev/tty,
# здесь его не было — несогласованность (не отсутствие защиты вообще).
read -p "Удалить GoPanel и Telegram-бота? [y/N] " c </dev/tty
[[ "$c" == "y" ]] || exit 0

systemctl stop gopanel.service gopanel-bot.service 2>/dev/null || true
systemctl disable gopanel.service gopanel-bot.service 2>/dev/null || true
tmux -S /opt/gopanel/tmux.sock kill-server 2>/dev/null || true
sleep 1

rm -f /etc/sudoers.d/gopanel /etc/sudoers.d/gopanel-bot
rm -f /usr/local/bin/gopanel
rm -f /usr/local/bin/gopanel-attach
rm -f /usr/local/bin/gopanel-uninstall
rm -f /usr/local/bin/gopanel-systemctl
rm -f /usr/local/bin/gopanel-journalctl
rm -f /usr/local/bin/gopanel-save-bot-config
rm -f /usr/local/bin/gopanel-db
rm -f /usr/local/bin/gopanel-docker
rm -f /usr/local/bin/gopanel-screenshot
rm -f /usr/local/bin/gopanel-restart-bot
rm -f /etc/systemd/system/gopanel.service
rm -f /etc/systemd/system/gopanel-bot.service
rm -f /etc/logrotate.d/gopanel
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/gopanel

# Удаление пользователя monitor — отдельное подтверждение
# (пользователь может использоваться другими сервисами)
if getent passwd monitor >/dev/null 2>&1; then
    read -p "Удалить пользователя monitor и его домашний каталог? [y/N] " del_user </dev/tty
    if [[ "${del_user:-N}" =~ ^[Yy]$ ]]; then
        userdel -r monitor 2>/dev/null || true
        echo "Пользователь monitor удалён."
    else
        echo "Пользователь monitor сохранён."
    fi
fi

# [ИСПРАВЛЕНО v2.1-16] раньше /etc/gopanel (включая ТОКЕН БОТА и список
# авторизованных пользователей в bot.json) и /var/log/gopanel безусловно
# сохранялись без единого предупреждения — полное удаление без следов было
# невозможно в принципе. Теперь отдельное явное подтверждение, по аналогии
# с уже существующим для пользователя monitor.
if [[ -d /etc/gopanel || -d /var/log/gopanel ]]; then
    read -p "Удалить конфиги /etc/gopanel (в т.ч. токен бота) и логи /var/log/gopanel? [y/N] " del_data </dev/tty
    if [[ "${del_data:-N}" =~ ^[Yy]$ ]]; then
        rm -rf /etc/gopanel /var/log/gopanel
        echo "Конфиги и логи удалены."
    else
        echo "Конфиги (/etc/gopanel, включая токен бота) и логи (/var/log/gopanel) сохранены."
    fi
fi

echo "Готово."
SH

# [ИСПРАВЛЕНО v2.1-18] CONF_DIR исключён из этого рекурсивного chown — раньше
# он безусловно возвращал владельца gopanel.db (root:monitor, см. выше) на
# monitor:monitor, что полностью обнуляло защиту "запись только через
# gopanel-db" — monitor мог писать в БД напрямую sqlite3, без валидации
# NAME_RE/UNIT_RE и wrapper'а вообще.
chown -R "$APP_USER":"$APP_USER" "$APP_DIR" "$LOG_DIR"
# Восстанавливаем права bot.json: root:monitor (бот читает под monitor, root владеет)
chown root:monitor "$CONF_DIR/bot.json" 2>/dev/null || true
chmod 0640 "$CONF_DIR/bot.json" 2>/dev/null || true
# [ИСПРАВЛЕНО v2.1-18] явно фиксируем владельца самого каталога и БД —
# идемпотентно чинит и апгрейд с версии, где CONF_DIR был monitor:monitor
chown root:"$APP_USER" "$CONF_DIR" 2>/dev/null || true
chmod 0750 "$CONF_DIR" 2>/dev/null || true
[[ -f "$DB_FILE" ]] && chown root:"$APP_USER" "$DB_FILE" 2>/dev/null && chmod 0640 "$DB_FILE" 2>/dev/null || true

# ======================== ЗАПУСК СЕРВИСОВ ========================

info "Запуск gopanel.service..."
systemctl start gopanel.service
# [ИСПРАВЛЕНО v2.1-20] было sleep 3 при RestartSec=5 у gopanel.service — окно
# проверки было короче интервала до первого автоперезапуска, из-за чего
# NRestarts-проверка ниже (v2.1-19) физически не могла поймать crash-loop:
# systemd просто не успевал перезапустить процесс к моменту проверки.
sleep 10

if systemctl is-active --quiet gopanel.service; then
    # [ИСПРАВЛЕНО v2.1-19] is-active сразу после старта не отличает "работает
    # стабильно" от "уже упал и был перезапущен systemd (Restart=on-failure)
    # ровно перед проверкой" — NRestarts>0 на этом этапе означает crash-loop.
    GP_NRESTARTS=$(systemctl show -p NRestarts --value gopanel.service 2>/dev/null || echo 0)
    if [[ "${GP_NRESTARTS:-0}" -gt 0 ]]; then
        err "gopanel.service уже перезапускался ($GP_NRESTARTS раз) — похоже на crash-loop"
        false  # принудительно активирует trap ERR
    fi
    if sudo -u "$APP_USER" tmux -S "$TMUX_SOCKET" has-session -t gopanel 2>/dev/null; then
        if pgrep -u "$APP_USER" -f "gopanel-tui" >/dev/null 2>&1; then
            ok "gopanel.service запущен успешно (tmux + процесс gopanel-tui активен)"
        else
            warn "gopanel.service запущен, tmux сессия есть, но процесс gopanel-tui не обнаружен"
        fi
    else
        err "gopanel.service запущен, но tmux сессия не найдена"
    fi
else
    err "gopanel.service не запустился"
    # [ИСПРАВЛЕНО v2.1] exit 1 внутри if/else не активирует trap ERR. Т.к.
    # очистка backup теперь происходит только после успешного запуска обоих
    # сервисов (см. ниже), backup на этом этапе ещё существует — false
    # активирует _install_failed и восстанавливает рабочую версию.
    false  # принудительно активирует trap ERR
fi

info "Запуск gopanel-bot.service..."
systemctl start gopanel-bot.service
sleep 15

if systemctl is-active --quiet gopanel-bot.service; then
    # [ИСПРАВЛЕНО v2.1-19] см. аналогичную проверку у gopanel.service выше —
    # is-active не отличает "стабильно работает" от "уже перезапускался".
    GB_NRESTARTS=$(systemctl show -p NRestarts --value gopanel-bot.service 2>/dev/null || echo 0)
    if [[ "${GB_NRESTARTS:-0}" -gt 0 ]]; then
        err "gopanel-bot.service уже перезапускался ($GB_NRESTARTS раз) — похоже на crash-loop"
        false  # принудительно активирует trap ERR
    fi
    ok "gopanel-bot.service запущен и работает"
    # Реальная проверка через Telegram API — бот уже запущен, токен в конфиге
    TG_TOKEN=$(python3 -c "import json; d=json.load(open('/etc/gopanel/bot.json')); print(d.get('telegram_token',''))" 2>/dev/null || true)
    if [[ -n "$TG_TOKEN" && "$TG_TOKEN" != "YOUR_BOT_TOKEN_HERE" ]]; then
        # [ИСПРАВЛЕНО v2.1-18] раньше токен передавался прямо в URL-аргументе
        # curl — виден локальным пользователям через ps/`/proc/*/cmdline` на
        # время выполнения запроса. Теперь URL берётся из временного
        # --config файла с правами 600, токен не попадает в argv процесса.
        TG_CURL_CFG=$(mktemp)
        chmod 600 "$TG_CURL_CFG"
        # [ИСПРАВЛЕНО v2.1-19] rm ниже выполнялся только при нормальном
        # продолжении — при аварийном завершении между mktemp и rm (сигнал,
        # kill) файл с токеном оставался в /tmp. Trap на EXIT/INT/TERM гарантирует
        # удаление в любом случае, кроме неперехватываемого SIGKILL. INT/TERM
        # дополнительно перевыбрасывают сигнал после очистки — иначе trap молча
        # "проглатывал" бы Ctrl+C/kill вместо завершения установщика.
        # [ИСПРАВЛЕНО v2.1-20] раньше здесь стояло "trap - INT TERM; kill -s TERM
        # "$$"" — сброс на дефолтную обработку сигнала. Теперь на верхнем уровне
        # INT/TERM запускают полноценный откат (_install_failed), а этот старый
        # сброс молча обходил бы его именно в эти ~10 секунд проверки токена.
        # Вызываем _install_failed напрямую, предварительно почистив temp-файл.
        trap 'rm -f "$TG_CURL_CFG"; trap - EXIT; _install_failed' INT TERM
        trap 'rm -f "$TG_CURL_CFG"' EXIT
        printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$TG_TOKEN" > "$TG_CURL_CFG"
        TG_RESP=$(curl -sf --max-time 10 --config "$TG_CURL_CFG" 2>/dev/null || true)
        rm -f "$TG_CURL_CFG"
        # [ИСПРАВЛЕНО v2.1-20] восстанавливаем глобальный INT/TERM->_install_failed
        # (снятый локальным trap выше), а не оставляем сигналы необработанными
        # до конца скрипта.
        trap - EXIT
        trap '_install_failed' INT TERM
        if echo "$TG_RESP" | grep -q '"ok":true'; then
            BOT_NAME=$(echo "$TG_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'].get('username','?'))" 2>/dev/null || echo "?")
            ok "Telegram API: токен валиден, бот @${BOT_NAME} отвечает"
        else
            warn "Telegram API не ответил — бот запущен, но токен может быть неверным"
            warn "Проверьте: curl 'https://api.telegram.org/bot\${TOKEN}/getMe'"
        fi
    fi
else
    err "gopanel-bot.service не запустился — проверьте конфиг /etc/gopanel/bot.json"
    err "Логи: sudo journalctl -u gopanel-bot.service -n 50"
    # [ИСПРАВЛЕНО v2.1] exit 1 внутри if/else не активирует trap ERR — см.
    # аналогичный комментарий у проверки gopanel.service выше.
    false  # принудительно активирует trap ERR
fi

# [ИСПРАВЛЕНО v2.1] Очистка backup перенесена сюда — оба сервиса подтверждённо
# активны. Ранее выполнялась сразу после проверки импорта Python-модулей
# (до systemctl start), из-за чего backup для отката отсутствовал при сбое
# именно на этапе реального запуска сервисов (см. аудит, Critical).
[[ -d "$BACKUP_DIR" ]] && rm -rf "$BACKUP_DIR" && ok "Backup cleaned"  # src/ + venv + /etc/gopanel

# ======================== ФИНАЛЬНЫЙ БАННЕР ========================

cat <<BANNER

╔══════════════════════════════════════════════════════════════════════╗
║        🎛  GoPanel v2.1  +  Telegram Bot v2.1                       ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  ПАНЕЛЬ (v2.1):                                                      ║
║  ✓ Мониторинг сервисов в реальном времени (CPU, RAM, Uptime, PID)    ║
║  ✓ Управление сервисами: старт / стоп / рестарт с подтверждением     ║
║  ✓ Добавление, редактирование и удаление сервисов из реестра         ║
║  ✓ Просмотр логов сервисов в реальном времени (journalctl follow)    ║
║  ✓ Панель алертов с историей событий (200 записей)                   ║
║  ✓ Метрики хоста: CPU, RAM, диск, uptime системы                     ║
║  ✓ Настройки Telegram-бота прямо из TUI (клавиша 4 / кнопка ⚙ Бот)  ║
║  ✓ Горячие клавиши управления (a/e/d/s/x/Ctrl+R/Enter)              ║
║  ✓ Статистика сессии: активных / упавших / остановлено / событий     ║
║                                                                      ║
║  БОТ (v2.1):                                                       ║
║  ✓ Уведомления о падении и восстановлении сервисов в Telegram        ║
║  ✓ Панель управления /start с кнопками для каждого сервиса           ║
║  ✓ Постоянная клавиатура: Сервисы / Статус / Помощь                  ║
║  ✓ Контекстные кнопки: при падении — Запуск+Рестарт, без Стоп        ║
║  ✓ Просмотр логов сервиса (последние 30 строк) из бота               ║
║  ✓ Команды: /status /info /logs /start_service /stop_service         ║
║  ✓ Авторизация по Telegram ID, защита от несанкционированного доступа ║
║  ✓ Автообнаружение новых сервисов без перезапуска бота               ║
║                                                                      ║
║  GoPanel v2.1 — TUI Dashboard + Telegram Bot                         ║
║  + Добавлен Telegram-бот с полным управлением сервисами              ║
║  + Уведомления о падении через deactivating/inactive/failed          ║
║  + Отслеживание ручных рестартов через ActiveEnterTimestamp          ║
║  + Панель алертов TUI: события только при смене состояния            ║
║  + asyncio.Lock против гонок при параллельных обновлениях            ║
║  + Автообновление реестра без перезапуска бота                       ║
║  + KillMode=control-group: корректная очистка дочерних процессов                 ║
║  + MemoryMax=512M для бота (было 256M)                               ║
║  + Выпадающий список уровня логирования в настройках бота            ║
║  + Центрирование заголовка в разделе Логи                            ║
║  + Проверка Telegram API после установки (getMe)                     ║
║                                                                      ║
║  НОВОЕ В v2.1:                                                       ║
║  ✓ SQLite-реестр вместо services.json (миграция автоматическая)      ║
║  ✓ Группировка сервисов: фильтр по группе в TUI (клавиши g/G)        ║
║  ✓ Массовые операции в боте: рестарт/стоп — все / critical / группа  ║
║  ✓ Управление Docker-контейнерами: TUI-таблица + секция в боте       ║
║  ✓ Скриншот TUI-панели прямо в Telegram (кнопка 📸 Скриншот)         ║
║  ✓ Полная русификация статусов сервисов в таблице TUI                ║
║                                                                      ║
║  УПРАВЛЕНИЕ:                                                         ║
║    Подключиться к TUI:    gopanel-attach                             ║
║    Статус панели:         systemctl status gopanel                   ║
║    Статус бота:           systemctl status gopanel-bot               ║
║    Перезапуск панели:     systemctl restart gopanel                  ║
║    Перезапуск бота:       systemctl restart gopanel-bot              ║
║    Логи бота:             tail -f /var/log/gopanel/bot.log           ║
║    Логи панели:           journalctl -u gopanel -f                   ║
║    Конфиг бота:           /etc/gopanel/bot.json                      ║
║    Реестр сервисов:       /etc/gopanel/gopanel.db                    ║
║    Удалить всё:           sudo gopanel-uninstall                     ║
╚══════════════════════════════════════════════════════════════════════╝

BANNER
