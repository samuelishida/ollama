#!/usr/bin/env bash
# Override the system Ollama with the custom speculative-decoding build.
#
#   sudo scripts/install-custom-ollama.sh              install + restart + verify
#   sudo scripts/install-custom-ollama.sh --dry-run    show what would happen
#   sudo scripts/install-custom-ollama.sh --rollback   restore newest backup
#
# WHY: /usr/local/bin/ollama is a STALE custom build. It forwards draft-mtp,
# draft-dflash and ngram-mod, but not --spec-ngram-map-k4v-size-n/-size-m/-min-hits
# and not OLLAMA_LLAMA_SERVER. So a Modelfile asking for
# `draft_spec_type ngram-map-k4v` enables the route with llama.cpp DEFAULTS
# instead of the 12/48/1 the published tags specify.
#
# The native payload is already correct: /usr/local/lib/ollama/libllama-common.so
# carries all three --spec-ngram-map-k4v-* flags. Only the Go wrapper needs replacing.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SRC="${OLLAMA_CUSTOM_SRC:-$REPO_ROOT/build/ollama-ngram}"
DEST="${OLLAMA_SYSTEM_BIN:-/usr/local/bin/ollama}"
LIBDIR="${OLLAMA_SYSTEM_LIBDIR:-/usr/local/lib/ollama}"
SERVICE="${OLLAMA_SYSTEM_SERVICE:-ollama}"
API="${OLLAMA_API:-http://127.0.0.1:11434}"

# Strings the wrapper must contain to do the job.
REQUIRED_FLAGS=(
  spec-ngram-map-k4v-size-n
  spec-ngram-map-k4v-size-m
  spec-ngram-map-k4v-min-hits
  OLLAMA_LLAMA_SERVER
)
# Strings the native payload must contain (separate component, warn only).
NATIVE_FLAGS=(
  spec-ngram-map-k4v-size-n
  spec-ngram-map-k4v-size-m
  spec-ngram-map-k4v-min-hits
)

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# Dump strings ONCE per file into a cache file, then count matches.
#
# Do NOT use `strings ... | grep -q`: grep -q exits on the first match, which
# kills strings with SIGPIPE, and `set -o pipefail` then reports the whole
# pipeline as failed. That produced false "missing" results. grep -c reads all
# input, so nothing gets SIGPIPE'd.
declare -A STRINGS_CACHE=()
STRINGS_TMPDIR=""
cleanup() { [[ -n "$STRINGS_TMPDIR" ]] && rm -rf "$STRINGS_TMPDIR"; }
trap cleanup EXIT

strings_of() {
  local file="$1" key
  key="$(printf '%s' "$file" | md5sum | cut -d' ' -f1)"
  if [[ -z "${STRINGS_CACHE[$key]:-}" ]]; then
    [[ -n "$STRINGS_TMPDIR" ]] || STRINGS_TMPDIR="$(mktemp -d)"
    STRINGS_CACHE[$key]="$STRINGS_TMPDIR/$key.txt"
    strings -a "$file" > "${STRINGS_CACHE[$key]}" 2>/dev/null || true
  fi
  printf '%s' "${STRINGS_CACHE[$key]}"
}

