#!/usr/bin/env bash
# One-time host setup. Run as root with the reviewed deploy-backend.sh path.
set -Eeuo pipefail
source_script=${1:?path to deploy-backend.sh required}
[[ $EUID -eq 0 && -f "$source_script" ]] || exit 2
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y awscli curl ffmpeg libcairo2 libpango-1.0-0 libgif7 librsvg2-2
install -d -m 755 /opt/ecopin
install -o root -g root -m 755 "$source_script" /opt/ecopin/deploy-backend.sh
install -d -o ubuntu -g ubuntu -m 700 /home/ubuntu/ecopin-deploy /home/ubuntu/ecopin-deploy/releases \
    /home/ubuntu/ecopin_backend_node/.private
chmod 600 /home/ubuntu/ecopin_backend_node/.env
if [[ ! -e /home/ubuntu/ecopin_backend_node/.private/pre-cicd.env ]]; then
    install -o ubuntu -g ubuntu -m 600 /home/ubuntu/ecopin_backend_node/.env \
      /home/ubuntu/ecopin_backend_node/.private/pre-cicd.env
fi
systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service
echo 'Host prepared; current backend has not been restarted.'
