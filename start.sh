#!/bin/bash
set -e

KEYS_DIR="/srv/keys"
AUTH_KEYS="/home/clawuser/.ssh/authorized_keys"

# ── 產生玩家 SSH key pair ────────────────────────────────────────
mkdir -p "$KEYS_DIR"
if [ ! -f "$KEYS_DIR/player_key" ]; then
    echo "[INFO] 產生玩家 SSH 金鑰..."
    ssh-keygen -t ed25519 -f "$KEYS_DIR/player_key" -N "" -C "lab2-player" -q
    chmod 600 "$KEYS_DIR/player_key"
    chmod 644 "$KEYS_DIR/player_key.pub"
fi
cp "$KEYS_DIR/player_key.pub" "$AUTH_KEYS"
chown clawuser:clawuser "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

echo "=========================================="
echo " Lab 2 玩家連線私鑰 (SFTP as clawuser)"
echo " sftp -i player_key -P ${LAB2_SSH_PORT:-2250} clawuser@localhost"
echo "=========================================="
cat "$KEYS_DIR/player_key"
echo "=========================================="

# ── Flag 1：寫入 SFTP chroot ────────────────────────────────────
: "${FLAG1:=FLAG_unset}"
printf '%s\n' "$FLAG1" > /srv/openclaw/flag1.txt
chown root:root /srv/openclaw/flag1.txt
chmod 444 /srv/openclaw/flag1.txt
echo "[INFO] flag1.txt written to /srv/openclaw/"

# ── 產生 sshd host keys ──────────────────────────────────────────
ssh-keygen -A -q

# ── 確認 chroot 目錄權限 ──────────────────────────────────────────
if [ "$(stat -c '%U:%G' /srv/openclaw)" != "root:root" ]; then
    echo "[ERROR] /srv/openclaw must be owned by root:root for sshd chroot"
    exit 1
fi

# ── 隔離 /usr/bin/su 的 page cache ───────────────────────────────
echo "[INFO] 隔離 /usr/bin/su page cache..."
if [ ! -r /opt/.su.pristine ]; then
    echo "[ERROR] 找不到 /opt/.su.pristine，請重新 build image"
    exit 1
fi
SU_INODE_BEFORE="$(stat -c %i /usr/bin/su)"
cp -a /opt/.su.pristine /usr/bin/.su.isolated
mv -f /usr/bin/.su.isolated /usr/bin/su
chown root:root /usr/bin/su
chmod 4755 /usr/bin/su
echo "[INFO] SU_ISOLATED inode ${SU_INODE_BEFORE} -> $(stat -c %i /usr/bin/su)"

# ── 確認 su 沒有被污染 ───────────────────────────────────────────
if [ "$(su - clawuser -c 'whoami' 2>/dev/null)" != "clawuser" ]; then
    echo "[ERROR] SU_POISONED — /usr/bin/su 已被污染（page cache poisoning）"
    echo "[ERROR] 請在宿主機執行以下指令清除 page cache："
    echo "[ERROR]   docker run --rm --privileged alpine sh -c \"sync; echo 3 > /proc/sys/vm/drop_caches\""
    echo "[ERROR]   docker compose build --no-cache"
    exit 1
fi
echo "[INFO] SU_INTEGRITY_OK"

# ── Copy Fail 環境驗證 ────────────────────────────────────────────
echo "[INFO] 驗證 Copy Fail 環境..."
python3 -c "
import socket
try:
    a = socket.socket(38, 5, 0)
    a.bind(('aead','authencesn(hmac(sha256),cbc(aes))'))
    a.close()
    print('[INFO] AF_ALG + authencesn OK')
except Exception as e:
    print(f'[WARN] AF_ALG 不可用: {e}')
    print('[WARN] 請確認：1) seccomp=unconfined  2) algif_aead 模組已載入')
" 2>&1 || true

python3 -c "
import os, sys
try:
    r, w = os.pipe()
    os.splice(r, w, 0)
    print('[INFO] os.splice() OK')
except AttributeError:
    print(f'[WARN] os.splice() 不存在（Python {sys.version}），需要 3.10+')
except Exception:
    print('[INFO] os.splice() 存在')
" 2>&1 || true

# ── API key 預檢 ─────────────────────────────────────────────────
LAB_MODEL_CHECK="${MODEL:-meta/llama-3.1-70b-instruct}"
if [ -z "${NVIDIA_API_KEY}" ]; then
    echo "[WARN] APIKEY_MISSING — 沒有設定 NVIDIA_API_KEY"
    echo "[WARN] 請在 .env 填入你的 key，再重啟容器"
    echo "[WARN] SFTP 與 exploit 部分仍可操作，但 LLM 觸發不會運作。"
