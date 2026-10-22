#!/bin/sh
# The gateway: the service that owns the public domains of a Railway project and puts a maintenance
# page in front of them (README.md). It is the image's entrypoint: every setting comes from variables,
# so turning maintenance on, changing its text or a route is a variable and a redeploy of an image,
# with no build in between.
#
# What it reads, all from variables:
#   ROUTES                   host=upstream pairs, separated by commas, spaces or new lines.
#                            `app.example.it=http://frontend.railway.internal:8080`. Host `*` takes
#                            every host no other pair names. An unknown host gets a bare 404.
#   MAINTENANCE              `on` answers 503 with the page and forwards nothing; `off` or unset
#                            forwards. Anything else refuses to start.
#   MAINTENANCE_PASSTHROUGH  paths still forwarded during maintenance (a third party's webhook that
#                            does not retry), Caddy path patterns: `/webhooks/*,/api/v1/payments/notify`.
#   PORT                     where Caddy listens, 8080 by default: the targetPort of every domain.
#                            With TLS on, the plain port of the healthcheck alone.
#
#   Away from Railway (README.md, «Fuori da Railway»), every default being Railway's:
#   TLS                      off (default), auto (Let's Encrypt, ports 80 and 443, certificates in
#                            /data) or internal (Caddy's local authority). Refuses a `*` route.
#   TLS_EMAIL                the address Let's Encrypt writes to about the certificates.
#   TRUSTED_PROXIES          all (default with TLS off), none (default with TLS on) or a list of
#                            addresses and ranges: whose X-Forwarded-* the gateway believes.
#   MAINTENANCE_FILE         while this file exists maintenance is on, no restart needed;
#                            /data/maintenance.on by default, empty for no file switch.
#
#   The page, every variable optional (README.md, «La pagina»):
#   MAINTENANCE_TITLE, MAINTENANCE_MESSAGE, MAINTENANCE_UNTIL (`2026-10-22T18:00`, `2026-10-22 18:00`
#   or `18:00`), MAINTENANCE_BRAND, MAINTENANCE_LOGO_URL (https), MAINTENANCE_COLOR (`#1f5f8b`),
#   MAINTENANCE_CONTACT_EMAIL, MAINTENANCE_CONTACT_PHONE, MAINTENANCE_CONTACT_URL (https),
#   MAINTENANCE_CONTACT_URL_LABEL, MAINTENANCE_LANG (`it`, the default, or `en`).
#   MAINTENANCE_HTML         a whole page of your own, served byte for byte: it wins over all of the above.
#   MAINTENANCE_JSON         the body for a client that wants JSON (a path under /api/, or an Accept
#                            naming application/json). `{"message":"..."}` when unset, with
#                            MAINTENANCE_MESSAGE if set and `until` when MAINTENANCE_UNTIL is.
#
# A refusal stops the container before Caddy starts, with the reason on stderr: on Railway the
# healthcheck then fails and the deployment already running keeps the traffic.
#
# MAINTENANCE=on wins over the file: the file can turn maintenance on, never off.
#
# Without maintenance the same page comes up by itself when an upstream is off, does not answer
# within 5 seconds, or answers 502, 503 or 504. Every page sent this way carries `X-Gateway:
# maintenance`: that is how the switch, and the page's own check, tell it from the app.
set -eu

TEMPLATE=/usr/share/gateway/page.html
PAGES=/srv/gateway

fail() {
  echo "gateway: $*" >&2
  exit 1
}

# single_line <value>: true when the value has no new line. A shape check with grep alone would pass a
# value whose FIRST line is fine and whose second is anything at all.
single_line() { [ "$(printf '%s' "$1" | wc -l)" -eq 0 ]; }
matches() { single_line "$1" && printf '%s' "$1" | grep -Eq "$2"; }

# one_line <value>: carriage returns dropped, every run of white space one space, trimmed.
one_line() { printf '%s' "$1" | tr '\r\n\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }

# esc <value>: safe inside HTML text and inside a double- or single-quoted attribute.
esc() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

PORT=${PORT:-8080}
case "$PORT" in '' | *[!0-9]*) fail "PORT is [$PORT], not a port number." ;; esac

