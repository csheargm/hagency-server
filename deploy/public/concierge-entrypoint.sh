#!/bin/sh
# Concierge container entrypoint: log the vendor CLIs in with API keys (from env,
# never baked into the image), then run the Hagency concierge daemon.
set -eu
: "${HAGENCY_SERVER_URL:?}" "${HAGENCY_SERVER_NAME:?}" "${CONCIERGE_USER:?}"
PASSWORD_FILE=/run/secrets/concierge_password
[ -r "$PASSWORD_FILE" ] || { echo "concierge: missing $PASSWORD_FILE" >&2; exit 1; }
# Extra CA (only for TLS_MODE=internal local tests: Caddy's local root).
if [ -s /run/extra-ca/root.crt ]; then
    cat /etc/ssl/certs/ca-certificates.crt /run/extra-ca/root.crt > /tmp/ca-bundle.pem
    export SSL_CERT_FILE=/tmp/ca-bundle.pem
fi
# Hosted agents run on Ollama (no commercial API key): Codex's built-in OSS provider.
: "${OLLAMA_URL:?set OLLAMA_URL in .env}" "${OLLAMA_MODEL:?set OLLAMA_MODEL in .env}"
mkdir -p "$HOME/.codex"
cat > "$HOME/.codex/config.toml" <<CFG
model = "$OLLAMA_MODEL"
model_provider = "ollama"
[model_providers.ollama]
name = "Ollama"
base_url = "${OLLAMA_URL%/}/v1"
CFG
exec hagency agent concierge --home /home/agent/state \
    --server "$HAGENCY_SERVER_URL" --server-name "$HAGENCY_SERVER_NAME" \
    --username "$CONCIERGE_USER" --password-file "$PASSWORD_FILE" \
    --runtime codex --model "$OLLAMA_MODEL" \
    --daily-budget "${CONCIERGE_DAILY_TOKENS:-200000}" \
    --max-agents-per-user "${CONCIERGE_MAX_AGENTS_PER_USER:-1}"
