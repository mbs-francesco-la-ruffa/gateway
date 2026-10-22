#!/usr/bin/env bash
#
# Tries the gateway image in docker, the way Railway runs it: no start command, every setting a
# variable. Two fake apps (tests/upstream.py) sit behind it on a network of its own, and every
# container, the network included, is removed at the end, Ctrl-C included. Nothing is published but
# one port on 127.0.0.1 that docker picks, so it runs beside any other stack.
#
#   bash tests/check.sh                          builds the image from this folder, then checks it
#   GATEWAY_IMAGE=gateway:dev bash tests/check.sh   checks an image built already
#   CHECK_BROWSER=0 bash tests/check.sh          skips the browser part (tests/browser.mjs)
#   SHOTS=/some/dir bash tests/check.sh          also saves screenshots of the page there
#
# CHECK_GATEWAY_SCRIPT=<copy of gateway.sh> and CHECK_GATEWAY_PAGE=<copy of page.html> mount a
# deliberately broken copy over the image's own: how a mutation proves a check can fail without
# touching the real files.
#
# Needs docker, curl, jq and python3, and the images python:3.12-alpine and (for the browser part)
# mcr.microsoft.com/playwright, which docker pulls the first time. About two minutes.
set -uo pipefail

cd "$(dirname "$0")/.."

RUN=gwcheck-$$
NET=$RUN
GW=$RUN-gateway
UPSTREAM_IMAGE=python:3.12-alpine
PLAYWRIGHT=1.49.0
PLAYWRIGHT_IMAGE=mcr.microsoft.com/playwright:v$PLAYWRIGHT-noble

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'
[ -t 1 ] || { BOLD=''; RED=''; GREEN=''; OFF=''; }

PASSED=0
FAILED=0
ok() { PASSED=$((PASSED + 1)); echo "${GREEN}ok${OFF}   $1"; }
ko() { FAILED=$((FAILED + 1)); echo "${RED}FAIL${OFF} $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/     /'; }
check() { # check <description> <condition...>
  local what=$1; shift
  if "$@"; then ok "$what"; else ko "$what" "${DETAIL:-}"; fi
  DETAIL=''
}

cleanup() {
  docker rm -f "$GW" "$RUN-a" "$RUN-b" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$TMP"
}
TMP=$(mktemp -d)
mkdir -p "$TMP/pages"
trap cleanup EXIT
trap 'exit 130' INT TERM

IMAGE=${GATEWAY_IMAGE:-}
if [ -z "$IMAGE" ]; then
  IMAGE=gateway:check
  echo "${BOLD}building $IMAGE${OFF}"
  docker build -q -t "$IMAGE" . >/dev/null || exit 1
fi
MOUNTS=()
# The copy is made executable here, so a mutation fails on what it changed and not on its mode.
if [ -n "${CHECK_GATEWAY_SCRIPT:-}" ]; then
  install -m 0755 "$CHECK_GATEWAY_SCRIPT" "$TMP/gateway" && MOUNTS+=(-v "$TMP/gateway:/usr/local/bin/gateway:ro")
fi
[ -n "${CHECK_GATEWAY_PAGE:-}" ] && MOUNTS+=(-v "$(realpath "$CHECK_GATEWAY_PAGE"):/usr/share/gateway/page.html:ro")

echo "${BOLD}gateway check${OFF}: $IMAGE${MOUNTS[*]:+ (with ${MOUNTS[*]})}"

docker network create "$NET" >/dev/null || exit 1
for name in a b; do
  docker run -d --name "$RUN-$name" --network "$NET" --network-alias "up-$name" -e NAME="$name" \
    -v "$PWD/tests/upstream.py:/upstream.py:ro" "$UPSTREAM_IMAGE" python -u /upstream.py >/dev/null || exit 1
done
# Both fake apps listening before the first request, or the first one may find nobody (a 503 that is
# the check's fault, not the gateway's).
for name in a b; do
  for _ in $(seq 1 50); do
    docker exec "$RUN-$name" wget -qO /dev/null http://127.0.0.1:8080/ready 2>/dev/null && break
    sleep 0.2
  done
done

ROUTES_AB='a.test=http://up-a:8080,b.test=http://up-b:8080'

# start_gateway [-e VAR=value ...]: replaces the gateway and waits for its healthcheck.
start_gateway() {
  docker rm -f "$GW" >/dev/null 2>&1
  docker run -d --name "$GW" --network "$NET" -p 127.0.0.1::8080 "${MOUNTS[@]}" "$@" "$IMAGE" >/dev/null || return 1
  BASE="http://127.0.0.1:$(docker port "$GW" 8080/tcp | head -n1 | sed 's/.*://')"
  for _ in $(seq 1 50); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/_gateway/health")" = 200 ] && return 0
    sleep 0.2
  done
  ko "the gateway comes up" "$(docker logs "$GW" 2>&1 | tail -n 3)"
  return 1
}

# req <host> [curl args...]: status, headers and body of one request, in $TMP/h and $TMP/b.
req() {
  local host=$1; shift
  CODE=$(curl -s -o "$TMP/b" -D "$TMP/h" -w '%{http_code}' -H "Host: $host" "$@")
}
has_header() { grep -qi "^$1" "$TMP/h"; }
body_has() { grep -qF -- "$1" "$TMP/b"; }
body_lacks() { ! grep -qF -- "$1" "$TMP/b"; }
is() { [ "$1" = "$2" ] || { DETAIL="expected [$2], got [$1]"; return 1; }; }