case "${MAINTENANCE:-off}" in
  on) MODE=on ;;
  off | '') MODE=off ;;
  *) fail "MAINTENANCE is [$MAINTENANCE]: it takes on or off, nothing else." ;;
esac

# --- Running somewhere other than Railway (README.md, «Fuori da Railway»). Every default below is
# Railway's: no TLS (the edge does it), every proxy trusted (only the edge reaches the port).

# TLS: off, the default; auto, certificates from Let's Encrypt for every host in ROUTES (ports 80 and
# 443, http redirected to https, certificates kept in /data); internal, the same from Caddy's own local
# authority, for a trial or a private network.
TLS_=$(one_line "${TLS:-}")
case "$TLS_" in
  '' | off) TLS_=off ;;
  auto | internal) ;;
  *) fail "TLS is [$TLS_]: it takes off, auto or internal." ;;
esac
TLS_EMAIL_=$(one_line "${TLS_EMAIL:-}")
[ -z "$TLS_EMAIL_" ] || matches "$TLS_EMAIL_" '^[A-Za-z0-9._%+-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$' ||
  fail "TLS_EMAIL is [$TLS_EMAIL_]: one address, name@example.it."
if [ "$TLS_" != off ]; then
  case "$PORT" in 80 | 443) fail "PORT is $PORT with TLS on: 80 and 443 are the public ports, PORT is the plain healthcheck's (8080)." ;; esac
fi

# TRUSTED_PROXIES: whose X-Forwarded-* the gateway believes. all (Railway's default: only its edge
# reaches the port), none (the default with TLS on: the gateway writes them itself from the real
# client, and drops whatever a client sent), or a list of addresses and ranges, `10.0.0.0/8 192.0.2.7`.
TRUST=$(printf '%s' "${TRUSTED_PROXIES:-}" | tr ',\r\n\t' '    ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
if [ -z "$TRUST" ]; then
  [ "$TLS_" = off ] && TRUST=all || TRUST=none
fi
case "$TRUST" in
  all | none) ;;
  *)
    for t in $TRUST; do
      printf '%s' "$t" | grep -Eq '^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*)(/[0-9]{1,3})?$' ||
        fail "TRUSTED_PROXIES has [$t]: all, none, or addresses and ranges (10.0.0.0/8, 192.0.2.7, fd00::/8)."
    done
    ;;
esac

# MAINTENANCE_FILE: while this file exists, maintenance is on, with no restart (Caddy looks for it on
# every request: one stat, nothing else). /data/maintenance.on unless set; set empty, there is no file
# switch. MAINTENANCE=on wins over it: the file can turn maintenance on, never off.
SWITCH=${MAINTENANCE_FILE-/data/maintenance.on}
SWITCH=$(one_line "$SWITCH")
if [ -n "$SWITCH" ]; then
  matches "$SWITCH" '^(/[A-Za-z0-9._-]+)+$' ||
    fail "MAINTENANCE_FILE is [$SWITCH]: an absolute path of a file, letters, digits, . _ - only, or empty for no file switch."
  SWITCH_DIR=${SWITCH%/*}
  SWITCH_DIR=${SWITCH_DIR:-/}
  SWITCH_NAME=${SWITCH##*/}
fi

# --- The page's variables, checked whether or not MAINTENANCE_HTML replaces the page: a wrong value is
# wrong either way, and it would surface the day somebody empties MAINTENANCE_HTML.

LANG_=$(one_line "${MAINTENANCE_LANG:-}")
case "$LANG_" in
  '' | it) LANG_=it ;;
  en) ;;
  *) fail "MAINTENANCE_LANG is [$LANG_]: it takes it or en." ;;
esac

