# tailscale-openwrt

Настройка Tailscale на OpenWrt **рядом с zapret / netshift / Forkozz**: удалённое
управление роутером (SSH, LuCI) через tailnet без MagicDNS и без конфликтов с
цепочками DPI.

Один идиомпотентный POSIX-скрипт (`install-tailscale.sh`): ставит пакет,
делает зону файрвола, настраивает `tailscaled` флагами (а не «мёртвым» uci),
выключает MagicDNS и оставляет роутер со своим `resolv.conf`. Повторный запуск
на живом роутере безопасен — настройки приводятся к нужному виду, без
зряшнего ронiania узла.

## Почему именно так

- **Настройки — флагами `tailscale up/set`, а не uci.** Init-скрипт пакета
  читает из `/etc/config/tailscale` только `fw_mode` (плюс log_stdout,
  log_stderr, port, state_file). Всё остальное в uci — `accept_dns`,
  `accept_routes`, `advertise_exit_node`, `login_server` — **никто не читает**.
  Если `accept_dns` не выключить явно флагом `--accept-dns=false`, MagicDNS
  включится, tailscaled перезапишет `/etc/resolv.conf` на `100.100.100.100`,
  и при пустом бэкапе роутер молча останется без DNS: туннель будет висеть в
  «Try again» и падать в «Configuration parsing error».
- **`--netfilter-mode=off`.** Tailscale не ставит свои iptables/nftables-правила —
  изоляция трафика сделана отдельной зоной файрвола. Так `tailscaled` не
  конфликтует с `fw4` и с таблицами zapret/`NetShiftTable`.
- **`firewall reload`, а не `restart`** — полный рестарт дёргает цепочки
  zapret/netshift, reload перестраивает правила без этого.
- **`fw_mode=nftables`** — на сборках с nftables.

## Требования

- OpenWrt с `opkg` или `apk` (24.10+ — apk, раньше — opkg); `uci`, `firewall4`
- Свободное место на `/overlay` (ориентир 35 МБ, сам пакет ~25 МБ)
- Пакет `tailscale` в доступных репозиториях
- Корпоративный (self-hosted) координатор — по умолчанию `https://rc.routerich.ru/`
  или публичный `https://login.tailscale.com/` — адрес меняется переменной `LOGIN_SERVER`

## Установка

```sh
# 1. Скачать и проверить синтаксис (не лейте curl прямо в sh)
curl -fsSL -o /tmp/install-tailscale.sh \
  https://raw.githubusercontent.com/xDarkOne/tailscale-openwrt/main/install-tailscale.sh
sh -n /tmp/install-tailscale.sh

# 2. Запустить
sh /tmp/install-tailscale.sh
```

Без ключа скрипт на шаге `[5/6]` выдаст ссылку для авторизации (окно по
умолчанию 120 с). При запуске **по SSH** (без терминала) полный вывод `tailscale up`,
включая ссылку, дополнительно пишется в **`/tmp/tailscale-auth.log`** —
подхватите его, пока окно не закрылось.

С ключом — без интерактива:

```sh
TS_AUTHKEY=... sh /tmp/install-tailscale.sh
```

## Переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `LOGIN_SERVER` | `https://rc.routerich.ru/` | адрес координатора |
| `TS_AUTHKEY` | — | ключ для неинтерактивной авторизации |
| `TS_UP_TIMEOUT` | `120s` | сколько ждать авторизации в интерактивном режиме |
| `TS_HOSTNAME` | — (не трогаем) | имя узла в tailnet |
| `ALLOW_TAILNET_TO_WAN` | `0` | `1` — выпускать тайнет в интернет через этот роутер (exit-нода) |
| `TS_INPUT_POLICY` | `ACCEPT` | входной трафик из tailnet: `ACCEPT` (всё) или `DROP` (только SSH 22/tcp и LuCI 80/tcp) |
| `TS_ADVERTISE_ROUTES` | — | публиковать подсети в tailnet через prefs, например `192.168.10.0/24,100.99.0.0/16` |
| `DNS_FALLBACK` | `netshift.bootstrap_dns_server`, иначе `77.88.8.8` | запасной резолвер в `resolv.conf` роутера |
| `ASSUME_YES` | `0` | историческая; вопросов в скрипте нет |

