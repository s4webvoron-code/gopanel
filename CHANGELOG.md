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
✓ Колонка CPU в таблице мониторинга                           
✓ Уведомления о восстановлении сервисов (исправлен throttle)  
✓ Панель горячих клавиш и статистики сессии                   
✓ AlertsPanel растягивается до InfoPanel                      
✓ CPU всегда показывал 0.0% — исправлено кешированием Process 
✓ Удалён нефункциональный экран метрик (клавиша 3)         