TITLE=$(one_line "${MAINTENANCE_TITLE:-}")
BRAND=$(one_line "${MAINTENANCE_BRAND:-}")
MESSAGE=$(printf '%s' "${MAINTENANCE_MESSAGE:-}" | tr -d '\r')
[ -n "$(one_line "$MESSAGE")" ] || MESSAGE=''
[ "${#TITLE}" -le 150 ] || fail "MAINTENANCE_TITLE is ${#TITLE} characters long: 150 at most."
[ "${#BRAND}" -le 80 ] || fail "MAINTENANCE_BRAND is ${#BRAND} characters long: 80 at most."
[ "${#MESSAGE}" -le 2000 ] || fail "MAINTENANCE_MESSAGE is ${#MESSAGE} characters long: 2000 at most."

COLOR=$(one_line "${MAINTENANCE_COLOR:-}")
if [ -z "$COLOR" ]; then
  COLOR='#2b5a87'
elif matches "$COLOR" '^#[0-9A-Fa-f]{3}$'; then
  COLOR=$(printf '%s' "$COLOR" | sed 's/^#\(.\)\(.\)\(.\)$/#\1\1\2\2\3\3/')
elif ! matches "$COLOR" '^#[0-9A-Fa-f]{6}$'; then
  fail "MAINTENANCE_COLOR is [$COLOR]: a hexadecimal colour, #1f5f8b or #fff."
fi
COLOR=$(printf '%s' "$COLOR" | tr 'A-F' 'a-f')

# An address the page links to: https, a host, an optional port, then a path without quotes, angle
# brackets, back slashes or spaces. Escaped on top of that.
URL_SHAPE='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?([/?#][A-Za-z0-9._~:/?#@!$&()*+,;=%-]*)?$'

LOGO=$(printf '%s' "${MAINTENANCE_LOGO_URL:-}" | tr -d '\r')
[ -z "$LOGO" ] || matches "$LOGO" "$URL_SHAPE" ||
  fail "MAINTENANCE_LOGO_URL is [$LOGO]: an https:// address, with no quotes, spaces or angle brackets."

EMAIL=$(printf '%s' "${MAINTENANCE_CONTACT_EMAIL:-}" | tr -d '\r')
[ -z "$EMAIL" ] || matches "$EMAIL" '^[A-Za-z0-9._%+-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$' ||
  fail "MAINTENANCE_CONTACT_EMAIL is [$EMAIL]: one address, name@example.it."

PHONE=$(printf '%s' "${MAINTENANCE_CONTACT_PHONE:-}" | tr -d '\r')
[ -z "$PHONE" ] || matches "$PHONE" '^\+?[0-9][0-9 ./()-]{3,24}$' ||
  fail "MAINTENANCE_CONTACT_PHONE is [$PHONE]: digits, with an optional + in front and spaces, dots, dashes or brackets."

CONTACT_URL=$(printf '%s' "${MAINTENANCE_CONTACT_URL:-}" | tr -d '\r')
CONTACT_LABEL=$(one_line "${MAINTENANCE_CONTACT_URL_LABEL:-}")
[ -z "$CONTACT_URL" ] || matches "$CONTACT_URL" "$URL_SHAPE" ||
  fail "MAINTENANCE_CONTACT_URL is [$CONTACT_URL]: an https:// address, with no quotes, spaces or angle brackets."
[ -z "$CONTACT_LABEL" ] || [ -n "$CONTACT_URL" ] ||
  fail "MAINTENANCE_CONTACT_URL_LABEL is set but MAINTENANCE_CONTACT_URL is not: the label names a link."
[ "${#CONTACT_LABEL}" -le 60 ] || fail "MAINTENANCE_CONTACT_URL_LABEL is ${#CONTACT_LABEL} characters long: 60 at most."

