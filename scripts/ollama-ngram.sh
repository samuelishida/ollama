#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SYSTEM_SERVICE="${OLLAMA_NGRAM_SYSTEM_SERVICE:-ollama}"
SYSTEM_BIN="${OLLAMA_NGRAM_SYSTEM_BIN:-/usr/local/bin/ollama}"
NATIVE_SERVER_OVERRIDE="${OLLAMA_NGRAM_LLAMA_SERVER:-}"
NATIVE_SERVER="${OLLAMA_NGRAM_LLAMA_SERVER:-/usr/local/lib/ollama/llama-server}"
MODEL_ROOT="${OLLAMA_MODELS:-${HOME}/.ollama/models}"
HOST_ADDR="${OLLAMA_NGRAM_HOST:-127.0.0.1:11434}"
SYSTEM_HOST_ADDR="${OLLAMA_NGRAM_SYSTEM_HOST:-127.0.0.1:11434}"
API_URL="${OLLAMA_NGRAM_API_URL:-http://${HOST_ADDR}}"
STATE_DIR="${OLLAMA_NGRAM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ollama-ngram}"
PID_FILE="$STATE_DIR/server.pid"
LOG_FILE="$STATE_DIR/server.log"
LOCK_FILE="$STATE_DIR/control.lock"
NATIVE_SERVER_STATE="$STATE_DIR/native-server.path"
BUILD_OUTPUT="${OLLAMA_NGRAM_BUILD_OUTPUT:-$REPO_ROOT/build/ollama-ngram}"
CMAKE_BUILD_DIR="${OLLAMA_NGRAM_CMAKE_BUILD_DIR:-$REPO_ROOT/build}"
PAYLOAD_PREFIX="${OLLAMA_NGRAM_PAYLOAD_PREFIX:-$CMAKE_BUILD_DIR}"
CMAKE_BACKENDS="${OLLAMA_NGRAM_CMAKE_BACKENDS:-vulkan}"
BUILD_JOBS="${OLLAMA_NGRAM_BUILD_JOBS:-8}"

OLD_CUSTOM_BIN="${XDG_DATA_HOME:-$HOME/.local/share}/ollama-ngram/bin/ollama"
if [[ -n "${OLLAMA_NGRAM_CUSTOM_BIN:-}" ]]; then
	CUSTOM_BIN="$OLLAMA_NGRAM_CUSTOM_BIN"
elif [[ -x "$BUILD_OUTPUT" ]]; then
	CUSTOM_BIN="$BUILD_OUTPUT"
else
	CUSTOM_BIN="$OLD_CUSTOM_BIN"
fi

USER_SERVICE="${OLLAMA_NGRAM_USER_SERVICE:-ollama-ngram}"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
USER_UNIT_FILE="$USER_UNIT_DIR/${USER_SERVICE}.service"
PI_MODELS_FILE="${OLLAMA_NGRAM_PI_MODELS_FILE:-$HOME/.pi/agent/models.json}"

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	echo "[ollama-ngram] $*" >&2
}

usage() {
	cat <<'EOF'
Usage:
  scripts/ollama-ngram.sh check
  scripts/ollama-ngram.sh build [--docker]
  scripts/ollama-ngram.sh build --full
  scripts/ollama-ngram.sh start-custom
  scripts/ollama-ngram.sh use-custom
  scripts/ollama-ngram.sh start-system
  scripts/ollama-ngram.sh use-system
  scripts/ollama-ngram.sh takeover
  scripts/ollama-ngram.sh sync-clients
  scripts/ollama-ngram.sh stop
  scripts/ollama-ngram.sh stop-custom
  scripts/ollama-ngram.sh restart-custom
  scripts/ollama-ngram.sh status
  scripts/ollama-ngram.sh logs

Both modes use 127.0.0.1:11434. Switching stops the other owner first.
takeover makes the custom build the permanent owner: it disables the
systemd service, starts the custom build on 127.0.0.1:11434, enables a
user unit so it comes back after reboot, and re-points the pi client
config at the live port.

Environment overrides:
  OLLAMA_NGRAM_CUSTOM_BIN   custom wrapper path
  OLLAMA_NGRAM_BUILD_OUTPUT build output path (default: build/ollama-ngram)
  OLLAMA_NGRAM_HOST         host:port (default: 127.0.0.1:11434)
  OLLAMA_NGRAM_USER_SERVICE user unit used for autostart (default: ollama-ngram)
  OLLAMA_NGRAM_NO_ROOT      skip privileged steps instead of calling sudo
                            (set by the generated user unit)
  OLLAMA_NGRAM_PI_MODELS_FILE
                            pi client config kept in sync
                            (default: ~/.pi/agent/models.json)
  OLLAMA_NGRAM_STATE_DIR    pid/log directory
  OLLAMA_NGRAM_GPU_MASK     Vulkan physical-device mask (default: 1)
  OLLAMA_NGRAM_GO_BIN       Go executable for local build
  OLLAMA_NGRAM_GO_IMAGE     Docker Go image (default: golang:1.26)
  OLLAMA_NGRAM_BUILD_JOBS   Full-build parallel jobs (default: 8)
  OLLAMA_NGRAM_CMAKE_BUILD_DIR
                            CMake build directory (default: build)
  OLLAMA_NGRAM_PAYLOAD_PREFIX
                            Native install/staging prefix (default: build)
  OLLAMA_NGRAM_CMAKE_BACKENDS
                            Full-build backend; must be vulkan currently
EOF
}

