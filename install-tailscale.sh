#!/bin/sh
#
# Настройка Tailscale на OpenWrt рядом с zapret/netshift.
# Репозиторий: https://github.com/xDarkOne/tailscale-openwrt
#
# Главное отличие от прежней версии: настройки задаются самому tailscaled
# флагами, а не через uci. Init-скрипт пакета (/etc/init.d/tailscale) читает
# из /etc/config/tailscale ровно пять опций — log_stdout, log_stderr, port,
# state_file и fw_mode. Всё остальное там лежит мёртвым грузом: ни accept_dns,
# ни accept_routes, ни advertise_exit_node, ни login_server, ни access никто
# не читает. Прежний скрипт выставлял accept_dns='0' в uci и считал дело
# сделанным, а затем звал `tailscale up --reset` — и вот он-то и решал: у
# --accept-dns значение по умолчанию true, а --reset возвращает к умолчаниям
# всё, что не задано явно. В итоге MagicDNS включался на каждом роутере.
#
# Чем это плохо: tailscaled перезаписывает /etc/resolv.conf на 100.100.100.100
# и пересылает запросы туда, что однажды сохранил в
# /etc/resolv.pre-tailscale-backup.conf. Если там окажется пусто, роутер
# остаётся без DNS вообще — и это видно не как «нет DNS», а как мёртвый
# туннель: netifd не может разрешить endpoint AWG, висит в «Try again» и
# падает в «Configuration parsing error».
#
# Что нового в этой версии:
#   - TS_AUTHKEY больше не попадает в логи и сообщения об ошибках
#   - повторные попытки установки пакета (нестабильные зеркала)
#   - авторизационная ссылка при запуске по SSH дублируется в
#     /tmp/tailscale-auth.log, чтобы не пропустить окно авторизации
#   - TS_INPUT_POLICY=DROP: вместо blanket-ACCEPT только SSH и LuCI
#   - TS_ADVERTISE_ROUTES: публикация подсетей в тайнет (через prefs,
#     а не мёртвым uci)
#   - восстановление «пол-пакета» после обрыва установки (apk fix)
#   - проверка состояния узла после авторизации
#
# Запуск:
#   sh install-tailscale.sh
#
# Переменные окружения (все необязательные):
#   LOGIN_SERVER          адрес координатора (по умолчанию https://rc.routerich.ru/)
#   TS_AUTHKEY            ключ для неинтерактивной установки
#   TS_UP_TIMEOUT         сколько ждать авторизации (по умолчанию 120s)
#   TS_HOSTNAME           имя узла в тайнете; пусто — не трогаем существующее
#   ALLOW_TAILNET_TO_WAN  1 — выпускать тайнет в интернет через этот роутер
#   TS_INPUT_POLICY       политика входного трафика из тайнета:
#                         ACCEPT (по умолчанию) или DROP
#                         (для DROP открываются только SSH 22/tcp и LuCI 80/tcp;
#                         если LuCI на нестандартном порту — добавьте правило сами)
#   TS_ADVERTISE_ROUTES   подсети, публикуемые в тайнет, через запятую
#                         (например "192.168.10.0/24,100.99.0.0/16")
#   DNS_FALLBACK          запасной резолвер роутера
#   ASSUME_YES            1 — не задавать вопросов (историческая, вопросы в
#                         скрипте нет — переменная оставлена для совместимости)

set -u

LOGIN_SERVER="${LOGIN_SERVER:-https://rc.routerich.ru/}"
ZONE_NAME="tailscale"
INTERFACE_MASK="tailscale+"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_UP_TIMEOUT="${TS_UP_TIMEOUT:-120s}"
TS_HOSTNAME="${TS_HOSTNAME:-}"
ALLOW_TAILNET_TO_WAN="${ALLOW_TAILNET_TO_WAN:-0}"
TS_INPUT_POLICY="${TS_INPUT_POLICY:-ACCEPT}"
TS_ADVERTISE_ROUTES="${TS_ADVERTISE_ROUTES:-}"
DNS_FALLBACK="${DNS_FALLBACK:-}"
ASSUME_YES="${ASSUME_YES:-0}"