# MAINTENANCE_UNTIL: when the service is expected back, written as the people reading the page tell the
# time (no time zone is converted). A date and a time, or a time alone for today.
UNTIL=$(one_line "${MAINTENANCE_UNTIL:-}")
UNTIL_TEXT=''
UNTIL_ISO=''
if [ -n "$UNTIL" ]; then
  if matches "$UNTIL" '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{1,2}:[0-9]{2}$'; then
    UNTIL_DATE=${UNTIL%%[T ]*}
    UNTIL_TIME=${UNTIL#*[T ]}
  elif matches "$UNTIL" '^[0-9]{1,2}:[0-9]{2}$'; then
    UNTIL_DATE=''
    UNTIL_TIME=$UNTIL
  else
    fail "MAINTENANCE_UNTIL is [$UNTIL]: 2026-10-22T18:00, 2026-10-22 18:00 or 18:00."
  fi
  # Range checks and the words, in awk: a day that does not exist (31 April) is refused too.
  UNTIL_LINE=$(awk -v d="$UNTIL_DATE" -v t="$UNTIL_TIME" -v lang="$LANG_" -v year_now="$(date +%Y)" '
    BEGIN {
      split(t, hm, ":"); h = hm[1] + 0; m = hm[2] + 0
      if (h > 23 || m > 59) { print "ERR"; exit }
      time = sprintf("%02d:%02d", h, m)
      if (d == "") {
        print time "|" (lang == "it" ? "alle " time : "at " time)
        exit
      }
      split(d, p, "-"); y = p[1] + 0; mo = p[2] + 0; dd = p[3] + 0
      split("31 28 31 30 31 30 31 31 30 31 30 31", days, " ")
      if ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) days[2] = 29
      if (mo < 1 || mo > 12 || dd < 1 || dd > days[mo]) { print "ERR"; exit }
      # Sakamoto: 0 is Sunday.
      split("0 3 2 5 0 3 5 1 4 6 2 4", off, " ")
      yy = (mo < 3) ? y - 1 : y
      wd = (yy + int(yy / 4) - int(yy / 100) + int(yy / 400) + off[mo] + dd) % 7
      if (lang == "it") {
        split("domenica lunedì martedì mercoledì giovedì venerdì sabato", wn, " ")
        split("gennaio febbraio marzo aprile maggio giugno luglio agosto settembre ottobre novembre dicembre", mn, " ")
        text = wn[wd + 1] " " dd " " mn[mo] (y != year_now ? " " y : "") ", alle " time
      } else {
        split("Sunday Monday Tuesday Wednesday Thursday Friday Saturday", wn, " ")
        split("January February March April May June July August September October November December", mn, " ")
        text = wn[wd + 1] " " dd " " mn[mo] (y != year_now ? " " y : "") ", at " time
      }
      print sprintf("%04d-%02d-%02dT%s", y, mo, dd, time) "|" text
    }')
  [ "$UNTIL_LINE" != ERR ] || fail "MAINTENANCE_UNTIL is [$UNTIL]: no such day or time."
  UNTIL_ISO=${UNTIL_LINE%%|*}
  UNTIL_TEXT=${UNTIL_LINE#*|}
fi

# --- The texts, in the page's language. Italian addresses the reader with «tu».
if [ "$LANG_" = it ]; then
  T_STATUS_ON='Manutenzione in corso'
  T_STATUS_OFF='Servizio non raggiungibile'
  T_TITLE='Torniamo tra poco'
  T_MESSAGE_ON='Stiamo facendo un intervento di manutenzione. Il servizio torna disponibile appena abbiamo finito: grazie per la pazienza.'
  T_MESSAGE_OFF='In questo momento il servizio non risponde. Stiamo lavorando per ripristinarlo il prima possibile.'
  T_JSON_ON='Servizio in manutenzione, torna disponibile a breve.'
  T_JSON_OFF='Servizio momentaneamente non disponibile, stiamo lavorando per ripristinarlo.'
  T_UNTIL='Ritorno previsto'
  T_RETRY='Riprova'
  T_AUTO='Questa pagina si aggiorna da sola appena il servizio torna disponibile.'
  T_LAST='Ultimo controllo alle {time}.'
  T_BACK='Il servizio è di nuovo disponibile: ricarico la pagina.'
  T_HELP='Ti serve aiuto?'
  T_EMAIL='Scrivi a'
  T_PHONE='Chiama il'
  T_LINK='Altre informazioni'
  T_CODE='Errore 503: servizio non disponibile'
  T_LOGO='Logo'
else
  T_STATUS_ON='Maintenance in progress'
  T_STATUS_OFF='Service unreachable'
  T_TITLE="We'll be back shortly"
  T_MESSAGE_ON="We are carrying out maintenance. The service will be available again as soon as we're done: thank you for your patience."
  T_MESSAGE_OFF='The service is not responding right now. We are working to restore it as soon as possible.'
  T_JSON_ON='Service under maintenance, back shortly.'
  T_JSON_OFF='Service temporarily unavailable, we are working to restore it.'
  T_UNTIL='Expected back'
  T_RETRY='Try again'
  T_AUTO='This page reloads by itself as soon as the service is available again.'
  T_LAST='Last checked at {time}.'
  T_BACK='The service is available again: reloading the page.'
  T_HELP='Need help?'
  T_EMAIL='Write to'
  T_PHONE='Call'
  T_LINK='More information'
  T_CODE='Error 503: service unavailable'
  T_LOGO='Logo'
fi
[ -n "$TITLE" ] || TITLE=$T_TITLE
[ -n "$CONTACT_LABEL" ] || CONTACT_LABEL=$T_LINK

# Two of everything, page and JSON: `on` for maintenance (MAINTENANCE=on, or the switch file), `off` for
# an app that is down while maintenance is off. They differ in the status line and the default texts.
mkdir -p "$PAGES"

# --- The JSON bodies.
for m in on off; do
  if [ -n "${MAINTENANCE_JSON:-}" ]; then
    printf '%s' "$MAINTENANCE_JSON" >"$PAGES/maintenance-$m.json"
    continue
  fi
  [ "$m" = on ] && default=$T_JSON_ON || default=$T_JSON_OFF
  # JSON string escaping: back slash and quote escaped, a new line written \n, every other control dropped.
  printf '%s' "${MESSAGE:-$default}" | awk -v until="$UNTIL_ISO" '
    { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, " "); gsub(/[[:cntrl:]]/, ""); s = (NR > 1 ? s "\\n" : "") $0 }
    END { printf "{\"message\":\"%s\"%s}", s, (until != "" ? ",\"until\":\"" until "\"" : "") }' >"$PAGES/maintenance-$m.json"
done

# --- The HTML page.
if [ -n "${MAINTENANCE_HTML:-}" ]; then
  printf '%s' "$MAINTENANCE_HTML" >"$PAGES/index-on.html"
  printf '%s' "$MAINTENANCE_HTML" >"$PAGES/index-off.html"
else
  # The accent: the text drawn on it (black or white, whichever contrasts more, which is never below
  # 4.58:1) and its edge on each theme's card (the accent itself when it stands out from the card by 3:1,
  # the ink otherwise). The two card colours are the page's --surface, light and dark.
  ACCENT_LINE=$(awk -v c="$COLOR" '
    function lin(x) { x = x / 255; return x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ^ 2.4 }
    function hex(s,   i, v) { v = 0; for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1; return v }
    function lum(h) { return 0.2126 * lin(hex(substr(h, 2, 2))) + 0.7152 * lin(hex(substr(h, 4, 2))) + 0.0722 * lin(hex(substr(h, 6, 2))) }
    function ratio(a, b) { return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05) }
    BEGIN {
      l = lum(c)
      on = ratio(l, 1) >= ratio(l, 0) ? "#ffffff" : "#000000"
      light = ratio(l, lum("#ffffff")) >= 3 ? c : "#17191d"
      dark = ratio(l, lum("#181b1f")) >= 3 ? c : "#ecebe7"
      print on " " light " " dark
    }')
  set -- $ACCENT_LINE

  GW_LANG=$LANG_
  GW_ACCENT=$COLOR
  GW_ON_ACCENT=$1
  GW_ACCENT_EDGE_LIGHT=$2
  GW_ACCENT_EDGE_DARK=$3
  GW_TITLE=$(esc "$TITLE")
  if [ -n "$BRAND" ]; then GW_DOC_TITLE="$GW_TITLE · $(esc "$BRAND")"; else GW_DOC_TITLE=$GW_TITLE; fi
  GW_RETRY=$(esc "$T_RETRY")
  GW_AUTO=$(esc "$T_AUTO")
  GW_LAST=$(esc "$T_LAST")
  GW_BACK=$(esc "$T_BACK")
  GW_CODE=$(esc "$T_CODE")

  GW_BRAND=''
  if [ -n "$LOGO" ] || [ -n "$BRAND" ]; then
    GW_BRAND='<div class="brand">'
    if [ -n "$LOGO" ]; then
      # The name beside it already says whose logo it is; without one, the image is the only name.
      [ -n "$BRAND" ] && alt='' || alt=$T_LOGO
      GW_BRAND="$GW_BRAND<img src=\"$(esc "$LOGO")\" alt=\"$(esc "$alt")\" height=\"36\" referrerpolicy=\"no-referrer\" onerror=\"this.remove()\">"
    fi
    [ -z "$BRAND" ] || GW_BRAND="$GW_BRAND<span class=\"brand-name\">$(esc "$BRAND")</span>"
    GW_BRAND="$GW_BRAND</div>"
  fi

  GW_UNTIL=''
  if [ -n "$UNTIL_ISO" ]; then
    GW_UNTIL="<p class=\"until\"><svg class=\"icon\" viewBox=\"0 0 24 24\" aria-hidden=\"true\" focusable=\"false\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 7v5l3 2\"/></svg><span><span class=\"until-label\">$(esc "$T_UNTIL")</span> <time datetime=\"$(esc "$UNTIL_ISO")\">$(esc "$UNTIL_TEXT")</time></span></p>"
  fi

  GW_CONTACTS=''
  if [ -n "$EMAIL" ] || [ -n "$PHONE" ] || [ -n "$CONTACT_URL" ]; then
    items=''
    if [ -n "$EMAIL" ]; then
      items="$items<li><a class=\"btn\" href=\"mailto:$(esc "$EMAIL")\"><svg class=\"icon\" viewBox=\"0 0 24 24\" aria-hidden=\"true\" focusable=\"false\"><rect x=\"3\" y=\"5\" width=\"18\" height=\"14\" rx=\"2\"/><path d=\"m4 7 8 6 8-6\"/></svg><span class=\"sr-only\">$(esc "$T_EMAIL") </span>$(esc "$EMAIL")</a></li>"
    fi
    if [ -n "$PHONE" ]; then
      tel=$(printf '%s' "$PHONE" | tr -cd '+0-9')
      items="$items<li><a class=\"btn\" href=\"tel:$tel\"><svg class=\"icon\" viewBox=\"0 0 24 24\" aria-hidden=\"true\" focusable=\"false\"><path d=\"M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2\"/></svg><span class=\"sr-only\">$(esc "$T_PHONE") </span>$(esc "$PHONE")</a></li>"
    fi
    if [ -n "$CONTACT_URL" ]; then
      items="$items<li><a class=\"btn\" href=\"$(esc "$CONTACT_URL")\" rel=\"noopener\"><svg class=\"icon\" viewBox=\"0 0 24 24\" aria-hidden=\"true\" focusable=\"false\"><path d=\"M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5\"/></svg>$(esc "$CONTACT_LABEL")</a></li>"
    fi
    GW_CONTACTS="<section class=\"contacts\" aria-labelledby=\"gw-help\"><h2 id=\"gw-help\">$(esc "$T_HELP")</h2><ul>$items</ul></section>"
  fi

  export GW_LANG GW_ACCENT GW_ON_ACCENT GW_ACCENT_EDGE_LIGHT GW_ACCENT_EDGE_DARK GW_TITLE GW_DOC_TITLE \
    GW_RETRY GW_AUTO GW_LAST GW_BACK GW_CODE GW_BRAND GW_UNTIL GW_CONTACTS

  # Each @@NAME@@ in the template becomes GW_NAME, in one pass: what a value contains is never read
  # again, so a value holding @@TITLE@@ stays text. A name the script does not export stops the start.
  for m in on off; do
    if [ "$m" = on ]; then GW_STATUS=$(esc "$T_STATUS_ON"); text=${MESSAGE:-$T_MESSAGE_ON}
    else GW_STATUS=$(esc "$T_STATUS_OFF"); text=${MESSAGE:-$T_MESSAGE_OFF}; fi
    # A blank line starts a new paragraph, a single new line is a line break.
    GW_MESSAGE=$(esc "$text" | awk 'BEGIN { RS = "" } { gsub(/[ \t]*\n[ \t]*/, "<br>"); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); printf "<p>%s</p>\n", $0 }')
    export GW_STATUS GW_MESSAGE
    awk '
      {
        out = ""; line = $0
        while ((i = index(line, "@@")) > 0) {
          rest = substr(line, i + 2); j = index(rest, "@@")
          if (j == 0) break
          key = substr(rest, 1, j - 1)
          if (key !~ /^[A-Z_]+$/) { out = out substr(line, 1, i + 1); line = rest; continue }
          if (!(("GW_" key) in ENVIRON)) { print "gateway: the page template names @@" key "@@, which nothing fills." > "/dev/stderr"; exit 1 }
          out = out substr(line, 1, i - 1) ENVIRON["GW_" key]
          line = substr(rest, j + 2)
        }
        print out line
      }' "$TEMPLATE" >"$PAGES/index-$m.html" || exit 1
  done
fi

# --- Routes. Everything below lands inside the Caddyfile, so every value is checked against a strict
# shape first: a brace or a space in the wrong place would otherwise rewrite the configuration.
set -f # a `*` in ROUTES or MAINTENANCE_PASSTHROUGH is a pattern for Caddy, never for the shell

PASS=''
for p in $(printf '%s' "${MAINTENANCE_PASSTHROUGH:-}" | tr ',' ' '); do
  printf '%s' "$p" | grep -Eq '^/[A-Za-z0-9._~/*-]*$' ||
    fail "MAINTENANCE_PASSTHROUGH has [$p]: a path starts with / and holds letters, digits, . _ ~ / * - only."
  PASS="$PASS $p"
done

SITES=''
STAR=''
SEEN=' '
HOSTS=''
COUNT=0
for entry in $(printf '%s' "${ROUTES:-}" | tr ',' ' '); do
  case "$entry" in
    *=*) ;;
    *) fail "ROUTES has [$entry], which is not host=upstream." ;;
  esac
  host=$(printf '%s' "${entry%%=*}" | tr 'A-Z' 'a-z')
  upstream=${entry#*=}
  [ -n "$host" ] ||
    fail "ROUTES has [$entry], with no host: a reference to a variable that is not set yet?"
  if [ "$host" != '*' ]; then
    printf '%s' "$host" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' ||
      fail "ROUTES names the host [$host]: a host name, or * for every other host."
  elif [ "$TLS_" != off ]; then
    fail "ROUTES has a * route with TLS=$TLS_: a certificate is for a host by name, so every host is listed."
  fi
  printf '%s' "$upstream" | grep -Eq '^http://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):[0-9]+$' ||
    fail "ROUTES sends [$host] to [$upstream]: an upstream is http://name:port (the private network speaks http, and the port is never guessed)."
  case "$SEEN" in *" $host "*) fail "ROUTES names [$host] twice." ;; esac
  SEEN="$SEEN$host "
  [ "$host" = '*' ] || HOSTS="${HOSTS:+$HOSTS, }$host"
  COUNT=$((COUNT + 1))

  # What maintenance answers on this host: the page, or the upstream for a passthrough path.
  if [ -n "$PASS" ]; then
    closed="		@pass_$COUNT path$PASS
		handle @pass_$COUNT {
			import upstream $upstream
		}
		handle {
			import maintenance on
		}"
  else
    closed='		import maintenance on'
  fi

  if [ "$MODE" = on ]; then
    body=$closed
  elif [ -n "$SWITCH" ]; then
    body="		@switch_$COUNT file {
			root $SWITCH_DIR
			try_files /$SWITCH_NAME
		}
		handle @switch_$COUNT {
	$closed
		}
		handle {
			import upstream $upstream
		}"
  else
    body="		import upstream $upstream"
  fi

  echo "gateway: $host -> $upstream"
  if [ "$host" = '*' ]; then
    STAR="	handle {
