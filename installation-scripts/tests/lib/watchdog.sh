# shellcheck shell=bash
# ============================================================================
# watchdog_start - a time limit for a whole test suite (installation-scripts/tests/).
#
# Every suite sources this right after setting its EXIT trap:
#
#   . "${src_root}/installation-scripts/tests/lib/watchdog.sh"
#   watchdog_start
#
# If the suite is still running when the limit is reached, the watchdog
# prints every process still running under it, with its arguments (the
# command it is stuck in), stops them, and the suite exits 124, as it would
# under `timeout`. The suite's own EXIT trap still runs, after those
# processes are gone (on Windows, rm cannot remove a directory a live process
# still runs in), so its throwaway copy is removed.
#
#   TEST_WATCHDOG_SECS  the limit in seconds (default 1200); 0 turns it off.
#
# It also makes a stop from outside (`timeout`, Ctrl-C) run the suite's EXIT
# trap to the end, even with the timer off (see _wd_signalled). A TERM sent
# to the suite's shell alone takes effect only when the command it waits for
# ends. `timeout` and Ctrl-C signal the whole process group, so they are not
# delayed.
#
# The default is far above a normal run. Under Git Bash every process start
# costs 50-150 ms, and a suite starts thousands, so a suite takes minutes
# there (test-rollback.sh 7 to 12) and seconds on Linux. A slow run is not a
# hang, and a short outside `timeout` makes it look like one.
#
# Lists and stops processes through /proc (Linux, Git Bash/MSYS). Under Git
# Bash it also asks Windows (powershell.exe) for the Windows programs under
# them that /proc does not list. Without /proc the suite itself is still
# stopped, but not what runs under it.
# ============================================================================

_wd_pid=""
_wd_fired=""