# page_is <expectations JSON>: the page last fetched, checked by tests/page_check.py.
page_is() { DETAIL=$(python3 tests/page_check.py "$TMP/b" "$1"); }

# page <name> [-e VAR=value ...]: maintenance on with these variables; the page lands in $TMP/b and in
# $TMP/pages/<name>.html (for the browser part), the JSON in $TMP/j.
page() {
  local name=$1; shift
  start_gateway -e ROUTES="$ROUTES_AB" -e MAINTENANCE=on "$@" || return 1
  curl -s -H 'Host: a.test' -H 'Accept: application/json' -o "$TMP/j" "$BASE/x"
  req a.test "$BASE/"
  cp "$TMP/b" "$TMP/pages/$name.html"
}

# expect_refusal <description> <words of the reason> [-e VAR=value ...]: the gateway must stop before
# Caddy starts, for that reason. A gateway that does start is stopped after 10 seconds and counts as a
# failure, rather than hanging the check.
expect_refusal() {
  local what=$1 why=$2; shift 2
  docker rm -f "$GW" >/dev/null 2>&1
  docker run -d --name "$GW" --network "$NET" "${MOUNTS[@]}" "$@" "$IMAGE" >/dev/null
  local code
  code=$(timeout 10 docker wait "$GW" 2>/dev/null) || { docker stop -t 1 "$GW" >/dev/null 2>&1; code=running; }
  docker logs "$GW" >"$TMP/out" 2>"$TMP/err"
  if [ "$code" != running ] && [ "$code" -ne 0 ] && grep -qF -- "$why" "$TMP/err" && grep -q '^gateway: ' "$TMP/err" &&
    ! grep -q 'serving initial configuration' "$TMP/out"; then
    ok "refused: $what ($(head -n1 "$TMP/err"))"
  else
    ko "refused: $what" "exit $code, stderr: $(head -n2 "$TMP/err" | tr '\n' ' ')"
  fi
}

