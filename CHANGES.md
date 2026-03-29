# Сводка изменений: Валидация прокси-ссылок

## Дата: 29 марта 2026 г.

## Изменения в urltest_proxy_links_updater.sh

### Новые переменные
- `TMP_VALID="/tmp/sub_valid.txt"` - временный файл для валидных ссылок
- `VALID_COUNT=0` - счётчик валидных ссылок
- `INVALID_COUNT=0` - счётчик невалидных ссылок

### Новые функции валидации

#### Базовые валидаторы
1. **validate_ipv4()** - валидация IPv4 адресов
   - Проверка формата X.X.X.X
   - Проверка диапазона 0-255 для каждого октета
   - Отклонение ведущих нулей (01, 001, etc.)

2. **validate_domain()** - валидация доменных имён
   - Проверка допустимых символов: a-z, A-Z, 0-9, -, .
   - Проверка длины (макс. 253 символа)
   - Отклонение доменов, начинающихся/заканчивающихся на дефис

3. **validate_port()** - валидация номера порта
   - Проверка диапазона 1-65535

#### Вспомогательные функции
4. **extract_host()** - извлечение хоста из URL
5. **extract_port()** - извлечение порта из URL

#### Валидаторы протоколов
6. **validate_shadowsocks_url()** - валидация ss:// ссылок
   - Проверка префикса ss://
   - Проверка наличия хоста и порта
   - Валидация IPv4/домена

7. **validate_vless_url()** - валидация vless:// ссылок
   - Проверка префикса vless://
   - Проверка UUID
   - Проверка хоста и порта
   - Проверка query-параметров (type, security)
   - Поддерживаемые type: tcp, raw, udp, grpc, http, httpupgrade, xhttp, ws, kcp
   - Поддерживаемые security: tls, reality, none
   - Для reality: проверка pbk и fp
   - Отклонение flow=xtls-rprx-vision-udp443

8. **validate_trojan_url()** - валидация trojan:// ссылок
   - Проверка префикса trojan://
   - Проверка пароля
   - Проверка хоста и порта

9. **validate_socks_url()** - валидация socks4://, socks4a://, socks5:// ссылок
   - Проверка префикса
   - Проверка хоста и порта
   - Валидация IPv4/домена

10. **validate_hysteria2_url()** - валидация hysteria2:// и hy2:// ссылок
    - Проверка префикса
    - Проверка пароля
    - Проверка хоста и порта
    - Проверка insecure (0 или 1)
    - Проверка obfs (none или salamander)
    - Для obfs != none: проверка obfs-password
    - Проверка sni (не может быть пустым)

#### Основные функции
11. **validate_proxy_url()** - диспетчер валидации
    - Определяет тип URL по префиксу
    - Вызывает соответствующий валидатор
    - Поддерживаемые протоколы: ss, vless, trojan, socks4, socks4a, socks5, hysteria2, hy2

12. **filter_valid_links()** - фильтрация ссылок
    - Читает из stdin или файла
    - Пропускает пустые строки и комментарии
    - Валидирует каждую ссылку
    - Выводит [VALID]/[INVALID] в stderr
    - Выводит статистику [STATS] в stderr
    - Выводит только валидные URL в stdout

### Изменения в существующих функциях

#### download_subscription()
- Добавлен вызов `filter_valid_links()` после загрузки
- TMP_RAW обновляется только валидными ссылками
- Вывод количества валидных ссылок после фильтрации

## Формат вывода

### stderr (логи)
```
Validating proxy URLs...
[VALID] ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@192.168.1.1:8388
[INVALID] http://example.com - Unsupported protocol scheme
[INVALID] ss://user:pass@256.1.1.1:8080 - Invalid Shadowsocks URL: invalid IPv4 address
[INVALID] # comment - comment line
[STATS] Total: 50, Valid: 42, Invalid: 8
Filtered valid links saved to /tmp/sub_valid.txt
```

### stdout (валидные URL)
```
ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@192.168.1.1:8388
vless://uuid@domain.com:443?encryption=none&security=tls
trojan://password@host:443
```

## Структура файла после изменений

```
urltest_proxy_links_updater.sh (1045 строк)
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
├── validate_ipv4()              # новая
├── validate_domain()            # новая
├── validate_port()              # новая
├── extract_host()               # новая
├── extract_port()               # новая
├── validate_shadowsocks_url()   # новая
├── validate_vless_url()         # новая
├── validate_trojan_url()        # новая
├── validate_socks_url()         # новая
├── validate_hysteria2_url()     # новая
├── validate_proxy_url()         # новая
├── filter_valid_links()         # новая
├── download_subscription()      # обновлена
├── update_podkop_config()
└── main()
```

## Тестирование

Создан тестовый файл `test_sub.txt` с валидными и невалидными ссылками.

Для тестирования на OpenWrt:
```sh
# Копировать скрипт на роутер
scp urltest_proxy_links_updater.sh root@openwrt:/usr/bin/
chmod +x /usr/bin/urltest_proxy_links_updater.sh

# Запустить с тестовым файлом
/usr/bin/urltest_proxy_links_updater.sh test_sub.txt
```

## POSIX-совместимость

- Используется `#!/bin/sh` (не bash)
- Нет массивов bash
- Нет `[[ ]]` (используется `[ ]`)
- Нет `function` keyword
- Используются стандартные утилиты: grep, sed, awk, tr, cut

## Примечания

- Размер скрипта: 1045 строк (превышает целевые 200 строк из-за сложности валидации)
- Все функции возвращают 0 (валидно) или 1 (не валидно)
- Сообщения об ошибках выводятся в stderr
- Валидные URL выводятся в stdout для конвейерной обработки
- Интеграция: `download_subscription | filter_valid_links | update_podkop_config`