$body
	}"
  else
    SITES="$SITES
	@route_$COUNT host $host
	handle @route_$COUNT {
$body
	}"
  fi
done

[ "$COUNT" -gt 0 ] || fail "ROUTES is empty: name at least one host=upstream pair."

# No `*` route: a host nobody listed gets a bare 404, rather than one of the apps picked by position.
[ -n "$STAR" ] || STAR='	handle {
		respond 404
	}'

echo "gateway: maintenance $MODE${SWITCH:+, or on while $SWITCH exists}${PASS:+, still forwarding$PASS}"
echo "gateway: tls $TLS_, trusted proxies: $TRUST"

# The pieces that depend on TLS and on whom the gateway trusts.
GLOBAL_TLS='	auto_https off'
SITE_ADDRESS=":$PORT"
SITE_TLS=''
HEALTH_SITE=''
if [ "$TLS_" != off ]; then
  GLOBAL_TLS='	skip_install_trust'
  [ -z "$TLS_EMAIL_" ] || GLOBAL_TLS="$GLOBAL_TLS
	email $TLS_EMAIL_"
  SITE_ADDRESS=$HOSTS
  [ "$TLS_" = internal ] && SITE_TLS='	tls internal'
  # The healthcheck on a plain port of its own, for docker or a load balancer: the hosts are https only.
  HEALTH_SITE="http://:$PORT {
	respond /_gateway/health \"ok\" 200
	respond 404
}"
fi
case "$TRUST" in
  all)
    TRUST_SERVER='		trusted_proxies static 0.0.0.0/0 ::/0'
    # The edge's own X-Forwarded-For, unchanged: appended to, its last entry would be the edge, and
    # that last entry is what most frameworks take for the client.
    FORWARD='		header_up X-Forwarded-For {http.request.header.X-Forwarded-For}'
    ;;
  none)
    TRUST_SERVER=''
    # Nobody is believed: whatever a client sent is replaced with what the gateway saw.
    FORWARD='		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}'
    ;;
  *)
    TRUST_SERVER="		trusted_proxies static $TRUST"
    # Caddy's own rule: a trusted proxy's X-Forwarded-* is kept and its address appended; anybody
    # else's is replaced.
    FORWARD=''
    ;;