echo "${BOLD}maintenance off, two hosts${OFF}"
if start_gateway -e ROUTES="$ROUTES_AB"; then
  req a.test "$BASE/x?y=1" -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 203.0.113.7'
  check "a.test reaches upstream a" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
  check "the host arrives unchanged" is "$(jq -r .host "$TMP/b")" "a.test"
  check "X-Forwarded-Proto from the edge arrives" is "$(jq -r .xfp "$TMP/b")" "https"
  check "X-Forwarded-For from the edge arrives as the edge wrote it" is "$(jq -r .xff "$TMP/b")" "203.0.113.7"
  check "  and the app's answer has no X-Gateway" bash -c "! grep -qi '^x-gateway' '$TMP/h'"
  req b.test "$BASE/x"
  check "b.test reaches upstream b" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/b"
  req B.Test "$BASE/x"
  check "a host in capitals is the same host" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/b"
  req c.test "$BASE/x"
  check "an unknown host gets 404" is "$CODE" "404"
  check "  and reaches no upstream" bash -c "! grep -qi '^x-upstream' '$TMP/h'"
  req a.test "$BASE/_gateway/health"
  check "the healthcheck answers on any host" is "$CODE" "200"

  req a.test "$BASE/fail503"
  check "an app answering 503 gets the maintenance page" is "$CODE/$(grep -ci '^x-gateway: maintenance' "$TMP/h")" "503/1"
  check "  in HTML, not the app's body, saying the service is unreachable" body_has 'Servizio non raggiungibile'
  check "  and the app's cookie does not pass" bash -c "! grep -qi '^set-cookie' '$TMP/h'"
  req a.test "$BASE/fail503" -H 'Accept: application/json'
  check "  in JSON when the client asks for JSON" is "$CODE/$(jq -r .message "$TMP/b")" \
    "503/Servizio momentaneamente non disponibile, stiamo lavorando per ripristinarlo."

  # A stream: the first piece must arrive long before the last one is sent (1.5 s apart).
  for path in /sse /stream; do
    curl -sN -H 'Host: a.test' "$BASE$path" | while IFS= read -r line; do
      [ -n "$line" ] && echo "$(date +%s.%N) $line"
    done >"$TMP/stream"
    first=$(head -n1 "$TMP/stream" | cut -d' ' -f1); last=$(tail -n1 "$TMP/stream" | cut -d' ' -f1)
    DETAIL="pieces: $(tr '\n' ' ' <"$TMP/stream")"
    check "$path arrives piece by piece" python3 -c "import sys; sys.exit(0 if $(wc -l <"$TMP/stream") == 3 and $last - $first > 2.5 else 1)"
  done

  ws=$(curl -s --http1.1 --max-time 5 -i -H 'Host: a.test' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$BASE/ws")
  DETAIL="$(printf '%s' "$ws" | head -n1)"
  check "a websocket upgrades and carries data" bash -c "printf '%s' \"\$1\" | grep -q '101 Switching Protocols' && printf '%s' \"\$1\" | grep -q ws-data" _ "$ws"

  head -c 100000000 /dev/zero | curl -s -o "$TMP/b" -H 'Host: b.test' -H 'Content-Type: application/octet-stream' \
    --data-binary @- "$BASE/upload"
  check "an upload of 100 MB arrives whole" is "$(jq -r .received "$TMP/b")" "100000000"

  out=$(docker logs "$GW" 2>/dev/null); err=$(docker logs "$GW" 2>&1 >/dev/null)
  DETAIL="stderr: $(printf '%s' "$err" | head -n2)"
  check "logs go to stdout, one line per request" bash -c "[ -z \"\$2\" ] && printf '%s' \"\$1\" | grep -q 'handled request'" _ "$out" "$err"
fi

echo "${BOLD}routes separated by new lines and spaces, a host written in capitals, and a * route${OFF}"
if start_gateway -e ROUTES="$(printf 'A.Test=http://up-a:8080\n  *=http://up-b:8080 ')"; then
  req a.test "$BASE/x"
  check "a.test reaches upstream a" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
  req c.test "$BASE/x"
  check "a host nobody named goes to the * route" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/b"
fi

echo "${BOLD}maintenance on, the default page, a path still forwarded${OFF}"
if start_gateway -e ROUTES="$ROUTES_AB" -e MAINTENANCE=on -e MAINTENANCE_PASSTHROUGH='/hooks/*, /api/v1/payments/notify'; then
  for path in / /a/b/c.html '/x?y=1'; do
    req a.test "$BASE$path"
    check "GET $path: 503 with the page" is "$CODE/$(grep -ci '^content-type: text/html' "$TMP/h")" "503/1"
  done
  check "  with Retry-After, X-Gateway and no-store" bash -c "grep -qi '^retry-after: 120' '$TMP/h' && grep -qi '^x-gateway: maintenance' '$TMP/h' && grep -qi '^cache-control: no-store' '$TMP/h'"
  check "  saying maintenance is in progress" body_has 'Manutenzione in corso'
  req a.test "$BASE/form" -X POST -d 'x=1'
  check "POST /form: 503 with the page" is "$CODE/$(grep -ci '^content-type: text/html' "$TMP/h")" "503/1"
  req b.test "$BASE/api/v1/users" -X POST -d '{}'
  check "POST /api/v1/users: 503 in JSON" is "$CODE/$(jq -r .message "$TMP/b")" "503/Servizio in manutenzione, torna disponibile a breve."
  check "  with no until when MAINTENANCE_UNTIL is not set" is "$(jq -c 'keys' "$TMP/b")" '["message"]'
  req b.test "$BASE/page" -H 'Accept: application/json, text/plain, */*'
  check "an Accept naming JSON: 503 in JSON" is "$CODE/$(grep -ci '^content-type: application/json' "$TMP/h")" "503/1"
  req a.test "$BASE/hooks/stripe" -X POST -d 'event=1'
  check "POST /hooks/stripe still reaches upstream a" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
  req b.test "$BASE/api/v1/payments/notify" -X POST -d 'x'
  check "POST /api/v1/payments/notify still reaches upstream b" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/b"
  req b.test "$BASE/api/v1/payments/notify/more"
  check "  but not a path the list does not name" is "$CODE" "503"
  req c.test "$BASE/"
  check "an unknown host still gets 404" is "$CODE" "404"
  req a.test "$BASE/_gateway/health"
  check "the healthcheck still answers 200" is "$CODE" "200"
fi

echo "${BOLD}maintenance on, a whole page of the app's own (it wins over the page's variables)${OFF}"
printf '%s' "<!doctype html><html lang=\"it\"><meta charset=\"utf-8\"><title>«Manutenzione»</title>
<p>L'app torna alle 18: \"ciao\" 'ciao' \$HOME \`date\` %s %d \\n {env.PORT} \${PORT} @@TITLE@@ àèéìòù €</p></html>" >"$TMP/page.html"
if start_gateway -e ROUTES="$ROUTES_AB" -e MAINTENANCE=on -e MAINTENANCE_HTML="$(cat "$TMP/page.html")" \
  -e MAINTENANCE_TITLE='Not this one' -e MAINTENANCE_COLOR='#123456' \
  -e MAINTENANCE_JSON='{"message":"Torniamo alle 18, è un\"attesa breve."}'; then
  req a.test "$BASE/"
  check "the HTML is served byte for byte ($(wc -c <"$TMP/page.html") bytes)" cmp -s "$TMP/b" "$TMP/page.html"
  req a.test "$BASE/api/x"
  check "the JSON is served as written" is "$(cat "$TMP/b")" '{"message":"Torniamo alle 18, è un\"attesa breve."}'
fi

echo "${BOLD}the page with no variables${OFF}"
if page bare; then
  check "Italian, default texts, only «Riprova», no logo, no expected time, contrast AA" page_is '{
    "lang": "it", "title": "Torniamo tra poco", "h1": "Torniamo tra poco", "status": "Manutenzione in corso",
    "texts": ["Stiamo facendo un intervento di manutenzione.", "Riprova", "Errore 503"],
    "absent": ["Ritorno previsto", "Ti serve aiuto?"],
    "hrefs": [""], "img": null, "until": null, "contrast": true}'
  check "  the default accent" body_has '--accent: #2b5a87;'
  check "  the JSON has the default message" is "$(jq -r .message "$TMP/j")" "Servizio in manutenzione, torna disponibile a breve."
fi