Пример с опциями:

```sh
TS_INPUT_POLICY=DROP \
TS_ADVERTISE_ROUTES="192.168.10.0/24" \
TS_HOSTNAME="tr3000" \
TS_AUTHKEY=... sh /tmp/install-tailscale.sh
```

## Совместимость с zapret / netshift / Forkozz

Проверено на живых роутерах (OpenWrt 25.12, Cudy TR3000 / WBR3000):

| Компонент | Что делает скрипт |
|---|---|
| `fw4` (штатный файрвол) | `firewall reload` — перестраивает только свою таблицу |
| zapret (byedpi) | свою таблицу nftables `zapret` не трогает |
| netshift / Forkozz | своя таблица `NetShiftTable` независима от `fw4`, `tailscaled` с `--netfilter-mode=off` правил не добавляет |
| sing-box (движок форка) | работает параллельно с `tailscaled` |

После установки стоит убедиться, что движок DPI всё ещё на месте:
`nft list tables` (должна быть `NetShiftTable`/`zapret`) и `tailscale status`.

## Безопасность

- Зона `tailscale` по умолчанию `input=ACCEPT` — осознанный компромисс:
  через tailnet доступны все службы на `0.0.0.0` (в т.ч. dnsmasq на 53).
  Ужесточить: `TS_INPUT_POLICY=DROP` — тогда открыты только SSH и LuCI
  (если LuCI на нестандартном порту, добавьте своё правило:
  `uci add_list`/`uci set firewall.ts_in_luci.src_dport=<порт>`).
- `TS_AUTHKEY` **не попадает** в вывод, логи и сообщения об ошибках
  (в командах-подсказках маскается). В любом случае ключ одноразовый —
  удалите его в панели координатора после установки.
- MagicDNS выключен: `/etc/resolv.conf` роутера остаётся своим
  (`127.0.0.1` + запасной), бэкап прежнего файла — `/root/resolv.conf.bak-<ts>`.

## Проверка после установки

```sh
tailscale status                                  # узел online, список пиров
tailscale ip                                      # адрес в tailnet
tailscale debug prefs | grep -E 'CorpDNS|NetfilterMode|RouteAll'
#   CorpDNS: false, NetfilterMode: 0 (off) — как надо
nft list tables                                   # NetShiftTable/zapret на месте
cat /etc/resolv.conf                              # 127.0.0.1 + запасной
```

Из другого устройства tailnet:

```sh
ping -c 3 100.x.x.x
curl -s -o /dev/null -w '%{http_code}\n' -u root:PASSWORD http://100.x.x.x/   # → 200
```

## Откат

DNS-часть (если что-то пошло не так с резолвом):

```sh
cp /root/resolv.conf.bak-<ts> /etc/resolv.conf
```

Полный:

```sh
/etc/init.d/tailscale stop && /etc/init.d/tailscale disable
apk del tailscale          # или: opkg remove tailscale
uci delete firewall.tszone; uci delete firewall.ts_ac_lan
uci delete firewall.lan_ac_ts; uci delete firewall.ts_ac_wan
/etc/init.d/firewall reload
```

## FAQ

**Установка вешается на «Ставим пакет Tailscale»** — зеркало медленное
(на некоторых роутерах до OpenWrt-зеркал ~30–100 КБ/с, пакет ~10 МБ).
Скрипт сам повторяет установку 3 раза; можно просто подождать.

**Проверка «резолв не работает»** — скрипт откатил `resolv.conf` из бэкапа.
Посмотрите, чем на самом деле отвечает `nslookup openwrt.org`, и запустите
с `DNS_FALLBACK=<ip>`.

**Узла нет в tailnet после «Готово»** — `tailscale status` на роутере;
если `NeedsLogin` — завершите авторизацию: ссылка в `/tmp/tailscale-auth.log`
(окно 120 с, либо повторите `tailscale up` с ключом).

**После обрыва установки «пакет установлен, а бинарника нет»** — скрипт сам
чинит через `apk fix tailscale` при повторном запуске.
