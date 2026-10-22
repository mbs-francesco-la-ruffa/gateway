#!/usr/bin/env bash
#
# Tries bin/maintenance.mjs against a fake Railway CLI (RAILWAY_CLI), which records every call and
# answers like the real one: no account, no network beyond a host name that cannot resolve.
#
#   bash tests/check-command.sh
#
# Needs node 22 or later. A few seconds. CHECK_COMMAND=<copy> tries a deliberately broken copy instead.
set -uo pipefail

cd "$(dirname "$0")/.."

PASSED=0
FAILED=0
check() { # check <description> <condition...>
  local what=$1; shift
  if "$@"; then PASSED=$((PASSED + 1)); echo "ok   $what"; else FAILED=$((FAILED + 1)); echo "FAIL $what"; sed 's/^/     /' "$TMP/out"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The fake CLI: VARS is what `variable list` answers; `variable set` and `deployment list` are recorded.
cat >"$TMP/railway" <<'FAKE'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
case "$1 $2" in
  'variable list') printf '%s' "$FAKE_VARS" ;;
  'variable set') echo set ;;
  'deployment list') printf '[{"id":"dep-0001-xxxx","status":"SUCCESS","createdAt":"2026-10-22T10:00:00Z"}]' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/railway"
export RAILWAY_CLI="$TMP/railway" FAKE_LOG="$TMP/calls"

run() { : >"$TMP/calls"; node "${CHECK_COMMAND:-bin/maintenance.mjs}" "$@" >"$TMP/out" 2>&1; CODE=$?; }
called() { grep -qxF -- "$1" "$TMP/calls"; }
said() { grep -qF -- "$1" "$TMP/out"; }

export FAKE_VARS='{"ROUTES":"App.gw-check.invalid=http://app.railway.internal:8080,*=http://x.railway.internal:8080","MAINTENANCE":"off","MAINTENANCE_UNTIL":"18:00"}'

run status --project p-123 --environment staging --service front-door
check "status reads the variables of the named service, project and environment" \
  called 'variable list --json --service front-door --project p-123 --environment staging'
check "  sets nothing" bash -c "! grep -q 'variable set' '$TMP/calls'"
check "  reports the mode, the expected time and every named host but *" \
  bash -c "[ $CODE = 0 ] && grep -qF 'MAINTENANCE=off' '$TMP/out' && grep -qF 'expected back: 18:00' '$TMP/out' && grep -qF 'https://app.gw-check.invalid/ → no answer' '$TMP/out' && [ \$(grep -c 'https://' '$TMP/out') = 1 ]"

run on --no-wait --environment production
check "on sets MAINTENANCE=on on the service called gateway by default" called 'variable set MAINTENANCE=on --service gateway --environment production'
check "  and with --no-wait returns at once" bash -c "[ $CODE = 0 ] && grep -qF 'Not waiting' '$TMP/out'"

run off
check "off when it is already off changes nothing" bash -c "[ $CODE = 0 ] && grep -qF 'nothing to change' '$TMP/out' && ! grep -q 'variable set' '$TMP/calls'"

FAKE_VARS='{"PORT":"8080"}' run on
check "a service with no ROUTES is not a gateway, and nothing is set" \
  bash -c "[ $CODE = 1 ] && grep -qF 'is not a gateway' '$TMP/out' && ! grep -q 'variable set' '$TMP/calls'"

run maybe
check "an unknown command shows the usage" bash -c "[ $CODE = 1 ] && grep -qF 'usage:' '$TMP/out'"
run on --service
check "an option without its value is refused" bash -c "[ $CODE = 1 ] && grep -qF -- '--service needs a value' '$TMP/out'"
run on --project --no-wait
check "  also when the next word is another option" bash -c "[ $CODE = 1 ] && grep -qF -- '--project needs a value' '$TMP/out'"

RAILWAY_CLI=/nonexistent/railway run status
check "no Railway CLI: says how to get one" bash -c "[ $CODE = 1 ] && grep -qF 'npm i -g @railway/cli' '$TMP/out'"