echo "${BOLD}the page with every variable${OFF}"
YEAR=$(date +%Y)
LAST_DAY_NAME=$(python3 -c "import datetime; print(['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'][datetime.date($YEAR, 12, 31).weekday()])")
if page full -e MAINTENANCE_TITLE='Aggiornamento del portale' \
  -e MAINTENANCE_MESSAGE="$(printf 'Stiamo installando la nuova versione.\nI dati sono al sicuro.\n\n  Grazie per la pazienza.  ')" \
  -e MAINTENANCE_UNTIL="$YEAR-12-31T18:05" -e MAINTENANCE_BRAND='Regione Esempio' \
  -e MAINTENANCE_LOGO_URL='https://cdn.example.it/logo.svg' -e MAINTENANCE_COLOR='#0B6E4F' \
  -e MAINTENANCE_CONTACT_EMAIL='assistenza@example.it' -e MAINTENANCE_CONTACT_PHONE='+39 06 1234.5678' \
  -e MAINTENANCE_CONTACT_URL='https://stato.example.it/?da=manutenzione&lingua=it' \
  -e MAINTENANCE_CONTACT_URL_LABEL='Stato del servizio' -e MAINTENANCE_LANG=it; then
  check "every value in its place, contrast AA" page_is '{
    "lang": "it", "title": "Aggiornamento del portale · Regione Esempio", "h1": "Aggiornamento del portale",
    "status": "Manutenzione in corso",
    "texts": ["Regione Esempio", "Stiamo installando la nuova versione. I dati sono al sicuro.", "Grazie per la pazienza.",
      "Ritorno previsto", "'"$LAST_DAY_NAME"' 31 dicembre, alle 18:05", "Ti serve aiuto?", "Scrivi a assistenza@example.it",
      "Chiama il +39 06 1234.5678", "Stato del servizio"],
    "absent": ["Altre informazioni", "'"$YEAR"'"],
    "hrefs": ["", "mailto:assistenza@example.it", "tel:+390612345678", "https://stato.example.it/?da=manutenzione&lingua=it"],
    "img": "https://cdn.example.it/logo.svg", "until": "'"$YEAR"'-12-31T18:05", "contrast": true}'
  check "  the message keeps its paragraphs and line breaks" body_has '<p>Stiamo installando la nuova versione.<br>I dati sono al sicuro.</p>'
  check "  the colour, lower case" body_has '--accent: #0b6e4f;'
  check "  the logo's alt is empty, the name beside it says whose it is" body_has 'alt=""'
  check "  the JSON carries the message and the expected time" is "$(jq -c . "$TMP/j")" \
    "$(jq -nc --arg m "$(printf 'Stiamo installando la nuova versione.\nI dati sono al sicuro.\n\n  Grazie per la pazienza.  ')" --arg u "$YEAR-12-31T18:05" '{message: $m, until: $u}')"
fi

echo "${BOLD}the page with values full of HTML and quotes${OFF}"
EVIL_TITLE=$'<b>"Ciao"</b> & \'tutti\' @@BRAND@@ </title><script>alert(1)</script>'
EVIL_BRAND='<img src=x onerror=alert(1)> & "Co"'
EVIL_MESSAGE=$'</p></div><script>alert("x")</script>\n<a href="javascript:alert(1)">clic</a> ${PORT} `date` %s'
EVIL_LABEL='"><svg onload=alert(1)>'
# An address with angle brackets is refused (below), so the links here hold an ampersand only.
if page evil -e MAINTENANCE_TITLE="$EVIL_TITLE" -e MAINTENANCE_BRAND="$EVIL_BRAND" -e MAINTENANCE_MESSAGE="$EVIL_MESSAGE" \
  -e MAINTENANCE_CONTACT_URL='https://example.it/a?b=1&c=2' -e MAINTENANCE_CONTACT_URL_LABEL="$EVIL_LABEL" \
  -e MAINTENANCE_LOGO_URL='https://example.it/l.png?x=1&y=2'; then
  check "every value arrives as text, no tag or handler gets in" page_is "$(jq -nc \
    --arg t "$EVIL_TITLE" --arg b "$EVIL_BRAND" --arg l "$EVIL_LABEL" '{
      h1: $t, title: ($t + " · " + $b),
      texts: [$b, "</p></div><script>alert(\"x\")</script>", "<a href=\"javascript:alert(1)\">clic</a> ${PORT} `date` %s", $l],
      hrefs: ["", "https://example.it/a?b=1&c=2"], img: "https://example.it/l.png?x=1&y=2"}')"
  check "  the raw page holds no quote, angle bracket or apostrophe from a value" bash -c \
    "! grep -qF -e '\"Ciao\"' -e \"'tutti'\" -e '<b>' -e '<svg onload' -e '<img src=x' -e '\"Co\"' '$TMP/b'"
  check "  an ampersand in an address is written &amp;" body_has 'href="https://example.it/a?b=1&amp;c=2"'
  check "  the JSON is valid and carries the message as written" is "$(jq -r .message "$TMP/j")" "$EVIL_MESSAGE"
fi