as_root() {
	if [[ "$EUID" -eq 0 ]]; then
		"$@"
		return
	fi
	if [[ -n "${OLLAMA_NGRAM_NO_ROOT:-}" ]]; then
		log "skipping privileged step (OLLAMA_NGRAM_NO_ROOT=1): $*"
		return 0
	fi
	command -v sudo >/dev/null 2>&1 || die "root access required for systemd switch; sudo not found"
	sudo "$@"
}

system_active() {
	systemctl is-active --quiet "$SYSTEM_SERVICE" 2>/dev/null
}

port_in_use() {
	local port="${HOST_ADDR##*:}"
	ss -ltnH 2>/dev/null | awk -v suffix=":$port" '$4 ~ suffix "$" { found = 1 } END { exit !found }'
}

wait_port_free() {
	local i
	for ((i = 0; i < 60; i++)); do
		if ! port_in_use; then
			return 0
		fi
		sleep 1
	done
	return 1
}

api_ready() {
	curl -fsS --max-time 2 "$API_URL/api/version" >/dev/null 2>&1
}

wait_api() {
	local i
	for ((i = 0; i < 120; i++)); do
		if api_ready; then
			return 0
		fi
		sleep 1
	done
	return 1
}

wait_custom_process() {
	local i
	for ((i = 0; i < 30; i++)); do
		if custom_running; then
			return 0
		fi
		sleep 1
	done
	return 1
}