# count occurrences of a literal string inside a binary
count_in() {
  local file="$1" needle="$2" dump n
  dump="$(strings_of "$file")"
  n="$(grep -cF -- "$needle" "$dump" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

have() { [[ "$(count_in "$1" "$2")" -gt 0 ]]; }

[[ $EUID -eq 0 ]] || die "must run as root:  sudo $0 ${1:-}"
command -v strings >/dev/null || die "needs 'strings' (install binutils)"
command -v systemctl >/dev/null || die "needs systemctl"

# ---------------------------------------------------------------- rollback ---
if [[ "${1:-}" == "--rollback" ]]; then
  backup="$(ls -1t "$DEST".bak-* 2>/dev/null | head -1 || true)"
  [[ -n "$backup" ]] || die "no $DEST.bak-* backup found"
  log "restoring $backup -> $DEST"
  install -o root -g root -m 755 "$backup" "$DEST"
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  sleep 2
  log "rolled back; service=$(systemctl is-active "$SERVICE")"
  exit 0
fi

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# ------------------------------------------------------------ preflight ------
log "candidate : $SRC"
[[ -f "$SRC" ]] || die "not found: $SRC
       build it:  cd $(dirname "$(dirname "$SRC")") && scripts/ollama-ngram.sh build --docker"
[[ -x "$SRC" ]] || die "not executable: $SRC"

missing=()
for f in "${REQUIRED_FLAGS[@]}"; do
  have "$SRC" "$f" || missing+=("$f")
done
if (( ${#missing[@]} )); then
  printf '\n  strings found in candidate (spec/ngram/ollama-related):\n'
  grep -iE 'ngram|spec|draft' "$(strings_of "$SRC")" 2>/dev/null | sort -u | head -25 | sed 's/^/    /'
  die "candidate is missing required strings: ${missing[*]}
       refusing to install a wrapper that cannot forward the route"
fi
log "wrapper carries all ${#REQUIRED_FLAGS[@]} required flag strings"

if [[ "$SRC" == "$DEST" ]]; then
  die "source and destination are the same path: $SRC"
fi

if [[ -f "$DEST" ]] && cmp -s "$SRC" "$DEST"; then
  log "already identical to $DEST -- nothing to do"
  exit 0
fi

# native payload is a separate component; warn only
if [[ -d "$LIBDIR" ]]; then
  nmissing=()
  for f in "${NATIVE_FLAGS[@]}"; do
    grep -rqF -- "$f" "$LIBDIR" 2>/dev/null || nmissing+=("$f")
  done
  if (( ${#nmissing[@]} )); then
    warn "native payload in $LIBDIR lacks: ${nmissing[*]}"
    warn "the wrapper will pass flags the native llama.cpp may reject."
    warn "you may also need the fork's build/lib/ollama/* payload."
  else
    log "native payload in $LIBDIR supports the k4v flags"
  fi
else
  warn "no native payload dir at $LIBDIR"
fi

log "current   : $DEST  ($( "$DEST" --version 2>&1 | head -1 ))"
log "service   : $SERVICE is $(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)"

if [[ $DRY -eq 1 ]]; then
  printf '\nDRY RUN -- no changes made. Would:\n'
  printf '  1. cp -a %s %s.bak-%s\n' "$DEST" "$DEST" "$(date +%Y%m%d-%H%M%S)"
  printf '  2. install -o root -g root -m 755 %s %s\n' "$SRC" "$DEST"
  printf '  3. systemctl daemon-reload && systemctl restart %s\n' "$SERVICE"
  printf '  4. verify flags on %s and smoke-test %s/api/version\n' "$DEST" "$API"
  exit 0
fi

# ---------------------------------------------------------------- install ----
backup=""
if [[ -f "$DEST" ]]; then
  backup="$DEST.bak-$(date +%Y%m%d-%H%M%S)"
  log "backing up $DEST -> $backup"
  cp -a "$DEST" "$backup"
fi

log "installing -> $DEST"
install -o root -g root -m 755 "$SRC" "$DEST"

log "restarting $SERVICE"
systemctl daemon-reload
systemctl restart "$SERVICE"
sleep 3

# ---------------------------------------------------------------- verify -----
log "verify"
printf '  service  : %s\n' "$(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)"
printf '  main pid : %s\n' "$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null)"
printf '  version  : %s\n' "$( "$DEST" --version 2>&1 | head -1 )"
printf '  binary   : %s\n' "$(stat -c '%s bytes, mtime %y' "$DEST" 2>/dev/null)"

fail=0
for f in "${REQUIRED_FLAGS[@]}"; do
  n="$(count_in "$DEST" "$f")"
  printf '  %-30s %s\n' "$f" "$n"
  [[ "$n" == "0" ]] && fail=1
done

smoke="$(curl -fsS --max-time 10 "$API/api/version" 2>/dev/null || true)"
if [[ -n "$smoke" ]]; then
  printf '  api      : %s\n' "$smoke"
else
  warn "no response from $API/api/version yet (service may still be starting)"
fi

printf '\n'
if (( fail )); then
  die "verification failed -- one or more flags missing after install.
       roll back with:  sudo $0 --rollback"
fi

log "done -- system Ollama is now the custom build"
printf '\nRollback:  sudo %s --rollback\n' "$0"
[[ -n "$backup" ]] && printf 'Backup  :  %s\n' "$backup"
printf '\nNext: a tag using `draft_spec_type ngram-map-k4v` will now receive its\n'
printf 'configured size-n/size-m/min-hits. Do one short generation to confirm.\n'
