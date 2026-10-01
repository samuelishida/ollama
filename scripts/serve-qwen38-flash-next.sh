#!/usr/bin/env bash
set -euo pipefail

# Direct-NVMe launcher for AtomicChat's sharded Qwen3.8-Flash-Next target.
# This bypasses Ollama's model store; llama-server opens GGUF shards in place.
# No external draft/speculative model is used.

MODEL_DIR="${QWEN38_FLASH_MODEL_DIR:-/home/smk/models/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64}"
TARGET_MODEL="${QWEN38_FLASH_TARGET:-$MODEL_DIR/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64-00001-of-00028.gguf}"
SERVER="${QWEN38_FLASH_SERVER:-/home/smk/llama.cpp-qwen4exp-mtp/build/bin/llama-server}"
BACKEND="${QWEN38_FLASH_BACKEND:-/home/smk/llama.cpp-qwen4exp-mtp/build/bin/libggml-vulkan.so}"
HOST="${QWEN38_FLASH_HOST:-127.0.0.1}"
# 11436 collided with the AEye Intel-iGPU ollama instances (which now own 11436
# and 11437), so the default moved to 11438. Override with QWEN38_FLASH_PORT.
PORT="${QWEN38_FLASH_PORT:-11438}"
CTX="${QWEN38_FLASH_CTX:-192000}"
GPU_LAYERS="${QWEN38_FLASH_NGL:-99}"
CPU_MOE_LAYERS="${QWEN38_FLASH_CPU_MOE:-32}"
THREADS="${QWEN38_FLASH_THREADS:-6}"
BATCH="${QWEN38_FLASH_BATCH:-1024}"
UBATCH="${QWEN38_FLASH_UBATCH:-512}"
VISIBLE_DEVICES="${GGML_VK_VISIBLE_DEVICES:-1}"

die() {
	echo "[qwen38-flash] $*" >&2
	exit 1
}

[[ -x "$SERVER" ]] || die "server not executable: $SERVER"
[[ -f "$BACKEND" ]] || die "Vulkan backend not found: $BACKEND"
[[ -f "$TARGET_MODEL" ]] || die "target shard missing: $TARGET_MODEL"
[[ "$CTX" =~ ^[1-9][0-9]*$ ]] || die "invalid context: $CTX"

native_dir="$(dirname -- "$SERVER")"
library_path="$native_dir:$native_dir/vulkan"
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
	library_path="$library_path:$LD_LIBRARY_PATH"
fi

args=(
	--host "$HOST"
	--port "$PORT"
	--alias "qwen3.8-flash-next"
	--model "$TARGET_MODEL"
	--gpu-layers "$GPU_LAYERS"
	--n-cpu-moe "$CPU_MOE_LAYERS"
	--ngram-on-disk
	--ngram-direct-io
	--ngram-io-threads 64
	--ngram-cache 0
	--flash-attn on
	--ctx-size "$CTX"
	--cache-type-k q4_0
	--cache-type-v q4_0
	--batch-size "$BATCH"
	--ubatch-size "$UBATCH"
	--threads "$THREADS"
	--threads-batch "$THREADS"
	--fit off
	--load-mode mmap
	--lazy-mode on
	--no-warmup
	--jinja
	--temperature 1
	--top-k 20
	--min-p 0
	--top-p 0.95
)

echo "[qwen38-flash] target=$TARGET_MODEL" >&2
echo "[qwen38-flash] context=$CTX kv=q4_0/q4_0 gpu_layers=$GPU_LAYERS cpu_moe=$CPU_MOE_LAYERS" >&2
echo "[qwen38-flash] spec=disabled; built-in PLE=on-disk/direct-io/cache-0" >&2
echo "[qwen38-flash] endpoint=http://$HOST:$PORT" >&2

# qwen4exp quantized-KV activation rotation is unsupported by this path.
# Keep model mmap-backed for ordinary tensors. Explicit qwen4exp ngram-on-disk
# mode keeps per_layer_token_embd out of RAM/page cache and reads gathered rows
# from NVMe with direct I/O. --load-mode none would defeat ordinary mmap use.
exec env \
	LLAMA_ATTN_ROT_DISABLE="${LLAMA_ATTN_ROT_DISABLE:-1}" \
	GGML_VK_VISIBLE_DEVICES="$VISIBLE_DEVICES" \
	LD_LIBRARY_PATH="$library_path" \
	"$SERVER" "${args[@]}"