else
    API_HTTP="$(curl -s -o /tmp/apicheck.json -w '%{http_code}' --max-time 45 \
        -X POST https://integrate.api.nvidia.com/v1/chat/completions \
        -H "Authorization: Bearer ${NVIDIA_API_KEY}" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${LAB_MODEL_CHECK}\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":2}" \
        2>/dev/null || echo "000")"
    case "$API_HTTP" in
        200)
            echo "[INFO] APIKEY_OK — ${LAB_MODEL_CHECK} 可用" ;;
        401|403)
            echo "[WARN] APIKEY_INVALID — key 被拒（HTTP ${API_HTTP}）" ;;
        429)
            echo "[WARN] APIKEY_RATELIMITED — 已達帳號額度（HTTP 429）" ;;
        503|000)
            echo "[WARN] MODEL_SATURATED — ${LAB_MODEL_CHECK} 無回應（HTTP ${API_HTTP}）" ;;
        *)
            echo "[WARN] APIKEY_UNKNOWN — HTTP ${API_HTTP}" ;;
    esac
    rm -f /tmp/apicheck.json
fi

# ── OpenClaw 初始化 ──────────────────────────────────────────────
OPENCLAW_HOME="/home/clawuser/.openclaw"
if [ ! -d "$OPENCLAW_HOME/agents/main" ]; then
    echo "[INFO] 首次啟動，執行 openclaw onboard..."
    su - clawuser -c "NVIDIA_API_KEY='${NVIDIA_API_KEY}' openclaw onboard --non-interactive --accept-risk --skip-health 2>&1 | tail -5"

    echo "[INFO] 注入 NVIDIA provider 設定..."
    su - clawuser -c "openclaw config set models.providers.nvidia '{
        \"baseUrl\": \"https://integrate.api.nvidia.com/v1\",
        \"api\": \"openai-completions\",
        \"apiKey\": {\"source\": \"env\", \"provider\": \"default\", \"id\": \"NVIDIA_API_KEY\"},
        \"models\": [
            {\"id\": \"openai/gpt-oss-20b\",          \"name\": \"GPT-OSS 20B\"},
            {\"id\": \"meta/llama-3.1-70b-instruct\", \"name\": \"Llama 3.1 70B Instruct\"},
            {\"id\": \"meta/llama-3.3-70b-instruct\", \"name\": \"Llama 3.3 70B Instruct\"},
            {\"id\": \"meta/llama-3.1-8b-instruct\",  \"name\": \"Llama 3.1 8B Instruct\"}
        ]
    }' --strict-json --replace 2>&1 | tail -3"

    echo "[INFO] 設定 agent 預設 model..."
    LAB_MODEL="${MODEL:-meta/llama-3.1-70b-instruct}"
    su - clawuser -c "openclaw config set agents.defaults.model 'nvidia/${LAB_MODEL}' 2>&1 | tail -3"
fi

# ── 啟動 OpenClaw Gateway ────────────────────────────────────────
rm -f /tmp/gateway.log
echo "[INFO] 啟動 OpenClaw Gateway..."
su - clawuser -c "NVIDIA_API_KEY='${NVIDIA_API_KEY}' nohup openclaw gateway run >/tmp/gateway.log 2>&1 &"

echo "[INFO] 等待 Gateway 就緒..."
GATEWAY_READY=0
for i in $(seq 1 90); do
    if grep -q "gateway] ready" /tmp/gateway.log 2>/dev/null; then
        echo "[INFO] Gateway ready after ${i}s"
        GATEWAY_READY=1
        break
    fi
    sleep 1
done

if [ "$GATEWAY_READY" != "1" ] || ! pgrep -u clawuser -f "openclaw" >/dev/null 2>&1; then
    echo "[WARN] GATEWAY_DEAD — Gateway 未成功啟動"
    tail -5 /tmp/gateway.log 2>/dev/null || true
else
    echo "[INFO] GATEWAY_ALIVE"
fi

# ── 修復 device scopes + 註冊 cron ───────────────────────────────
if pgrep -u clawuser -f "openclaw" >/dev/null 2>&1; then
    su - clawuser -c "openclaw cron list >/dev/null 2>&1 || true"
    su - clawuser -c "python3 /usr/local/bin/fix_openclaw_scopes.py 2>&1 | tail -3"

    CRON_NAME="weather-every-60s"
    if ! su - clawuser -c "openclaw cron list 2>/dev/null | grep -q '$CRON_NAME'"; then
        echo "[INFO] 註冊 weather cron job..."
        su - clawuser -c "openclaw cron add \
            --name '$CRON_NAME' \
            --cron '*/60 * * * * *' \
            --message '請使用 weather-reporter skill 回報目前台北天氣' \
            --timeout-seconds 600 \
            --no-deliver \
            2>&1 | tail -5" || echo "[WARN] cron add 失敗"
    fi
else
    echo "[WARN] 跳過 scope 修復與 cron 註冊（gateway 未運作）"
fi

# ── sshd 前景運行 ────────────────────────────────────────────────
echo "[INFO] SSHD_LISTENING — sshd 啟動於 port 22"
exec /usr/sbin/sshd -D -e