echo "${BOLD}the page in English, the expected time a time alone${OFF}"
if page english -e MAINTENANCE_LANG=en -e MAINTENANCE_UNTIL='9:30' -e MAINTENANCE_CONTACT_URL='https://help.example.com'; then
  check "English texts, «at 09:30», the link's default label" page_is '{
    "lang": "en", "h1": "We'"'"'ll be back shortly", "status": "Maintenance in progress",
    "texts": ["We are carrying out maintenance.", "Try again", "Expected back", "at 09:30", "Need help?", "More information",
      "Error 503"],
    "absent": ["Riprova", "alle"], "hrefs": ["", "https://help.example.com"], "until": "09:30", "contrast": true}'
  check "  the JSON in English, with until" is "$(jq -c . "$TMP/j")" '{"message":"Service under maintenance, back shortly.","until":"09:30"}'
fi
if page english-date -e MAINTENANCE_LANG=en -e MAINTENANCE_UNTIL='2031-01-07 08:00'; then
  check "a date in another year names the year, in English" page_is '{"texts": ["Tuesday 7 January 2031, at 08:00"], "until": "2031-01-07T08:00"}'
fi
if page leap -e MAINTENANCE_UNTIL='2028-02-29 23:59'; then
  check "29 February of a leap year, in Italian" page_is '{"texts": ["martedì 29 febbraio 2028, alle 23:59"], "until": "2028-02-29T23:59"}'
fi
if page blank -e MAINTENANCE_MESSAGE=$'  \n\n ' -e MAINTENANCE_TITLE=' ' -e MAINTENANCE_UNTIL=''; then
  check "blank values count as unset" page_is '{"h1": "Torniamo tra poco", "texts": ["Stiamo facendo un intervento"], "until": null}'
  check "  in the JSON too" is "$(jq -r .message "$TMP/j")" "Servizio in manutenzione, torna disponibile a breve."
fi

echo "${BOLD}accents that are hard to read on${OFF}"
for colour in '#ffff00' '#777777' '#000000' '#ffffff' '#0000ff' '#e11d48' '#fc0'; do
  if page "colour-${colour#\#}" -e MAINTENANCE_COLOR="$colour" -e MAINTENANCE_CONTACT_EMAIL=a@example.it; then
    check "$colour: every text and control pair measured AA, light and dark" page_is '{"contrast": true}'
  fi
done

echo "${BOLD}maintenance off, upstream b stopped${OFF}"
if start_gateway -e ROUTES="$ROUTES_AB" -e MAINTENANCE_UNTIL='18:00'; then
  docker stop -t 1 "$RUN-b" >/dev/null
  req b.test "$BASE/anything"
  check "b.test: 503 with the page, no bare 502" is "$CODE/$(grep -ci '^x-gateway: maintenance' "$TMP/h")" "503/1"
  check "  saying the service is unreachable, not under maintenance" page_is '{"status": "Servizio non raggiungibile",
    "texts": ["In questo momento il servizio non risponde."], "absent": ["Manutenzione in corso"], "until": "18:00"}'
  req b.test "$BASE/api/x"
  check "b.test/api/x: 503 in JSON" is "$CODE/$(grep -ci '^content-type: application/json' "$TMP/h")" "503/1"
  req a.test "$BASE/x"
  check "a.test is untouched" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
  docker start "$RUN-b" >/dev/null
fi

echo "${BOLD}an upstream that never answers${OFF}"
if start_gateway -e ROUTES='a.test=http://10.255.255.1:8080'; then
  t0=$(date +%s.%N); req a.test "$BASE/x"; t1=$(date +%s.%N)
  DETAIL="after $(python3 -c "print(round($t1 - $t0, 1))") s"
  check "503 with the page after the 5 s dial timeout ($DETAIL)" is "$CODE/$(python3 -c "print(int($t1 - $t0 < 8))")" "503/1"
fi

echo "${BOLD}the switch file, no restart${OFF}"
started() { docker inspect -f '{{.State.StartedAt}}' "$GW"; }
if start_gateway -e ROUTES="$ROUTES_AB" -e MAINTENANCE_PASSTHROUGH='/hooks/*'; then
  t0=$(started)
  req a.test "$BASE/x"
  check "no file: a.test reaches upstream a" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
  docker exec "$GW" touch /data/maintenance.on
  req a.test "$BASE/x"
  check "/data/maintenance.on created: the next request gets the page" is "$CODE/$(grep -ci '^x-gateway: maintenance' "$TMP/h")" "503/1"
  check "  the maintenance page, not the unreachable one" page_is '{"status": "Manutenzione in corso"}'
  req b.test "$BASE/api/x"
  check "  JSON with the maintenance message" is "$CODE/$(jq -r .message "$TMP/b")" "503/Servizio in manutenzione, torna disponibile a breve."
  req a.test "$BASE/hooks/stripe" -X POST -d 'x'
  check "  a passthrough path still reaches upstream a" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
  docker exec "$GW" rm /data/maintenance.on
  req a.test "$BASE/x"
  check "file removed: a.test reaches upstream a again" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
  check "  and the gateway never restarted" is "$(started)" "$t0"

  node bin/maintenance.mjs on --docker "$GW" >"$TMP/cmd" 2>&1
  req a.test "$BASE/x"
  DETAIL=$(cat "$TMP/cmd")
  check "the switch: on --docker creates the file in the container, the page follows" is "$CODE" "503"
  node bin/maintenance.mjs status --docker "$GW" >"$TMP/cmd" 2>&1
  DETAIL=$(cat "$TMP/cmd")
  check "  status --docker says it is on" grep -qF 'maintenance on' "$TMP/cmd"
  node bin/maintenance.mjs off --docker "$GW" >"$TMP/cmd" 2>&1
  req a.test "$BASE/x"
  DETAIL=$(cat "$TMP/cmd")
  check "  off --docker removes it, the app is back" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
  check "  still with no restart" is "$(started)" "$t0"
