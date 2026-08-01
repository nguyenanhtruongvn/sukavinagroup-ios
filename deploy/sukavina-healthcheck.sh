#!/usr/bin/env bash
set -u

PROJECT_DIR="${SUKAVINA_PROJECT_DIR:-/opt/projects/sukavina}"
cd "$PROJECT_DIR" || exit 1

for service in postgres api web; do
  container_id="$(docker-compose ps -q "$service" 2>/dev/null | head -n 1)"
  if [ -n "$container_id" ]; then
    state="$(docker inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
    [ "$state" = "running" ] && continue
    docker rm -f "$container_id" >/dev/null 2>&1 || true
  fi
  docker-compose up -d --no-build "$service" >/dev/null 2>&1 || true
done
