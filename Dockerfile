FROM ghcr.io/omnigres/omnigres-17 AS builder

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libgit2-dev \
    libssl-dev \
    libz-dev \
    postgresql-server-dev-17 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /omni_git
COPY . .

RUN make && make install

FROM ghcr.io/omnigres/omnigres-17

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgit2-1.5 \
    git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/lib/postgresql/17/lib/omni_git.so /usr/lib/postgresql/17/lib/
COPY --from=builder /usr/share/postgresql/17/extension/omni_git* /usr/share/postgresql/17/extension/

COPY docker-init.sh /docker-entrypoint-initdb.d/99-omni-git.sh

ENV POSTGRES_DB=omnigres
ENV POSTGRES_USER=omnigres
ENV POSTGRES_PASSWORD=omnigres
