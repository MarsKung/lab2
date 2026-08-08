# CVE-2026-31431 (Copy Fail) 靶機
# Ubuntu 22.04 — Python 3.10 內建，kernel 由宿主機（WSL2 6.6.87.2）提供
#
# 獨立版：容器自己產生 SSH key pair，玩家從 docker logs 取得私鑰。
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# ── 系統依賴 ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        python3 \
        python3-pip \
        openssh-server \
        iptables \
        git \
        bash \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir requests

# ── Node.js 24 + OpenClaw ─────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g openclaw@latest

# ── 使用者 ───────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash clawuser \
    && passwd -d clawuser

# ── Flag 2 (root:root 600) ───────────────────────────────────────
ARG FLAG2="FLAG{c0pyfail_v1a_llm_sk1ll_supply_ch41n}"
RUN echo "${FLAG2}" > /flag \
    && chmod 600 /flag \
    && chown root:root /flag

# ── /usr/bin/su 乾淨備份 ─────────────────────────────────────────
RUN su --version | grep -q util-linux \
        || ( echo "BUILD ABORTED: /usr/bin/su 已被 page cache 污染。" \
          && echo "請先在宿主機清除 page cache，然後用 --no-cache 重建。" \
          && exit 1 ) \
    && cp -a /usr/bin/su /opt/.su.pristine \
    && chown root:root /opt/.su.pristine \
    && chmod 0400 /opt/.su.pristine

# ── SSH ───────────────────────────────────────────────────────────
RUN mkdir -p /run/sshd /home/clawuser/.ssh \
    && chown clawuser:clawuser /home/clawuser/.ssh \
    && chmod 700 /home/clawuser/.ssh \
    && touch /home/clawuser/.ssh/authorized_keys \
    && chown clawuser:clawuser /home/clawuser/.ssh/authorized_keys \
    && chmod 600 /home/clawuser/.ssh/authorized_keys
COPY ssh/sshd_config /etc/ssh/sshd_config

# ── SFTP chroot ──────────────────────────────────────────────────
RUN mkdir -p /srv/openclaw/skills \
    && chown root:root /srv/openclaw \
    && chmod 755 /srv/openclaw \
    && chown clawuser:clawuser /srv/openclaw/skills \
    && chmod 755 /srv/openclaw/skills

COPY --chown=clawuser:clawuser skills/ /srv/openclaw/skills/
RUN cp -a /srv/openclaw/skills /opt/skills.pristine

# ── Workspace symlink ─────────────────────────────────────────────
RUN mkdir -p /home/clawuser/.openclaw/workspace \
    && chown -R clawuser:clawuser /home/clawuser/.openclaw \
    && ln -s /srv/openclaw/skills /home/clawuser/.openclaw/workspace/skills

# ── 啟動腳本 ─────────────────────────────────────────────────────
COPY start.sh /start.sh
COPY fix_openclaw_scopes.py /usr/local/bin/fix_openclaw_scopes.py
RUN chmod 755 /start.sh /usr/local/bin/fix_openclaw_scopes.py

EXPOSE 22
CMD ["/start.sh"]