custom_pid() {
	local candidate actual expected
	[[ -r "$PID_FILE" ]] || return 1
	candidate="$(<"$PID_FILE")"
	[[ "$candidate" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$candidate" 2>/dev/null || return 1
	actual="$(readlink -f "/proc/$candidate/exe" 2>/dev/null || true)"
	expected="$(readlink -f "$CUSTOM_BIN" 2>/dev/null || true)"
	[[ -n "$actual" && ("$actual" == "$expected" || "$actual" == "$expected (deleted)") ]] || return 1
	printf '%s\n' "$candidate"
}

custom_running() {
	custom_pid >/dev/null
}

resolve_native_server() {
	if [[ -n "$NATIVE_SERVER_OVERRIDE" ]]; then
		NATIVE_SERVER="$NATIVE_SERVER_OVERRIDE"
		return 0
	fi

	if [[ -r "$NATIVE_SERVER_STATE" ]]; then
		NATIVE_SERVER="$(<"$NATIVE_SERVER_STATE")"
		[[ -n "$NATIVE_SERVER" ]] || die "empty native payload state: $NATIVE_SERVER_STATE"
		return 0
	fi

	local built_vulkan="$PAYLOAD_PREFIX/lib/ollama/llama-server"
	if [[ -x "$built_vulkan" ]]; then
		NATIVE_SERVER="$built_vulkan"
	else
		NATIVE_SERVER="/usr/local/lib/ollama/llama-server"
	fi
}

stop_custom() {
	local pid i
	if ! pid="$(custom_pid)"; then
		rm -f "$PID_FILE"
		return 0
	fi

	log "stopping custom server pid=$pid"
	kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
	for ((i = 0; i < 30; i++)); do
		if ! kill -0 "$pid" 2>/dev/null; then
			rm -f "$PID_FILE"
			return 0
		fi
		sleep 1
	done

	log "custom server did not exit; terminating owned process group pid=$pid"
	kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
	rm -f "$PID_FILE"
}

stop_system() {
	if ! system_active; then
		return 0
	fi
	log "stopping systemd service $SYSTEM_SERVICE"
	as_root systemctl stop "$SYSTEM_SERVICE"
	wait_port_free || die "systemd service stopped but $HOST_ADDR remains occupied"
}

start_custom() {
	local system_was_active=0 native_dir backend_path native_ld_library_path
	resolve_native_server
	[[ -x "$CUSTOM_BIN" ]] || die "custom binary not executable: $CUSTOM_BIN"
	[[ -x "$NATIVE_SERVER" ]] || die "native payload not executable: $NATIVE_SERVER"
	native_dir="$(dirname -- "$NATIVE_SERVER")"
	if [[ -n "${OLLAMA_NGRAM_BACKEND:-}" ]]; then
		backend_path="$OLLAMA_NGRAM_BACKEND"
	elif [[ -f "$native_dir/libggml-vulkan.so" ]]; then
		backend_path="$native_dir/libggml-vulkan.so"
	elif [[ -f "$native_dir/vulkan/libggml-vulkan.so" ]]; then
		backend_path="$native_dir/vulkan/libggml-vulkan.so"
	else
		die "Vulkan backend not found beside native payload: $native_dir"
	fi
	[[ -f "$backend_path" ]] || die "Vulkan backend not found: $backend_path"
	native_ld_library_path="$native_dir"
	if [[ -d "$native_dir/vulkan" ]]; then
		native_ld_library_path="$native_ld_library_path:$native_dir/vulkan"
	fi
	if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
		native_ld_library_path="$native_ld_library_path:$LD_LIBRARY_PATH"
	fi
	if custom_running && ! system_active; then
		api_ready || die "custom process exists but API is not ready: $API_URL"
		log "custom server already running: $CUSTOM_BIN"
		return 0
	fi

	custom_running && stop_custom || true
	if system_active; then
		if [[ "$HOST_ADDR" == "$SYSTEM_HOST_ADDR" ]]; then
			system_was_active=1
			stop_system
		else
			log "systemd service remains on $SYSTEM_HOST_ADDR; custom uses separate $HOST_ADDR"
		fi
	fi
	wait_port_free || die "$HOST_ADDR is occupied by an unknown process"

	mkdir -p "$STATE_DIR"
	{
		printf '\n=== start %s ===\n' "$(date --iso-8601=seconds)"
		printf 'binary=%s\n' "$CUSTOM_BIN"
		printf 'host=%s\n' "$HOST_ADDR"
	} >>"$LOG_FILE"

	log "starting custom server: $CUSTOM_BIN"
	setsid env \
		OLLAMA_HOST="$HOST_ADDR" \
		OLLAMA_MODELS="$MODEL_ROOT" \
		OLLAMA_LLM_LIBRARY="${OLLAMA_LLM_LIBRARY:-vulkan}" \
		OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}" \
		OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}" \
		OLLAMA_DEBUG="${OLLAMA_DEBUG:-1}" \
		OLLAMA_LLAMA_SERVER="$NATIVE_SERVER" \
		GGML_BACKEND_PATH="$backend_path" \
		LD_LIBRARY_PATH="$native_ld_library_path" \
		GGML_VK_VISIBLE_DEVICES="${OLLAMA_NGRAM_GPU_MASK:-1}" \
		"$CUSTOM_BIN" serve >>"$LOG_FILE" 2>&1 9>&- &
	local pid=$!
	echo "$pid" >"$PID_FILE"

	if wait_custom_process && wait_api; then
		log "custom server ready at $API_URL"
		return 0
	fi

	log "custom server failed to become ready; see $LOG_FILE"
	stop_custom
	if ((system_was_active)); then
		as_root systemctl start "$SYSTEM_SERVICE"
	fi
	die "custom server start failed"
}

start_system() {
	stop_custom
	disable_user_unit
	if system_active; then
		if [[ "$HOST_ADDR" == "$SYSTEM_HOST_ADDR" ]]; then
			api_ready || die "systemd service active but API is not ready: $API_URL"
		elif ! curl -fsS --max-time 2 "http://${SYSTEM_HOST_ADDR}/api/version" >/dev/null 2>&1; then
			die "systemd service active but API is not ready: http://${SYSTEM_HOST_ADDR}"
		fi
		as_root systemctl enable "$SYSTEM_SERVICE" >/dev/null
		log "systemd service already running"
		return 0
	fi
	wait_port_free || die "$HOST_ADDR is occupied by an unknown process"
	log "starting systemd service $SYSTEM_SERVICE ($SYSTEM_BIN)"
	as_root systemctl enable --now "$SYSTEM_SERVICE" >/dev/null
	wait_api || die "systemd Ollama did not become ready"
	log "systemd Ollama ready at $API_URL"
}

check_binary() {
	[[ -x "$CUSTOM_BIN" ]] || die "custom binary not executable: $CUSTOM_BIN"
	local marker
	for marker in draft_spec_type draft_ngram_mod_n_match draft_ngram_mod_n_min draft_ngram_map_k4v_size_n; do
		grep -aFq "$marker" "$CUSTOM_BIN" || die "custom binary lacks feature marker: $marker"
	done
	"$CUSTOM_BIN" --version
}

check_native() {
	[[ -x "$NATIVE_SERVER" ]] || die "native llama-server not executable: $NATIVE_SERVER"
	local help option
	help="$("$NATIVE_SERVER" --help 2>&1 || true)"
	for option in --spec-type --spec-draft-n-max --spec-ngram-mod-n-match --spec-ngram-mod-n-min --spec-ngram-mod-n-max; do
		grep -Fq -- "$option" <<<"$help" || die "native payload lacks $option"
	done
	"$NATIVE_SERVER" --version
}

check() {
	resolve_native_server
	check_binary
	check_native
	printf 'custom_binary=%s\n' "$CUSTOM_BIN"
	printf 'native_server=%s\n' "$NATIVE_SERVER"
	printf 'native_server_state=%s\n' "$NATIVE_SERVER_STATE"
	printf 'model_root=%s\n' "$MODEL_ROOT"
	printf 'api=%s\n' "$API_URL"
	printf 'state=%s\n' "$STATE_DIR"
}

find_go() {
	if [[ -n "${OLLAMA_NGRAM_GO_BIN:-}" && -x "$OLLAMA_NGRAM_GO_BIN" ]]; then
		printf '%s\n' "$OLLAMA_NGRAM_GO_BIN"
		return 0
	fi
	if command -v go >/dev/null 2>&1; then
		command -v go
		return 0
	fi
	for candidate in /usr/local/go/bin/go /opt/go/bin/go; do
		if [[ -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

build_local() {
	local go_bin tmp
	go_bin="$(find_go)" || die "Go 1.26+ not found; use 'build --docker'"
	mkdir -p "$(dirname -- "$BUILD_OUTPUT")"
	tmp="$(mktemp "${BUILD_OUTPUT}.tmp.XXXXXX")"
	trap 'rm -f "$tmp"' RETURN
	log "building custom wrapper with $go_bin"
	(
		cd "$REPO_ROOT"
		"$go_bin" build -trimpath -ldflags '-s -w' -o "$tmp" .
	)
	chmod 755 "$tmp"
	mv -f "$tmp" "$BUILD_OUTPUT"
	trap - RETURN
	CUSTOM_BIN="$BUILD_OUTPUT"
	check_binary
}

validate_full_build_options() {
	[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || die "OLLAMA_NGRAM_BUILD_JOBS must be a positive integer: $BUILD_JOBS"
	[[ "$CMAKE_BUILD_DIR" = /* ]] || die "OLLAMA_NGRAM_CMAKE_BUILD_DIR must be an absolute path: $CMAKE_BUILD_DIR"
	[[ "$PAYLOAD_PREFIX" = /* ]] || die "OLLAMA_NGRAM_PAYLOAD_PREFIX must be an absolute path: $PAYLOAD_PREFIX"
	[[ "$CMAKE_BACKENDS" == "vulkan" ]] || die "full build currently supports only OLLAMA_NGRAM_CMAKE_BACKENDS=vulkan: $CMAKE_BACKENDS"
}

write_native_server_state() {
	local tmp
	mkdir -p "$STATE_DIR"
	tmp="$(mktemp "${NATIVE_SERVER_STATE}.tmp.XXXXXX")"
	printf '%s\n' "$NATIVE_SERVER" >"$tmp"
	mv -f "$tmp" "$NATIVE_SERVER_STATE"
}

build_full() {
	local go_bin built_native
	command -v cmake >/dev/null 2>&1 || die "cmake not found"
	validate_full_build_options
	custom_running && die "stop custom server before full build: $PID_FILE"
	go_bin="$(find_go)" || die "Go 1.26+ not found; set OLLAMA_NGRAM_GO_BIN or use the quick build"

	log "configuring full custom Ollama build: backend=$CMAKE_BACKENDS build_dir=$CMAKE_BUILD_DIR"
	cmake -S "$REPO_ROOT" -B "$CMAKE_BUILD_DIR" \
		-DOLLAMA_LLAMA_BACKENDS="$CMAKE_BACKENDS" \
		-DOLLAMA_GO_OUTPUT="$BUILD_OUTPUT" \
		-DOLLAMA_PAYLOAD_INSTALL_PREFIX="$PAYLOAD_PREFIX" \
		-DGO_EXECUTABLE="$go_bin"

	log "building full custom Ollama payload with $BUILD_JOBS jobs"
	cmake --build "$CMAKE_BUILD_DIR" --parallel "$BUILD_JOBS"

	built_native="$PAYLOAD_PREFIX/lib/ollama/llama-server"
	[[ -x "$BUILD_OUTPUT" ]] || die "full build did not produce custom wrapper: $BUILD_OUTPUT"
	[[ -x "$built_native" ]] || die "full build did not produce Vulkan native payload: $built_native"
	NATIVE_SERVER="$built_native"
	check_binary
	check_native
	write_native_server_state
	log "full custom Ollama build ready: wrapper=$BUILD_OUTPUT native=$NATIVE_SERVER"
}

build_docker() {
	command -v docker >/dev/null 2>&1 || die "docker not found"
	mkdir -p "$(dirname -- "$BUILD_OUTPUT")"
	local image="${OLLAMA_NGRAM_GO_IMAGE:-golang:1.26}"
	log "building custom wrapper in Docker image $image"
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		-e GOCACHE=/tmp/ollama-gocache \
		-e GOMODCACHE=/tmp/ollama-gomodcache \
		-v "$REPO_ROOT:/src" -w /src \
		"$image" \
		go build -trimpath -ldflags '-s -w' -o "${BUILD_OUTPUT#"$REPO_ROOT/"}" .
	CUSTOM_BIN="$BUILD_OUTPUT"
	check_binary
}

status() {
	local custom_state=down system_state=down api_state=down
	custom_running && custom_state="up pid=$(custom_pid)" || true
	system_active && system_state="up pid=$(systemctl show -p MainPID --value "$SYSTEM_SERVICE")" || true
	api_ready && api_state=ready || true
	printf 'custom=%s\n' "$custom_state"
	printf 'system=%s\n' "$system_state"
	printf 'api=%s (%s)\n' "$api_state" "$API_URL"
	printf 'custom_binary=%s\n' "$CUSTOM_BIN"
	printf 'log=%s\n' "$LOG_FILE"
}

unit_enabled() {
	systemctl --user is-enabled --quiet "$USER_SERVICE" 2>/dev/null
}

disable_user_unit() {
	unit_enabled || return 0
	log "disabling user unit $USER_SERVICE"
	systemctl --user disable --now "$USER_SERVICE" >/dev/null 2>&1 ||
		log "warning: could not disable user unit $USER_SERVICE"
}

write_user_unit() {
	local tmp launcher
	launcher="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
	mkdir -p "$USER_UNIT_DIR"
	tmp="$(mktemp "${USER_UNIT_FILE}.tmp.XXXXXX")"
	cat >"$tmp" <<EOF
[Unit]
Description=Custom Ollama ngram build on $HOST_ADDR

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=OLLAMA_NGRAM_HOST=$HOST_ADDR
Environment=OLLAMA_NGRAM_SYSTEM_HOST=$SYSTEM_HOST_ADDR
Environment=OLLAMA_NGRAM_GPU_MASK=${OLLAMA_NGRAM_GPU_MASK:-1}
Environment=OLLAMA_NGRAM_NO_ROOT=1
ExecStartPre=/bin/sh -c 'for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -d "$MODEL_ROOT" ] && exit 0; sleep 2; done; exit 0'
ExecStart=$launcher start-custom
ExecStop=$launcher stop-custom

[Install]
WantedBy=default.target
EOF
	mv -f "$tmp" "$USER_UNIT_FILE"
	log "user unit written: $USER_UNIT_FILE"
}

sync_clients() {
	local target current backup
	target="$API_URL/v1"
	if [[ ! -f "$PI_MODELS_FILE" ]]; then
		log "pi config not found: $PI_MODELS_FILE (skipped)"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		log "jq not found; set providers.ollama.baseUrl in $PI_MODELS_FILE to $target manually"
		return 0
	fi
	current="$(jq -r '.providers.ollama.baseUrl // empty' "$PI_MODELS_FILE" 2>/dev/null || true)"
	if [[ -z "$current" ]]; then
		log "no providers.ollama.baseUrl in $PI_MODELS_FILE (skipped)"
		return 0
	fi
	if [[ "$current" == "$target" ]]; then
		log "pi client already points at $target"
		return 0
	fi
	backup="$PI_MODELS_FILE.bak-$(date +%s)"
	cp -f "$PI_MODELS_FILE" "$backup" || die "cannot back up $PI_MODELS_FILE"
	if jq --arg url "$target" '.providers.ollama.baseUrl = $url' "$PI_MODELS_FILE" >"$PI_MODELS_FILE.tmp"; then
		mv -f "$PI_MODELS_FILE.tmp" "$PI_MODELS_FILE"
		log "pi client baseUrl $current -> $target (backup: $backup)"
	else
		rm -f "$PI_MODELS_FILE.tmp"
		die "failed to update $PI_MODELS_FILE"
	fi
}

takeover() {
	local system_was_active=0
	if custom_running && ! system_active; then
		log "custom build already owns $HOST_ADDR"
	else
		stop_custom
		if system_active; then
			system_was_active=1
		fi
		log "disabling systemd service $SYSTEM_SERVICE so the custom build owns $HOST_ADDR"
		as_root systemctl disable --now "$SYSTEM_SERVICE"
		if ! wait_port_free; then
			if ((system_was_active)); then
				as_root systemctl enable --now "$SYSTEM_SERVICE" >/dev/null 2>&1 || true
			fi
			die "$HOST_ADDR is still occupied after stopping $SYSTEM_SERVICE"
		fi
		if ! ( start_custom ); then
			if ((system_was_active)); then
				log "custom server failed to start; restoring systemd service $SYSTEM_SERVICE"
				as_root systemctl enable --now "$SYSTEM_SERVICE" >/dev/null 2>&1 || true
			fi
			die "takeover failed"
		fi
	fi

	write_user_unit
	systemctl --user daemon-reload
	if systemctl --user enable "$USER_SERVICE" >/dev/null 2>&1; then
		log "user unit $USER_SERVICE enabled for autostart (activates on next login or boot)"
	else
		log "warning: enable autostart manually: systemctl --user enable $USER_SERVICE"
	fi
	sync_clients
	status
}

stop_all() {
	stop_custom
	stop_system
}

with_lock() {
	mkdir -p "$STATE_DIR"
	exec 9>"$LOCK_FILE"
	flock -n 9 || die "another lifecycle operation is running"
	"$@"
}

main() {
	local action="${1:-}"
	shift || true
	case "$action" in
		check) check ;;
		build)
			case "${1:-}" in
				"") build_local ;;
				--docker)
					[[ "$#" -eq 1 ]] || die "build --docker accepts no extra arguments"
					build_docker
					;;
				--full)
					[[ "$#" -eq 1 ]] || die "build --full accepts no extra arguments"
					with_lock build_full
					;;
				*) die "unknown build option: ${1}" ;;
			esac
			;;
		start-custom|use-custom) with_lock start_custom ;;
		start-system|use-system) with_lock start_system ;;
		takeover) with_lock takeover ;;
		sync-clients) sync_clients ;;
		stop) with_lock stop_all ;;
		stop-custom) with_lock stop_custom ;;
		restart-custom) "$0" stop; "$0" start-custom ;;
		status) status ;;
		logs) tail -n "${OLLAMA_NGRAM_LOG_LINES:-160}" "$LOG_FILE" ;;
		-h|--help) usage ;;
		*) usage >&2; die "unknown action: ${action:-<empty>}" ;;
	esac
}

main "$@"