# Реальный установленный размер Tailscale ~25 МБ (apk info -s tailscale).
# На UBIFS df занижает свободное место (не учитывает сжатие), поэтому порог —
# только ориентир для предупреждения, а не повод прерваться: настоящая защита
# в том, что apk сам вернёт ENOSPC, плюс пост-проверка ниже.
REQUIRED_SPACE_MB=35
REQUIRED_SPACE_KB=$((REQUIRED_SPACE_MB * 1024))

say() { printf '\n%s\n' "$1"; }
die() { printf '\n [ОШИБКА] %s\n' "$1" >&2; exit 1; }

# Скрывает auth key из логов и сообщений об ошибках.
mask_cmd() {
    if [ -n "$TS_AUTHKEY" ]; then
        printf '%s\n' "$1" | sed 's#--auth-key=[^ ]*#--auth-key=***#g'
    else
        printf '%s\n' "$1"
    fi
}

# Состояние tailscaled; jq берём, если есть, — он надёжнее sed по JSON.
get_state() {
    if command -v jq >/dev/null 2>&1; then
        tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' | head -n1
    else
        tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -n1
    fi
}

echo "========================================================================="
echo " Настройка Tailscale для OpenWrt (совместимо с zapret/netshift)          "
echo "========================================================================="

[ "$(id -u)" = "0" ] || die "Нужны права root."
command -v uci >/dev/null 2>&1 || die "Это не OpenWrt: не найден uci."
case "$TS_INPUT_POLICY" in
    ACCEPT|DROP) ;;
    *) die "TS_INPUT_POLICY принимает только ACCEPT или DROP (задано: '$TS_INPUT_POLICY')" ;;
esac

# Уже установлен? Тогда не переустанавливаем, но настройки всё равно
# приводим к нужному виду. Прежний скрипт в этом месте просто выходил, и
# починить съехавшую настройку повторным запуском было нельзя.
ALREADY_INSTALLED=0
command -v tailscale >/dev/null 2>&1 && ALREADY_INSTALLED=1

# Пакет числится в базе, но бинарника нет (установка оборвалась посреди
# транзакции): apk в таком состоянии сам себе помочь не пообещает — чиним.
if [ "$ALREADY_INSTALLED" = "0" ] && command -v apk >/dev/null 2>&1 &&
   [ -n "$(apk info -e tailscale 2>/dev/null)" ]; then
    echo "-> tailscale числится в базе пакетов, но бинарника нет — чиню: apk fix"
    apk fix tailscale >/dev/null 2>&1 || :
    command -v tailscale >/dev/null 2>&1 && ALREADY_INSTALLED=1
fi

# ── [0/6] Место на накопителе ────────────────────────────────────────────
say "[0/6] Проверка свободного места..."
if [ "$ALREADY_INSTALLED" = "1" ]; then
    echo "-> Tailscale уже установлен, проверка места не нужна."
else
    if [ -d /overlay ]; then CHECK_MOUNT="/overlay"; else CHECK_MOUNT="/"; fi
    FREE_SPACE_KB=$(df -k "$CHECK_MOUNT" 2>/dev/null | awk 'NR==2 {print $4}')
    FS_TYPE=$(mount 2>/dev/null | awk -v m="$CHECK_MOUNT" '$3==m {print $5; exit}')

    if ! [ "${FREE_SPACE_KB:-x}" -eq "${FREE_SPACE_KB:-x}" ] 2>/dev/null; then
        echo " [ПРЕДУПРЕЖДЕНИЕ] Не удалось определить свободное место. Продолжаем."
    elif [ "$FREE_SPACE_KB" -lt "$REQUIRED_SPACE_KB" ]; then
        echo " [ВНИМАНИЕ] df показывает $((FREE_SPACE_KB / 1024)) МБ на $CHECK_MOUNT"
        echo "            (${FS_TYPE:-неизв.}), ориентир ${REQUIRED_SPACE_MB} МБ."
        if [ "$FS_TYPE" = "ubifs" ]; then
            echo " -> UBIFS занижает оценку из-за сжатия. Не прерываюсь."
        else
            echo " -> Продолжаю: пакетный менеджер откажется сам, если места нет."
        fi
    else
        echo "-> Места достаточно: $((FREE_SPACE_KB / 1024)) МБ на $CHECK_MOUNT."
    fi
