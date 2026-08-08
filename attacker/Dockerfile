FROM alpine:3.20

RUN apk add --no-cache \
        bash \
        curl \
        jq \
        openssh-client \
        python3 \
        py3-requests \
        netcat-openbsd \
        vim \
        less \
        coreutils

COPY motd /etc/motd
RUN printf '%s\n' \
        'cat /etc/motd' \
        'export PS1="\[\e[1;31m\]attacker\[\e[0m\]:\w\$ "' \
        > /root/.bashrc

WORKDIR /work
ENV SHELL=/bin/bash