fi
if start_gateway -e ROUTES="$ROUTES_AB" -e MAINTENANCE=on; then
  docker exec "$GW" sh -c 'touch /data/maintenance.on && rm /data/maintenance.on'
  req a.test "$BASE/x"
  check "MAINTENANCE=on wins: no file, still the page" is "$CODE" "503"
fi
if start_gateway -e ROUTES="$ROUTES_AB" -e MAINTENANCE_FILE=/srv/flags/closed; then
  docker exec "$GW" touch /data/maintenance.on
  req a.test "$BASE/x"
  check "MAINTENANCE_FILE elsewhere: the default file means nothing" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
  docker exec "$GW" sh -c 'mkdir -p /srv/flags && touch /srv/flags/closed'
  req a.test "$BASE/x"
  check "  its own file turns maintenance on" is "$CODE" "503"
fi
if start_gateway -e ROUTES="$ROUTES_AB" -e MAINTENANCE_FILE=; then
  docker exec "$GW" touch /data/maintenance.on
  req a.test "$BASE/x"
  check "MAINTENANCE_FILE empty: no file switch at all" is "$CODE/$(jq -r .upstream "$TMP/b")" "200/a"
fi

echo "${BOLD}whose X-Forwarded-* the gateway believes${OFF}"
FORGED=(-H 'X-Forwarded-For: 203.0.113.7' -H 'X-Forwarded-Proto: https')
if start_gateway -e ROUTES="$ROUTES_AB" -e TRUSTED_PROXIES=none; then
  req a.test "$BASE/x" "${FORGED[@]}"
  check "none: a forged X-Forwarded-For is replaced with the real client" \
    bash -c "x=\$(jq -r .xff '$TMP/b'); [[ \$x =~ ^[0-9a-f.:]+$ ]] && [ \"\$x\" != 203.0.113.7 ]"
  check "  a forged X-Forwarded-Proto is replaced with the real scheme" is "$(jq -r .xfp "$TMP/b")" "http"
fi
if start_gateway -e ROUTES="$ROUTES_AB" -e TRUSTED_PROXIES='10.99.0.0/16, 2001:db8::/32'; then
  req a.test "$BASE/x" "${FORGED[@]}"
  check "a list without the caller: its X-Forwarded-For is replaced" bash -c "! jq -r .xff '$TMP/b' | grep -q 203.0.113.7"
  check "  and so is its X-Forwarded-Proto" is "$(jq -r .xfp "$TMP/b")" "http"
fi
if start_gateway -e ROUTES="$ROUTES_AB" -e TRUSTED_PROXIES='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'; then
  req a.test "$BASE/x" "${FORGED[@]}"
  check "a list with the caller: its X-Forwarded-For is kept, the caller appended" bash -c "jq -r .xff '$TMP/b' | grep -Eq '^203\.0\.113\.7, [0-9a-f.:]+$'"
fi

echo "${BOLD}TLS from Caddy's local authority (TLS=internal)${OFF}"
docker rm -f "$GW" >/dev/null 2>&1
if docker run -d --name "$GW" --network "$NET" -p 127.0.0.1::443 -p 127.0.0.1::80 -p 127.0.0.1::8080 "${MOUNTS[@]}" \
  -e ROUTES="$ROUTES_AB" -e TLS=internal "$IMAGE" >/dev/null; then
  port() { docker port "$GW" "$1/tcp" | head -n1 | sed 's/.*://'; }
  P443=$(port 443); P80=$(port 80); P8080=$(port 8080)
  for _ in $(seq 1 50); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P8080/_gateway/health")" = 200 ] &&
      docker exec "$GW" test -s /data/caddy/pki/authorities/local/root.crt && break
    sleep 0.2
  done
  docker exec "$GW" cat /data/caddy/pki/authorities/local/root.crt >"$TMP/root.crt" 2>/dev/null
  tls() { # tls <host> [curl args...]: an https request checked against the local authority
    local host=$1; shift
    CODE=$(curl -s -o "$TMP/b" -D "$TMP/h" -w '%{http_code}' --max-time 10 --cacert "$TMP/root.crt" \
      --resolve "$host:$P443:127.0.0.1" "$@" "https://$host:$P443/x")
  }
  tls a.test "${FORGED[@]}" -H 'X-Forwarded-For: 203.0.113.7' -H 'X-Forwarded-Proto: http'
  check "https with a certificate for a.test, reaching upstream a" is "$CODE/$(jq -r .upstream "$TMP/b" 2>/dev/null)" "200/a"
  check "  X-Forwarded-Proto is https, whatever the client sent" is "$(jq -r .xfp "$TMP/b" 2>/dev/null)" "https"
  check "  a forged X-Forwarded-For is replaced (none is the default with TLS)" bash -c "! jq -r .xff '$TMP/b' | grep -q 203.0.113.7"
  tls b.test
  check "https for b.test too" is "$CODE/$(jq -r .upstream "$TMP/b" 2>/dev/null)" "200/b"
  tls c.test
  check "a host not in ROUTES gets no certificate and no answer" bash -c "[ '$CODE' != 200 ]"
  CODE=$(curl -s -o /dev/null -D "$TMP/h" -w '%{http_code}' -H 'Host: a.test' "http://127.0.0.1:$P80/x?y=1")
  check "http is redirected to https" is "$CODE/$(grep -i '^location:' "$TMP/h" | tr -d '\r' | cut -d' ' -f2)" "308/https://a.test/x?y=1"
  docker exec "$GW" touch /data/maintenance.on
  tls a.test
  check "the switch file works over https too" is "$CODE/$(grep -ci '^x-gateway: maintenance' "$TMP/h")" "503/1"
  check "  the healthcheck answers on the plain port" is "$(curl -s "http://127.0.0.1:$P8080/_gateway/health")" "ok"