fi

# ── [1/6] Установка пакета ───────────────────────────────────────────────
say "[1/6] Установка пакета Tailscale..."
if [ "$ALREADY_INSTALLED" = "1" ]; then
    echo "-> Уже установлен ($(tailscale version 2>/dev/null | head -1)), пропускаю."
else
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"; PKG_VERB="add"
        echo "-> Менеджер: apk (OpenWrt 24.10+)"
    else
        PKG_MGR="opkg"; PKG_VERB="install"
        echo "-> Менеджер: opkg"
    fi
    PKG_OK=0
    PKG_TRY=1
    # Зеркала OpenWrt бывают медленными и нестабильными: пакет ~10 МБ легко
    # не доезжает при первом скачивании. Повторяем с чисткой кэша.
    while [ "$PKG_TRY" -le 3 ]; do
        if { "$PKG_MGR" update && "$PKG_MGR" "$PKG_VERB" tailscale; }; then
            PKG_OK=1
            break
        fi
        [ "$PKG_MGR" = "apk" ] && apk cache clean >/dev/null 2>&1
        rm -f /tmp/opkg-*/*.ipk 2>/dev/null || :
        echo " ↻ Установка не удалась (попытка $PKG_TRY/3), повторяю..."
        sleep 5
        PKG_TRY=$((PKG_TRY + 1))
    done

    [ "$PKG_OK" = "1" ] || die \
"Установка не удалась (чаще всего не хватило места при распаковке
 или зеркало не стабильно). Мусор пакетного менеджера подчищен,
 файрвол не трогали — система осталась в прежнем состоянии."

    command -v tailscale >/dev/null 2>&1 || die \
"Пакет менеджер считает установленным, но бинарника нет.
 Попробуйте: apk fix tailscale  (или opkg install --force-reinstall tailscale)"
    echo "-> Пакет установлен."
fi

# ── [2/6] Зона файрвола ──────────────────────────────────────────────────
say "[2/6] Изоляция трафика в файрволе..."

uci set firewall.tszone=zone
uci set firewall.tszone.name="${ZONE_NAME}"
# input=ACCEPT — это осознанно: через тайнет мы ходим в SSH и LuCI роутера.
# Но помните, что так же открыты и остальные службы, слушающие 0.0.0.0
# (например dnsmasq отвечает на 53 и на tailscale-адресе).
# Ужесточить: TS_INPUT_POLICY=DROP — откроются только SSH и LuCI.
uci set firewall.tszone.input="$TS_INPUT_POLICY"
uci set firewall.tszone.output='ACCEPT'
uci set firewall.tszone.forward='ACCEPT'
uci set firewall.tszone.masq='1'
uci set firewall.tszone.mtu_fix='1'
# Полное удаление списка перед добавлением: иначе при повторных прогонах
# маска копится дубликатами (видел 'tailscale+' 'tailscale+' на живом роутере).
uci -q delete firewall.tszone.device
uci add_list firewall.tszone.device="${INTERFACE_MASK}"

# Для DROP-политики — точечные правила. Для ACCEPT они не нужны и убираются,
# чтобы повторный прогон с изменённой политикой не копил хвосты.
if [ "$TS_INPUT_POLICY" = "DROP" ]; then
    uci set firewall.ts_in_ssh=rule
    uci set firewall.ts_in_ssh.name='Tailscale: SSH'
    uci set firewall.ts_in_ssh.src="${ZONE_NAME}"
    uci set firewall.ts_in_ssh.proto='tcp'
    uci set firewall.ts_in_ssh.src_dport='22'
    uci set firewall.ts_in_ssh.target='ACCEPT'

    uci set firewall.ts_in_luci=rule
    uci set firewall.ts_in_luci.name='Tailscale: LuCI'
    uci set firewall.ts_in_luci.src="${ZONE_NAME}"
    uci set firewall.ts_in_luci.proto='tcp'
    uci set firewall.ts_in_luci.src_dport='80'
    uci set firewall.ts_in_luci.target='ACCEPT'
else
    uci -q delete firewall.ts_in_ssh
    uci -q delete firewall.ts_in_luci
fi

uci set firewall.ts_ac_lan=forwarding
uci set firewall.ts_ac_lan.src="${ZONE_NAME}"
uci set firewall.ts_ac_lan.dest='lan'

uci set firewall.lan_ac_ts=forwarding
uci set firewall.lan_ac_ts.src='lan'
uci set firewall.lan_ac_ts.dest="${ZONE_NAME}"

# Выпуск тайнета в интернет через этот роутер нужен только если он работает
# exit-нодой. По умолчанию не работает, поэтому правило по умолчанию не ставим.
if [ "$ALLOW_TAILNET_TO_WAN" = "1" ]; then
    uci set firewall.ts_ac_wan=forwarding
    uci set firewall.ts_ac_wan.src="${ZONE_NAME}"
    uci set firewall.ts_ac_wan.dest='wan'
else
    uci -q delete firewall.ts_ac_wan
fi

uci commit firewall
# reload, а не restart: полный рестарт дёргает zapret и netshift, которые
# подмешивают свои цепочки в nftables. reload перестраивает набор правил
# целиком и этого достаточно.
/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1
echo "-> Зона '${ZONE_NAME}' (input=${TS_INPUT_POLICY}) и проброс между ней и lan настроены."

# ── [3/6] Параметры службы ───────────────────────────────────────────────
say "[3/6] Параметры службы..."
# Если секции нет (бывает на сборках без дефолтного конфига), uci set по
# ключу внутри неё упадёт — заводим секцию заранее.
uci -q get tailscale.settings >/dev/null 2>&1 || uci set tailscale.settings=settings

# Единственная опция отсюда, которую init-скрипт действительно читает.
# Запоминаем прежнее значение: только его изменение требует перезапуска демона.
FW_MODE_OLD=$(uci -q get tailscale.settings.fw_mode 2>/dev/null || echo "")
uci set tailscale.settings.fw_mode='nftables'

# Остальное init-скрипт игнорирует; держим как документацию к тому, что
# фактически задано флагами ниже, чтобы значения не расходились.
uci set tailscale.settings.accept_routes='0'
uci set tailscale.settings.accept_dns='0'
uci set tailscale.settings.advertise_exit_node='0'
uci set tailscale.settings.login_server="${LOGIN_SERVER}"

uci -q del_list tailscale.settings.access='ts_ac_lan'
uci -q del_list tailscale.settings.access='ts_ac_wan'
uci -q del_list tailscale.settings.access='lan_ac_ts'
uci add_list tailscale.settings.access='ts_ac_lan'
uci add_list tailscale.settings.access='lan_ac_ts'
[ "$ALLOW_TAILNET_TO_WAN" = "1" ] && uci add_list tailscale.settings.access='ts_ac_wan'

uci commit tailscale
echo "-> Конфиг зафиксирован (реально используется только fw_mode)."

# ── [4/6] Демон ──────────────────────────────────────────────────────────
say "[4/6] Запуск tailscaled..."
/etc/init.d/tailscale enable >/dev/null 2>&1
# Перезапускаем только по делу: демон не запущен или сменился fw_mode (он
# передаётся через env, на лету не подхватится). Иначе повторный прогон
# скрипта на живом роутере ронял бы узел из тайнета просто так.
# pgrep без -x: busybox 1.37 pgrep -x на OpenWrt не матчит tailscaled
# (проверено на живом роутере), хотя comm как раз «tailscaled».
if ! pgrep tailscaled >/dev/null 2>&1; then
    echo "-> Демон не запущен, запускаю."
    /etc/init.d/tailscale start >/dev/null 2>&1
elif [ "$FW_MODE_OLD" != "nftables" ]; then
    echo "-> fw_mode изменился ('${FW_MODE_OLD:-не задан}' -> 'nftables'), перезапускаю."
    /etc/init.d/tailscale restart >/dev/null 2>&1
else
    echo "-> Демон уже работает с нужным fw_mode, не трогаю."
fi

# Ждём сокет, иначе следующая команда упрётся в «failed to connect».
i=0
while [ "$i" -lt 30 ]; do
    tailscale status >/dev/null 2>&1 && break
    tailscale status 2>&1 | grep -q "Logged out\|NeedsLogin" && break
    i=$((i + 1)); sleep 1
done
pgrep tailscaled >/dev/null 2>&1 ||
    die "tailscaled не запустился. Посмотрите: logread | grep -i tailscaled"
echo "-> Служба запущена и добавлена в автозагрузку."

# ── [5/6] Настройки самого tailscaled ────────────────────────────────────
say "[5/6] Применение настроек..."

STATE=$(get_state)
echo "-> Состояние: ${STATE:-неизвестно}"

# --accept-dns=false — та самая настройка, из-за которой всё затевалось.
# Указываем явно: по умолчанию она true, и никакой uci её не выключит.
# --netfilter-mode=off — свои правила tailscale не ставит, изоляция сделана
# зоной выше; так он не конфликтует с цепочками zapret.
PREFS="--accept-dns=false --accept-routes=false --advertise-exit-node=false --netfilter-mode=off"
[ -n "$TS_HOSTNAME" ] && PREFS="$PREFS --hostname=${TS_HOSTNAME}"
# Публикация подсетей — только через prefs: в uci это мёртвые значения,
# которые init-скрипт не читает.
[ -n "$TS_ADVERTISE_ROUTES" ] && PREFS="$PREFS --advertise-routes=${TS_ADVERTISE_ROUTES}"

if [ "$STATE" = "Running" ]; then
    # Узел уже авторизован: правим настройки, не трогая учётные данные.
    # `up --reset` здесь был бы лишним риском — он сбрасывает всё незаданное
    # к умолчаниям, а заодно заново прогоняет вход.
    # shellcheck disable=SC2086
    tailscale set $PREFS || die "Не удалось применить настройки."
    echo "-> Настройки обновлены без переавторизации."
else
    UP="--login-server=${LOGIN_SERVER} --timeout=${TS_UP_TIMEOUT} $PREFS"
    [ -n "$TS_AUTHKEY" ] && UP="$UP --auth-key=${TS_AUTHKEY}"
    echo "Предупреждение о netfilter=off — это нормально."
    if [ -z "$TS_AUTHKEY" ]; then
        echo "Если устройство подключается впервые, перейдите по ссылке ниже."
        echo "Ожидание ограничено ${TS_UP_TIMEOUT} — скрипт не повиснет навсегда."
    fi
    echo "------------------------------------------------------------------------"
    # Вывод команды уходит в файл и на экран: при запуске по SSH (без
    # терминала) ссылка видна не «на лету», а когда команда завершится, —
    # и её легко пропустить к моменту, когда окно авторизации уже закрыто.
    AUTHLOG=/tmp/tailscale-auth.log
    : > "$AUTHLOG"
    # shellcheck disable=SC2086
    if tailscale up $UP >>"$AUTHLOG" 2>&1; then
        AUTH_RC=0
    else
        AUTH_RC=1
    fi
    cat "$AUTHLOG"
    if [ ! -t 1 ]; then
        echo "-> Запуск без терминала: полный вывод (включая ссылку) в $AUTHLOG"
    fi
    echo "------------------------------------------------------------------------"
    [ "$AUTH_RC" = "0" ] || die "Авторизация не завершена. Вывод: $AUTHLOG
 Повторите на роутере: tailscale up $(mask_cmd "$UP")"
fi

# После успешной авторизации узлу нужно пару секунд, чтобы дойти до Running.
i=0
while [ "$i" -lt 15 ]; do
    [ "$(get_state)" = "Running" ] && break
    i=$((i + 1)); sleep 2
done
if [ "$(get_state)" != "Running" ]; then
    echo " [!] Узел ещё не в состоянии Running (состояние: $(get_state)).
   Туннель поднимется чуть позже; проверьте: tailscale status"
fi

# ── [6/6] Резолвер самого роутера ────────────────────────────────────────
say "[6/6] Настройка резолвера роутера..."

# Раз MagicDNS выключен, /etc/resolv.conf снова наш. Двух записей мало не
# бывает: 127.0.0.1 — свой dnsmasq, а запасной нужен на окно загрузки, когда
# dnsmasq уже поднялся, но его апстрим (sing-box) — ещё нет. Без запасного
# роутер в это окно не разрешит endpoint туннеля.
if [ -z "$DNS_FALLBACK" ]; then
    DNS_FALLBACK=$(uci -q get netshift.settings.bootstrap_dns_server 2>/dev/null)
    case "${DNS_FALLBACK:-}" in
        ""|*[!0-9.]*) DNS_FALLBACK="77.88.8.8" ;;
    esac
fi

RESOLV_NEW="/tmp/resolv.conf.new.$$"
cat > "$RESOLV_NEW" <<EOF
# Резолвер самого роутера. DNS клиентов идёт другим путём (dnsmasq и, если
# он есть, sing-box на 127.0.0.42) и этого файла не касается.
#
# Tailscale тут не хозяйничает: у него --accept-dns=false. Иначе он пишет
# сюда 100.100.100.100 и пересылает запросы туда, что однажды сохранил в
# /etc/resolv.pre-tailscale-backup.conf. Если там пусто — роутер молча
# остаётся без DNS, netifd не может разрешить endpoint туннеля, и интерфейс
# виснет в "Try again", а затем падает в "Configuration parsing error".
#
# ${DNS_FALLBACK} — запасной на окно загрузки, пока апстрим dnsmasq не встал.
nameserver 127.0.0.1
nameserver ${DNS_FALLBACK}
EOF

# Копию делаем только когда файл действительно меняется, иначе повторные
# прогоны засоряют /root десятком одинаковых resolv.conf.bak-*.
RESOLV_BAK=""
if cmp -s "$RESOLV_NEW" /etc/resolv.conf 2>/dev/null; then
    rm -f "$RESOLV_NEW"
    echo "-> Резолвер уже настроен как надо, файл не трогаю."
else
    RESOLV_BAK="/root/resolv.conf.bak-$(date +%s)"
    cp -a /etc/resolv.conf "$RESOLV_BAK" 2>/dev/null || : > "$RESOLV_BAK"
    cat "$RESOLV_NEW" > /etc/resolv.conf
    rm -f "$RESOLV_NEW"
    echo "-> Записан свой resolv.conf (127.0.0.1 + ${DNS_FALLBACK})."
fi

# ── Проверка и откат ─────────────────────────────────────────────────────
say "Проверка..."
OK=1
TESTNAME="openwrt.org"
nslookup "$TESTNAME" >/dev/null 2>&1 || { echo " [!] резолв не работает"; OK=0; }
ip r 2>/dev/null | grep -q "^default .*dev tailscale" && { echo " [!] дефолтный маршрут уехал в тайнет"; OK=0; }
pgrep tailscaled >/dev/null 2>&1 || { echo " [!] tailscaled не запущен"; OK=0; }

if [ "$OK" != "1" ]; then
    if [ -n "$RESOLV_BAK" ]; then
        echo " -> Откатываю /etc/resolv.conf из ${RESOLV_BAK}"
        cp -a "$RESOLV_BAK" /etc/resolv.conf 2>/dev/null
    else
        echo " -> resolv.conf не менялся, откатывать нечего."
    fi
    die "Проверка не прошла. Файрвол и настройки Tailscale оставлены как есть."
fi

echo "-> Резолв работает, маршрут по умолчанию на месте, служба жива."
[ -n "$RESOLV_BAK" ] && echo "   Резервная копия прежнего resolv.conf: ${RESOLV_BAK}"

echo "========================================================================="
echo " Готово. Адрес роутера в сети Tailscale:"
tailscale ip 2>/dev/null || echo " (устройство ещё не авторизовано)"
echo "========================================================================="
echo " Проверить настройки:  tailscale debug prefs | grep -E 'CorpDNS|RouteAll'"
if [ -n "$RESOLV_BAK" ]; then
    echo " Откатить DNS-часть:   cp ${RESOLV_BAK} /etc/resolv.conf && tailscale set --accept-dns=true"
else
    echo " Вернуть MagicDNS:     tailscale set --accept-dns=true"
fi
echo "========================================================================="
