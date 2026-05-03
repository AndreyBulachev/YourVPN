# YourVPN

Bash-скрипт для автоматической установки и настройки VPN-сервера на базе **VLESS + XTLS-Reality** (Xray-core) на Ubuntu/Debian.

Протокол VLESS с Reality-маскировкой делает VPN-трафик неотличимым от обычного HTTPS к крупному сайту (Microsoft, Google и др.), что позволяет обходить DPI-блокировки.

---

## Что делает скрипт

| Шаг | Действие |
|-----|----------|
| 1 | Обновление системы (`apt update && upgrade`) |
| 2 | Установка необходимых утилит (curl, openssl, ufw, qrencode и др.) |
| 3 | Настройка файрвола UFW: открыть SSH (определяется автоматически), VLESS (443/tcp) |
| 4 | Включение BBR — современного алгоритма управления TCP-перегрузкой |
| 5 | Оптимизация сетевых параметров ядра (TCP-буферы, backlog, лимиты соединений) |
| 6 | Установка Xray-core через официальный скрипт XTLS |
| 7 | Генерация UUID пользователя, пары ключей X25519 и Short ID |
| 8 | Интерактивный выбор dest-сайта для Reality: 6 проверенных пресетов или свой вариант с автоматической проверкой совместимости (TLS 1.3 + доступность) |
| 9 | Создание серверного конфига `/usr/local/etc/xray/config.json` |
| 10 | Валидация конфигурации (`xray run -test`) |
| 11 | Запуск сервиса и настройка автозапуска (`systemctl enable`) |
| ✓ | Вывод VLESS-ссылки и QR-кода для настройки клиента |

---

## Требования

- Ubuntu 20.04 / 22.04 / 24.04 или Debian 11/12
- Права root
- Доступ в интернет (для загрузки пакетов и Xray-core)
- Открытый порт 443 у хостинг-провайдера

---

## Установка и запуск

```bash
# Скачать скрипт
curl -O https://raw.githubusercontent.com/AndreyBulachev/YourVPN/master/core/ubuntu/setup-vless.sh

# Запустить от root
sudo bash setup-vless.sh
```

Или одной командой:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/AndreyBulachev/YourVPN/master/core/ubuntu/setup-vless.sh)"
```

> **Важно:** запускайте только на чистом сервере или убедитесь, что порт 443 свободен.

---

## Что происходит в интерактивном режиме

В процессе работы скрипт один раз спросит, какой dest-сайт использовать для Reality-маскировки:

```
Choose a dest site for Reality masking:
  1) www.microsoft.com
  2) www.samsung.com
  3) www.asus.com
  4) dl.google.com
  5) www.logitech.com
  6) www.apple.com
  7) Enter a custom site

Your choice [1–7]:
```

Если выбран свой сайт и он не прошёл проверку — скрипт сообщит об этом и предложит выбрать заново.

---

## Результат

По завершении скрипт выводит:

- Параметры сервера (IP, UUID, Public Key, Short ID, dest-сайт)
- Готовую VLESS-ссылку для импорта в клиент
- QR-код для мобильных клиентов

Пример ссылки:
```
vless://UUID@SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp#MyVPN
```

---

## Рекомендуемые клиенты

| Платформа | Клиент |
|-----------|--------|
| Android | [v2rayNG](https://github.com/2dust/v2rayNG), [Hiddify](https://github.com/hiddify/hiddify-next) |
| iOS | [Hiddify](https://github.com/hiddify/hiddify-next), Shadowrocket |
| Windows | [v2rayN](https://github.com/2dust/v2rayN) |
| macOS | [V2Box](https://github.com/gost/V2Box), [Hiddify](https://github.com/hiddify/hiddify-next) |
| Linux | [Nekoray](https://github.com/MatsuriDayo/nekoray) |

---

## Управление пользователями

После установки запустите `manage-users.sh` для добавления, просмотра и удаления пользователей.

```bash
# Скачать скрипт управления
curl -O https://raw.githubusercontent.com/AndreyBulachev/YourVPN/master/core/ubuntu/manage-users.sh

# Запустить (интерактивное меню)
sudo bash manage-users.sh
```

Или одной командой:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/AndreyBulachev/YourVPN/master/core/ubuntu/manage-users.sh)"
```

Скрипт поддерживает как интерактивное меню, так и прямые команды:

```bash
sudo bash manage-users.sh list              # список пользователей
sudo bash manage-users.sh info             # просмотр пользователя (с QR-кодом)
sudo bash manage-users.sh add              # добавить пользователя
sudo bash manage-users.sh delete           # удалить пользователя

# Можно сразу указать номер или UUID:
sudo bash manage-users.sh info 2
sudo bash manage-users.sh delete a1b2c3...
```

### Что делает скрипт при добавлении пользователя

- Генерирует новый UUID и уникальный Short ID
- Добавляет пользователя в `/usr/local/etc/xray/config.json`
- Валидирует конфиг (`xray run -test`) и перезапускает Xray
- Сохраняет метаданные (имя, Short ID, дата) в `/root/xray-users-meta.json`
- Выводит готовую VLESS-ссылку и QR-код

---

## Управление сервисом

```bash
systemctl status xray      # статус
systemctl restart xray     # перезапуск (после изменения конфига)
journalctl -u xray -f      # логи в реальном времени
```

Конфиг сервера: `/usr/local/etc/xray/config.json`

---

## Источники

- Теоретическая база и команды — [C1-vpn-theory-and-setup.md](https://github.com/AndreyBulachev/Product-Engineer-from-scratch/blob/master/course/appendix-vpn-vless/C1-vpn-theory-and-setup.md)
- [Официальная документация Xray](https://xtls.github.io)
- [Репозиторий Xray-core](https://github.com/XTLS/Xray-core)

---

## Лицензия

[CC BY-NC 4.0](LICENSE) — бесплатно для личного использования, запрещено в коммерческих целях.