fi

echo "${BOLD}TLS from Let's Encrypt (TLS=auto): the configuration only${OFF}"
if start_gateway -e ROUTES="$ROUTES_AB" -e TLS=auto -e TLS_EMAIL=ops@example.it; then
  docker exec "$GW" cat /etc/caddy/Caddyfile >"$TMP/caddyfile"
  check "starts, with the email for Let's Encrypt and no local authority" \
    bash -c "grep -qx '[[:space:]]*email ops@example.it' '$TMP/caddyfile' && ! grep -q 'tls internal' '$TMP/caddyfile' && grep -q '^a.test, b.test {' '$TMP/caddyfile'"
fi
if start_gateway -e ROUTES="$ROUTES_AB"; then
  docker exec "$GW" cat /etc/caddy/Caddyfile >"$TMP/caddyfile"
  check "the Railway defaults: no TLS, every proxy trusted, the edge's X-Forwarded-For as it is" \
    bash -c "grep -q 'auto_https off' '$TMP/caddyfile' && grep -q 'trusted_proxies static 0.0.0.0/0 ::/0' '$TMP/caddyfile' && grep -q 'header_up X-Forwarded-For {http.request.header.X-Forwarded-For}' '$TMP/caddyfile' && grep -q '^:8080 {' '$TMP/caddyfile'"
fi