esac

cat >/etc/caddy/Caddyfile <<CADDY
{
$GLOBAL_TLS
	admin off
	log {
		output stdout
	}
	servers {
$TRUST_SERVER
	}
}

(maintenance) {
	header X-Gateway maintenance
	header Retry-After 120
	header Cache-Control no-store
	root * $PAGES
	handle @html {
		rewrite * /index-{args[0]}.html
		file_server {
			status 503
		}
	}
	handle {
		rewrite * /maintenance-{args[0]}.json
		file_server {
			status 503
		}
	}
}

(upstream) {
	# No flush_interval: a stream (SSE, a chatbot's answer) has no Content-Length, and Caddy forwards
	# such a body piece by piece by itself (tests/check.sh tries both kinds).
	reverse_proxy {args[0]} {
$FORWARD
		transport http {
			dial_timeout 5s
		}
		@down status 502 503 504
		handle_response @down {
			import maintenance off
		}
	}
}

$SITE_ADDRESS {
$SITE_TLS
	log {
		output stdout
	}
	@html {
		not path /api/*
		not header Accept *application/json*
	}
	handle_errors {
		import maintenance $MODE
	}
	# Railway's healthcheck: Caddy is up and this file was accepted, whatever the upstreams are doing.
	@gateway_health path /_gateway/health
	handle @gateway_health {
		respond "ok" 200
	}
$SITES
$STAR
}

$HEALTH_SITE
CADDY

caddy fmt --overwrite /etc/caddy/Caddyfile
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
