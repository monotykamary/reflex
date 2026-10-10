# reflex.farm: the website and Sparkle's appcast, served by Caddy.
# Built by Railway from the repo root (RAILWAY_DOCKERFILE_PATH=deploy/site.Dockerfile).
FROM caddy:2.8.4-alpine
COPY deploy/Caddyfile /etc/caddy/Caddyfile
COPY site/ /srv/
# The launch film plays live on the site: its page and its clock, no video file.
COPY film/launch.html film/grid.js /srv/film/