# Prints "<pid> <depth>" for every process under <root>, parents first,
# leaving out <skip> and everything under it (the watchdog itself).
_wd_descendants() {  # <root> <skip>
  local f s r pid i=0
  local -A parent=()
  local -a queue=("$1") depth=(0)
  for f in /proc/[0-9]*/stat; do
    { read -r s < "$f"; } 2>/dev/null || continue
    r="${s##*) }"; r="${r#* }"       # "<pid> (<name>) <state> <ppid> ..."
    parent["${s%% *}"]="${r%% *}"
  done
  while (( i < ${#queue[@]} )); do
    for pid in "${!parent[@]}"; do
      [[ "${parent[$pid]}" == "${queue[$i]}" && "$pid" != "$2" ]] || continue
      queue+=("$pid"); depth+=($(( depth[i] + 1 )))
      printf '%s %s\n' "$pid" "$(( depth[i] + 1 ))"
    done
    i=$((i + 1))
  done
}

_wd_cmdline() {  # <pid>
  local -a argv=()
  { mapfile -d '' -t argv < "/proc/$1/cmdline"; } 2>/dev/null || true
  local line="${argv[*]}"
  printf '%s' "${line:0:300}"
}

_wd_args() {  # <command line>: it without the program, quoted ("C:\...\bash.exe") or not
  local c="$1"
  if [[ "$c" == \"* ]]; then c="${c#\"*\"}"; c="${c# }"; else c="${c#* }"; fi
  printf '%s' "$c"
}

# Git Bash only. A Windows program started by another Windows program has no
# /proc entry, e.g. python3.13.exe behind the Microsoft Store's python3
# alias, and stopping its parent leaves it running with the suite's $(...)
# pipe open. Prints "<winpid> <command line>" for every Windows process under
# <winpid>... that is not one of them, created after its parent (Windows
# reuses pids), leaving out <skip> (the watchdog) and what runs under it.
_wd_windows_only() {  # <skip winpid> <winpid>...
  command -v powershell.exe >/dev/null 2>&1 || return 0
  local skip="$1" w p t c i=0
  shift
  local -A parent=() born=() cmd=() seen=()
  local -a queue=("$@")
  for w in "$@"; do seen[$w]=1; done
  while IFS=$'\t' read -r w p t c; do
    parent[$w]="$p"; born[$w]="${t:-0}"; cmd[$w]="${c%$'\r'}"
  done < <(powershell.exe -NoProfile -NonInteractive -Command \
    'Get-CimInstance Win32_Process | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.ProcessId, $_.ParentProcessId, $_.CreationDate.Ticks, $_.CommandLine }' \
    < /dev/null 2>/dev/null)
  while (( i < ${#queue[@]} )); do
    for w in "${!parent[@]}"; do
      [[ "${parent[$w]}" == "${queue[$i]}" && "$w" != "$skip" && -z "${seen[$w]:-}" ]] || continue
      (( ${born[$w]:-0} >= ${born[${queue[$i]}]:-0} )) || continue
      seen[$w]=1; queue+=("$w")
      printf '%s %s\n' "$w" "${cmd[$w]:0:300}"
    done
    i=$((i + 1))
  done
}

_wd_alive() {  # <pid>...: is any of them still running?
  local p
  for p in "$@"; do kill -0 "$p" 2>/dev/null && return 0; done
  return 1
}

# Runs in the background for the suite's whole life.
_wd_run() {  # <suite pid> <suite name> <limit>
  set +e
  trap - EXIT USR1 TERM INT HUP
  local main="$1" name="$2" limit="$3" self="$BASHPID" pid depth n
  local end=$(( SECONDS + limit ))
  while (( SECONDS < end )); do
    kill -0 "$main" 2>/dev/null || return 0
    sleep 5 2>/dev/null
  done
  kill -0 "$main" 2>/dev/null || return 0

  local -a pids=() wins=() natives=()
  local main_cmd main_args cmd w mwin swin
  main_cmd="$(_wd_cmdline "$main")"
  main_args="$(_wd_args "$main_cmd")"
  printf '\nWATCHDOG: %s still running after %ss (TEST_WATCHDOG_SECS; 0 turns it off). Stopping it and what runs under it:\n' \
    "$name" "$limit" >&2
  while read -r pid depth; do
    pids+=("$pid")
    cmd="$(_wd_cmdline "$pid")"
    # Git Bash shows a fork in its Windows form: "C:\...\bash.exe" <same arguments>.
    [[ "$cmd" == "$main_cmd" || ( "$cmd" == *bash* && "$(_wd_args "$cmd")" == "$main_args" ) ]] \
      && cmd="(a subshell of the suite, e.g. \$(...))"
    printf '  %*s%s %s\n' $(( (depth - 1) * 2 )) '' "$pid" "$cmd" >&2
  done < <(_wd_descendants "$main" "$self")
  if { read -r mwin < "/proc/${main}/winpid" && read -r swin < "/proc/${self}/winpid"; } 2>/dev/null; then
    wins=("$mwin")
    for pid in "${pids[@]}"; do { read -r w < "/proc/${pid}/winpid"; } 2>/dev/null && wins+=("$w"); done
    while read -r w cmd; do
      natives+=("$w")
      printf '  %s (Windows) %s\n' "$w" "$cmd" >&2
    done < <(_wd_windows_only "$swin" "${wins[@]}")
  fi
  (( ${#pids[@]} + ${#natives[@]} )) || echo "  (no process under it: the suite itself is blocked, e.g. in a read)" >&2

  # USR1 first: the suite runs its trap as soon as the command it waits for
  # ends, so it never goes on to the next case. It then waits for this
  # process in its EXIT trap (_wd_stop), so this returns once all is stopped.
  kill -USR1 "$main" 2>/dev/null
  (( ${#natives[@]} )) && /usr/bin/kill -f -W "${natives[@]}" 2>/dev/null
  if (( ${#pids[@]} )); then
    kill -TERM "${pids[@]}" 2>/dev/null
    for n in 1 2 3 4 5 6 7 8 9 10; do _wd_alive "${pids[@]}" 2>/dev/null || break; sleep 0.5 2>/dev/null; done
  fi
  # Anything still there, or started since the list was made, gets KILL.
  while read -r pid depth; do pids+=("$pid"); done < <(_wd_descendants "$main" "$self")
  if (( ${#pids[@]} )) && _wd_alive "${pids[@]}"; then
    kill -KILL "${pids[@]}" 2>/dev/null
    for n in 1 2 3 4; do _wd_alive "${pids[@]}" || break; sleep 0.5 2>/dev/null; done
  fi
  return 0
}

# Part of the suite's EXIT trap, ahead of the suite's own command. After a
# stop, it waits until the watchdog has stopped everything under the suite,
# so the suite's cleanup can remove its copy. Never fails: the trap runs
# under the suite's errexit, and a failed kill (the watchdog already gone,
# e.g. an outside `timeout` signalled the whole process group) would skip
# the suite's cleanup.
_wd_stop() {
  [[ -n "$_wd_pid" ]] || return 0
  if [[ -n "$_wd_fired" ]]; then
    wait "$_wd_pid" 2>/dev/null || true
  else
    trap '' USR1   # a stop that comes this late must not cut the suite's cleanup short
    kill "$_wd_pid" 2>/dev/null || true
  fi
  _wd_pid=""
  return 0
}

# A stop from outside (timeout, Ctrl-C, a closed terminal) ends the suite
# through its EXIT trap, once the command it is waiting for has ended, with
# further signals ignored so that they cannot cut the cleanup short. Without
# these traps an outside `timeout` left the throwaway copy behind: under Git
# Bash its second TERM (to the whole process group) killed the EXIT trap
# mid-rm, and on Linux bash skips the EXIT trap now and then when TERM
# arrives while it has a background job (the watchdog).
_wd_signalled() {  # <exit code>
  trap '' TERM INT HUP
  exit "$1"
}

watchdog_start() {  # [default limit in seconds]
  local limit="${TEST_WATCHDOG_SECS:-${1:-1200}}" prev
  if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
    echo "ERROR: TEST_WATCHDOG_SECS must be a whole number of seconds (0 turns the watchdog off), got '${limit}'" >&2
    exit 2
  fi
  trap '_wd_signalled 143' TERM
  trap '_wd_signalled 130' INT
  trap '_wd_signalled 129' HUP
  (( limit > 0 )) || return 0
  trap '_wd_fired=1; exit 124' USR1
  # No stdin or stdout: only the message on expiry goes to the suite's stderr.
  _wd_run "$$" "${0##*/}" "$limit" < /dev/null > /dev/null &
  _wd_pid=$!
  # Run _wd_stop ahead of the suite's own EXIT trap ("trap -- '<command>' EXIT").
  prev="$(trap -p EXIT)"
  if [[ -n "$prev" ]]; then
    eval "set -- ${prev}"
    prev="$3"
  fi
  # shellcheck disable=SC2064 # expanded now on purpose: the suite's own command
  trap "_wd_stop; ${prev}" EXIT
}
