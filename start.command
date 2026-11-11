#!/bin/zsh
cd "$(dirname "$0")"
# 构建用的 Python ≥3.12 在 .venv;服务器本身 3.9+ 都能跑,但统一用 .venv 免得 PATH 不一致
if [ -x .venv/bin/python ]; then
  exec .venv/bin/python server.py "$@"
else
  exec python3 server.py "$@"
fi