# Away from Railway: fake docker and ssh that run the script they are given on this machine, so the
# switch file is a real file under $TMP and the quoting is the real quoting.
cat >"$TMP/docker" <<'FAKE'
#!/bin/sh
echo "docker $*" >>"$FAKE_LOG"
[ "$1" = exec ] || { echo "unexpected: $*" >&2; exit 1; }
shift 2 # exec <container>
MAINTENANCE=$FAKE_ENV_MAINTENANCE ROUTES=$FAKE_ENV_ROUTES exec "$@"
FAKE
cat >"$TMP/ssh" <<'FAKE'
#!/bin/sh
echo "ssh $*" >>"$FAKE_LOG"
shift # the host
exec sh -c "$1"
FAKE
chmod +x "$TMP/docker" "$TMP/ssh"
export DOCKER_CLI="$TMP/docker" SSH_CLI="$TMP/ssh" FAKE_ENV_MAINTENANCE='' FAKE_ENV_ROUTES='app.gw-check.invalid=http://app:8080'
FLAG="$TMP/data/maintenance.on"

run on --docker gw-1 --path "$FLAG"
check "on --docker creates the switch file through docker exec, no Railway call" \
  bash -c "[ $CODE = 0 ] && [ -e '$FLAG' ] && grep -q '^docker exec gw-1 sh -c' '$TMP/calls' && ! grep -q '^variable' '$TMP/calls'"
check "  and reports maintenance on, the file, and every host" \
  bash -c "grep -qF 'maintenance on' '$TMP/out' && grep -qF 'present' '$TMP/out' && grep -qF 'https://app.gw-check.invalid/' '$TMP/out'"
run status --docker gw-1 --path "$FLAG"
check "status --docker reads, changes nothing" bash -c "[ $CODE = 0 ] && [ -e '$FLAG' ] && ! grep -q 'touch\|rm -f' '$TMP/calls'"
run off --docker gw-1 --path "$FLAG"
check "off --docker removes it" bash -c "[ $CODE = 0 ] && [ ! -e '$FLAG' ] && grep -qF 'maintenance off' '$TMP/out'"
FAKE_ENV_MAINTENANCE=on run off --docker gw-1 --path "$FLAG"
check "off with MAINTENANCE=on in the container says the variable wins" bash -c "grep -qF 'wins over the file' '$TMP/out' && grep -qF 'maintenance on' '$TMP/out'"

run on --ssh deploy@server.example --path "$FLAG"
check "on --ssh creates the file on the server, through ssh" \
  bash -c "[ $CODE = 0 ] && [ -e '$FLAG' ] && grep -q '^ssh deploy@server.example ' '$TMP/calls' && ! grep -q '^docker' '$TMP/calls'"
run off --ssh deploy@server.example --docker gw-1 --path "$FLAG"
check "off --ssh --docker runs docker exec on the server" \
  bash -c "[ $CODE = 0 ] && [ ! -e '$FLAG' ] && grep -q '^ssh deploy@server.example .*exec.*gw-1' '$TMP/calls' && grep -q '^docker exec gw-1' '$TMP/calls'"

run on --ssh deploy@server.example
check "--ssh alone needs --path" bash -c "[ $CODE = 1 ] && grep -qF -- '--path says where' '$TMP/out'"
run on --docker 'gw;rm -rf /'
check "a container name with a shell character is refused" bash -c "[ $CODE = 1 ] && grep -qF -- '--docker is' '$TMP/out' && ! grep -q '^docker' '$TMP/calls'"
run on --docker gw-1 --path "/data/x';touch /tmp/pwned;'"
check "a path with a quote is refused" bash -c "[ $CODE = 1 ] && grep -qF -- '--path is' '$TMP/out' && ! grep -q '^docker' '$TMP/calls'"
run on --docker gw-1 --environment production
check "a Railway option with --docker is refused" bash -c "[ $CODE = 1 ] && grep -qF 'are for Railway' '$TMP/out'"

echo
if [ "$FAILED" -eq 0 ]; then echo "command check passed ($PASSED checks)"; else echo "command check failed: $FAILED of $((PASSED + FAILED))"; exit 1; fi
