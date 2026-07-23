#!/bin/sh
set -eu

JOBS="${JOBS:-/etc/zfs-autosnap/jobs.conf}"
STATE="${STATE:-/var/lib/zfs-autosnap}"

trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

fmt_rel() {
  s=$1
  [ "$s" -lt 0 ] && s=0
  d=$((s / 86400)); s=$((s % 86400))
  h=$((s / 3600)); s=$((s % 3600))
  m=$((s / 60)); s=$((s % 60))
  printf "%2dd %2dh %2dm %2ds" "$d" "$h" "$m" "$s"
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

now_ts=$(date +%s)
echo "Now: $(date -Ins)"
printf "%-16s | %-19s | %s\n" "Job" "Last run (mtime)" "Next run (from now)"
echo "--------------------------------------------------------------------------"

grep -v '^[[:space:]]*\(#\|$\)' "$JOBS" |
while IFS='|' read -r name dataset label sched keep slack flags; do
  name="$(printf '%s' "$name" | trim)"
  sched="$(printf '%s' "$sched" | trim)"
  tf="$STATE/${name}.timefile"

  last="(none)"
  if [ -e "$tf" ]; then
    last="$(date -d "$(stat -c %y "$tf")" '+%F %T')"
  fi

  next_ts="$(next_epoch "$sched")"
  rel=$((next_ts - now_ts))
  next_str="$(date -d "@$next_ts" +%Y-%m-%dT%H:%M:%S%z)"
  printf "%-16s | %-19s | %s  %s\n" "$name" "$last" "$next_str" "$(fmt_rel "$rel")"
done