echo "${BOLD}what the gateway refuses${OFF}"
OK=(-e ROUTES="$ROUTES_AB")
expect_refusal "no ROUTES" "ROUTES is empty"
expect_refusal "MAINTENANCE=yes" "takes on or off" "${OK[@]}" -e MAINTENANCE=yes
expect_refusal "an https upstream" "an upstream is http" -e ROUTES='a.test=https://up-a:8080'
expect_refusal "an upstream without a port" "an upstream is http" -e ROUTES='a.test=http://up-a'
expect_refusal "a pair without =" "not host=upstream" -e ROUTES='a.test'
expect_refusal "a pair with no host, as an unset reference leaves it" "with no host" -e ROUTES='=http://up-a:8080,b.test=http://up-b:8080'
expect_refusal "a host with a brace" "names the host" -e ROUTES='a{.test=http://up-a:8080'
expect_refusal "the same host twice, in other capitals" "twice" -e ROUTES='a.test=http://up-a:8080,A.test=http://up-b:8080'
expect_refusal "a passthrough path with a brace" "MAINTENANCE_PASSTHROUGH has" "${OK[@]}" -e MAINTENANCE_PASSTHROUGH='/hooks/{x}'
expect_refusal "a passthrough path without /" "MAINTENANCE_PASSTHROUGH has" "${OK[@]}" -e MAINTENANCE_PASSTHROUGH='hooks'
expect_refusal "PORT that is not a number" "not a port number" "${OK[@]}" -e PORT=80a
expect_refusal "a logo over http" "MAINTENANCE_LOGO_URL is" "${OK[@]}" -e MAINTENANCE_LOGO_URL='http://example.it/logo.png'
expect_refusal "a logo address with a quote" "MAINTENANCE_LOGO_URL is" "${OK[@]}" -e MAINTENANCE_LOGO_URL='https://example.it/l.png"onerror="alert(1)'
expect_refusal "a logo that is javascript:" "MAINTENANCE_LOGO_URL is" "${OK[@]}" -e MAINTENANCE_LOGO_URL='javascript:alert(1)'
expect_refusal "a logo address with a second line" "MAINTENANCE_LOGO_URL is" "${OK[@]}" -e MAINTENANCE_LOGO_URL=$'https://example.it/l.png\n<script>'
expect_refusal "a contact link over ftp" "MAINTENANCE_CONTACT_URL is" "${OK[@]}" -e MAINTENANCE_CONTACT_URL='ftp://example.it'
expect_refusal "a contact link with angle brackets" "MAINTENANCE_CONTACT_URL is" "${OK[@]}" -e MAINTENANCE_CONTACT_URL='https://example.it/a?c=<2>'
expect_refusal "a label with no link" "MAINTENANCE_CONTACT_URL_LABEL is set" "${OK[@]}" -e MAINTENANCE_CONTACT_URL_LABEL='Aiuto'
expect_refusal "a colour by name" "MAINTENANCE_COLOR is" "${OK[@]}" -e MAINTENANCE_COLOR='red'
expect_refusal "a colour of five digits" "MAINTENANCE_COLOR is" "${OK[@]}" -e MAINTENANCE_COLOR='#12345'
expect_refusal "a colour that closes the CSS" "MAINTENANCE_COLOR is" "${OK[@]}" -e MAINTENANCE_COLOR='#fff;}body{display:none'
expect_refusal "a colour with a second line" "MAINTENANCE_COLOR is" "${OK[@]}" -e MAINTENANCE_COLOR=$'#ffffff\n#000000'
expect_refusal "an email without a domain" "MAINTENANCE_CONTACT_EMAIL is" "${OK[@]}" -e MAINTENANCE_CONTACT_EMAIL='assistenza@example'
expect_refusal "two emails" "MAINTENANCE_CONTACT_EMAIL is" "${OK[@]}" -e MAINTENANCE_CONTACT_EMAIL='a@example.it, b@example.it'
expect_refusal "a phone with letters" "MAINTENANCE_CONTACT_PHONE is" "${OK[@]}" -e MAINTENANCE_CONTACT_PHONE='06 CHIAMA'
expect_refusal "an expected time of 25:00" "no such day or time" "${OK[@]}" -e MAINTENANCE_UNTIL='25:00'
expect_refusal "an expected day of 30 February" "no such day or time" "${OK[@]}" -e MAINTENANCE_UNTIL='2026-02-30 10:00'
expect_refusal "29 February of a year that is not leap" "no such day or time" "${OK[@]}" -e MAINTENANCE_UNTIL='2027-02-29 10:00'
expect_refusal "an expected time in words" "MAINTENANCE_UNTIL is" "${OK[@]}" -e MAINTENANCE_UNTIL='domani alle 18'
expect_refusal "a language the page does not speak" "MAINTENANCE_LANG is" "${OK[@]}" -e MAINTENANCE_LANG=fr
expect_refusal "a title of 151 characters" "MAINTENANCE_TITLE is 151" "${OK[@]}" -e MAINTENANCE_TITLE="$(printf 'x%.0s' $(seq 151))"
expect_refusal "TLS=yes" "TLS is [yes]" "${OK[@]}" -e TLS=yes
expect_refusal "TLS with a * route" "a * route with TLS=auto" -e ROUTES='*=http://up-a:8080' -e TLS=auto
expect_refusal "TLS with PORT 443" "PORT is 443 with TLS on" "${OK[@]}" -e TLS=internal -e PORT=443
expect_refusal "a TLS_EMAIL that is not an address" "TLS_EMAIL is" "${OK[@]}" -e TLS=auto -e TLS_EMAIL=ops
expect_refusal "TRUSTED_PROXIES=everyone" "TRUSTED_PROXIES has [everyone]" "${OK[@]}" -e TRUSTED_PROXIES=everyone
expect_refusal "a trusted range with a brace" "TRUSTED_PROXIES has" "${OK[@]}" -e TRUSTED_PROXIES='10.0.0.0/8}'
expect_refusal "a relative MAINTENANCE_FILE" "MAINTENANCE_FILE is" "${OK[@]}" -e MAINTENANCE_FILE=maintenance.on
expect_refusal "a MAINTENANCE_FILE with a space" "MAINTENANCE_FILE is" "${OK[@]}" -e MAINTENANCE_FILE='/data/x y'
expect_refusal "a wrong page value, even with MAINTENANCE_HTML set" "MAINTENANCE_COLOR is" "${OK[@]}" \
  -e MAINTENANCE_HTML='<p>ok</p>' -e MAINTENANCE_COLOR='blue'

if [ "${CHECK_BROWSER:-1}" != 0 ]; then
  echo "${BOLD}the page in a browser${OFF} (Chromium $PLAYWRIGHT, in docker)"
  SHOT_MOUNT=()
  if [ -n "${SHOTS:-}" ]; then mkdir -p "$SHOTS"; SHOT_MOUNT=(-v "$(realpath "$SHOTS"):/shots" -e SHOTS=/shots); fi
  # playwright-core is installed in the container, at the version of the image, on every run: the
  # browser part needs no package.json and leaves nothing behind.
  docker run --rm --init --ipc=host --user "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_cache=/tmp/npm \
    -v "$PWD/tests/browser.mjs:/work/browser.mjs:ro" -v "$TMP/pages:/pages:ro" "${SHOT_MOUNT[@]}" \
    "$PLAYWRIGHT_IMAGE" sh -c "cd /tmp && npm install --silent --no-audit --no-fund playwright-core@$PLAYWRIGHT >/dev/null 2>&1 &&
      cp /work/browser.mjs /tmp/browser.mjs && node /tmp/browser.mjs" >"$TMP/browser" 2>&1
  status=$?
  while IFS= read -r line; do
    case "$line" in
      'ok '*) ok "${line#ok }" ;;
      'FAIL '*) ko "${line#FAIL }" ;;
      *) echo "     $line" ;;
    esac
  done <"$TMP/browser"
  [ "$status" -eq 0 ] || grep -q '^FAIL ' "$TMP/browser" || ko "the browser part ran" "exit $status"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "${GREEN}${BOLD}gateway check passed${OFF} ($PASSED checks)"
else
  echo "${RED}${BOLD}gateway check failed${OFF}: $FAILED of $((PASSED + FAILED)) checks"
  exit 1
fi
