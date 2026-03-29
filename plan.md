# План: Валидация прокси-ссылок после загрузки

## Цель
Добавить валидацию загруженных ссылок между `download_subscription()` и `update_podkop_config()`. Невалидные ссылки и пустые строки должны отфильтровываться.

## Поддерживаемые протоколы
- `ss://` — Shadowsocks
- `vless://` — VLESS
- `trojan://` — Trojan
- `socks4://`, `socks4a://`, `socks5://` — SOCKS
- `hysteria2://`, `hy2://` — Hysteria2

## План выполнения

### 1. Создать функцию `validate_proxy_url()`
Основная функция валидации, которая определяет тип URL и вызывает соответствующий валидатор.

**Логика:**
- Проверка на пустоту и пробелы
- Определение префикса протокола
- Вызов специализированного валидатора

### 2. Создать функцию `validate_shadowsocks_url()`
Валидация ссылок `ss://`.

**Проверки:**
- Начинается с `ss://`
- Не содержит пробелов
- Содержит зашифрованную часть (метод:пароль)
- Содержит сервер и порт
- Порт в диапазоне 1-65535

### 3. Создать функцию `validate_vless_url()`
Валидация ссылок `vless://`.

**Проверки:**
- Начинается с `vless://`
- Не содержит пробелов
- Содержит UUID пользователя
- Содержит хост и порт
- Порт в диапазоне 1-65535
- Содержит query-параметры (type, security)
- Поддерживаемые type: tcp, raw, udp, grpc, http, httpupgrade, xhttp, ws, kcp
- Поддерживаемые security: tls, reality, none
- Для reality: наличие pbk и fp
- Проверка flow (xtls-rprx-vision-udp443 не поддерживается)

### 4. Создать функцию `validate_trojan_url()`
Валидация ссылок `trojan://`.

**Проверки:**
- Начинается с `trojan://`
- Не содержит пробелов
- Содержит пароль
- Содержит хост и порт
- Порт в диапазоне 1-65535

### 5. Создать функцию `validate_socks_url()`
Валидация ссылок `socks4://`, `socks4a://`, `socks5://`.

**Проверки:**
- Начинается с `socks4://`, `socks4a://` или `socks5://`
- Не содержит пробелов
- Содержит хост и порт
- Порт в диапазоне 1-65535
- Хост — валидный IPv4 или домен

### 6. Создать функцию `validate_hysteria2_url()`
Валидация ссылок `hysteria2://` и `hy2://`.

**Проверки:**
- Начинается с `hysteria2://` или `hy2://`
- Не содержит пробелов
- Содержит пароль
- Содержит хост и порт
- Порт в диапазоне 1-65535
- Параметр insecure: 0 или 1
- Параметр obfs: none или salamander
- При obfs != none требуется obfs-password
- Параметр sni не может быть пустым

### 7. Создать функцию `validate_ipv4()`
Валидация IPv4 адресов.

**Проверки:**
- Формат: X.X.X.X
- Каждая часть 0-255

### 8. Создать функцию `validate_domain()`
Валидация доменных имён.

**Проверки:**
- Допустимые символы: a-z, A-Z, 0-9, -, .
- Не начинается/не заканчивается на дефис
- Длина до 253 символов

### 9. Создать функцию `filter_valid_links()`
Фильтрация загруженных ссылок.

**Логика:**
- Читает файл построчно
- Пропускает пустые строки
- Пропускает строки с пробелами
- Вызывает `validate_proxy_url()` для каждой ссылки
- Записывает валидные ссылки во временный файл
- Возвращает количество валидных ссылок
- Выводит статистику по невалидным

### 10. Обновить `main()`
Добавить вызов `filter_valid_links()` после `download_subscription()`.

**Новый порядок:**
```sh
check_prerequisites
download_subscription
filter_valid_links    # <-- новая функция
update_podkop_config
```

## Структура файла после изменений

```
urltest_proxy_links_updater.sh
├── show_help()
├── check_prerequisites()
├── get_hwid()
├── get_hwid_base64()
├── get_os_name()
├── get_os_version()
├── get_device_model()
├── get_headers()
├── is_base64()
├── decode_base64()
├── download_subscription()
├── validate_ipv4()           # новая
├── validate_domain()         # новая
├── validate_shadowsocks_url() # новая
├── validate_vless_url()      # новая
├── validate_trojan_url()     # новая
├── validate_socks_url()      # новая
├── validate_hysteria2_url()  # новая
├── validate_proxy_url()      # новая
├── filter_valid_links()      # новая
├── update_podkop_config()
└── main()
```

## Пример вывода при валидации

```
Found 150 configs
Saved to /tmp/sub_raw.txt
Validating proxy URLs...
Valid: 142 links
Invalid: 8 links
  - ss://... : Invalid Shadowsocks URL: missing port
  - vless://... : Invalid VLESS URL: missing query parameters
  - trojan://... : Invalid Trojan URL: invalid port number
Filtered valid links saved to /tmp/sub_valid.txt
```

## Тестирование

1. Создать тестовый файл с валидными и невалидными ссылками
2. Запускать не нужно, попросить пользователя запустить внутри openwrt и прислать результат
3. Проверить, что только валидные ссылки попали в конфигурацию
