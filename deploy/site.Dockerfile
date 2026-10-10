# reflex.farm: the website and Sparkle's appcast, served by Caddy.
# Built by Railway from the repo root (RAILWAY_DOCKERFILE_PATH=deploy/site.Dockerfile).
FROM caddy:2.8.4-alpine
COPY deploy/Caddyfile /etc/caddy/Caddyfile
COPY site/ /srv/
