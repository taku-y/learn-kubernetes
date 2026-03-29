# ビルドステージ
FROM rust:slim AS builder
WORKDIR /app

# 依存クレートのキャッシュを先に構築
COPY Cargo.toml ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release

# 本番コードをビルド
COPY src ./src
RUN touch src/main.rs && cargo build --release

# 実行ステージ
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/minio-client /usr/local/bin/minio-client
CMD ["minio-client"]
