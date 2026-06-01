![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-orange)
![Python](https://img.shields.io/badge/Python-3.12-blue)
![License](https://img.shields.io/badge/License-MIT-green)
# GoPanel

Лёгкая TUI-панель мониторинга и управления systemd-сервисами для Ubuntu 24.04.

## Возможности

- Мониторинг systemd-сервисов
- Просмотр логов через journalctl
- Start / Stop / Restart сервисов
- Добавление и удаление сервисов через интерфейс
- Контроль ресурсов процессов
- Работа через Textual TUI
- Защищённые wrappers для systemctl и journalctl
- Минимальные требования к ресурсам

## Требования

- Ubuntu 24.04
- Python 3.12+
- systemd
- tmux

## Установка

```bash
wget https://raw.githubusercontent.com/s4webvoron-code/gopanel/main/quickinstall.sh
sudo bash quickinstall.sh
