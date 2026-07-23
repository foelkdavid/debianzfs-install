#!/bin/sh
set -eu

JOBS="${JOBS:-/etc/zfs-autosnap/jobs.conf}"
STATE="${STATE:-/var/lib/zfs-autosnap}"
mkdir -p "$STATE"

echo "[INFO] zfs-autosnap starting at $(date -Ins)"

cleanup() {
  echo "[INFO] zfs-autosnap shutting down"
  trap - INT TERM HUP
  kill -TERM -- -$$ 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup INT TERM HUP

trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

seconds_from_slack() {
  case "$1" in
    *d) echo "$((${1%d} * 86400))" ;;
    *h) echo "$((${1%h} * 3600))" ;;
    *min) echo "$((${1%min} * 60))" ;;
    *m) echo "$((${1%m} * 60))" ;;
    *s) echo "${1%s}" ;;
    '') echo 60 ;;
    *) echo "$1" ;;
  esac
}

next_epoch() {
  sched="$1"
  case "$sched" in
    *"-H0"*"-M0"*) date -d "tomorrow 00:00" +%s ;;
    *"-H*"*"-M0"*) date -d "next hour" +%s ;;
    *"-H*"*"-M/15"*)
      now=$(date +%s)
      echo "$((now + 900 - (now % 900)))"
      ;;
    *"-H*"*"-M"*) date -d "now +1 minute" +%s ;;
    *) date -d "now +5 minutes" +%s ;;
  esac
}

label_prefix() {
  printf '%s' "$1" | sed 's/\$(.*$//'
}

label_pattern() {
  patt="$(printf '%s' "$1" | sed -n 's/.*$(\([^)]*\)).*/\1/p')"
  [ -n "$patt" ] || patt="%Y%m%d-%H%M"
  printf '%s' "$patt"
}

run_snapshot() {
  name="$1"
  dataset="$2"
  label="$3"
  keep="$4"
  flags="$5"
  tf="$6"

  prefix="$(label_prefix "$label")"
  patt="$(label_pattern "$label")"
  stamp="$(date +"$patt")"
  snap="${dataset}@${prefix}${stamp}"
  rflag=""
  printf '%s' "$flags" | grep -q 'r' && rflag="-r"

  echo "[INFO] $name snapshot $snap"
  if zfs snapshot $rflag "$snap"; then
    touch "$tf"
  else
    echo "[WARN] $name snapshot failed: $snap" >&2
    return 1
  fi

  echo "[INFO] $name prune keep=$keep"
  zfs list -H -t snapshot -o name -S creation \
    | grep "^${dataset}@${prefix}" \
    | tail -n +"$((keep + 1))" \
    | xargs -r -n1 zfs destroy
  echo "[INFO] $name cycle done"
}

start_worker() {
  name="$1"
  dataset="$2"
  label="$3"
  sched="$4"
  keep="$5"
  slack="$6"
  flags="$7"
  tf="$STATE/${name}.timefile"
  slack_seconds="$(seconds_from_slack "$slack")"

  echo "[INFO] worker '$name' -> dataset=$dataset schedule='$sched' keep=$keep slack=$slack flags=$flags"

  (
    trap 'exit 0' INT TERM HUP
    while :; do
      target="$(next_epoch "$sched")"
      now="$(date +%s)"
      sleep_for="$((target - now))"
      [ "$sleep_for" -lt 0 ] && sleep_for=0
      [ "$slack_seconds" -gt 0 ] && sleep_for="$((sleep_for + slack_seconds))"
      echo "[INFO] $name waiting ${sleep_for}s"
      sleep "$sleep_for"
      run_snapshot "$name" "$dataset" "$label" "$keep" "$flags" "$tf" || true
    done
  ) &
}

while IFS= read -r line; do
  [ -z "$line" ] && continue
  printf '%s' "$line" | grep -q '^[[:space:]]*#' && continue

  IFS='|' read -r name dataset label sched keep slack flags <<EOF
$line
EOF

  name="$(printf '%s' "$name" | trim)"
  dataset="$(printf '%s' "$dataset" | trim)"
  label="$(printf '%s' "$label" | trim)"
  sched="$(printf '%s' "$sched" | trim)"
  keep="$(printf '%s' "$keep" | trim)"
  slack="$(printf '%s' "$slack" | trim)"
  flags="$(printf '%s' "$flags" | trim)"

  start_worker "$name" "$dataset" "$label" "$sched" "$keep" "$slack" "$flags"
done < "$JOBS"

wait
