#!/bin/bash
# usage: install_image.sh <sha256:digest>  — pull nornir:cupy, verify digest, rebuild nornir-build when idle, report.
W=$1
# Busy = any python or nornir-build process in the container (pipelines run as `nornir-build ...`,
# `python -m nornir_buildmanager ...` or ad-hoc scripts). show_jobs also lists MQTT runs still "running" on this container.
busy(){ docker exec nornir-build bash -c 'ps -eo args | grep -qE "^([^ ]*/)?(python[0-9.]*|nornir-build) "'; }
show_jobs(){
  docker exec nornir-build bash -c 'ps -eo pid,etime,args | grep -E "^ *[0-9]+ +[-0-9:]+ ([^ ]*/)?(python[0-9.]*|nornir-build) " | grep -v forkserver | cut -c1-170'
  h=$(docker inspect nornir-build --format '{{.Config.Hostname}}')
  docker exec nornir-dashboard-mosquitto-1 sh -c 'timeout 5 mosquitto_sub -h localhost -t "nornir/run/+/meta" -W 4 2>/dev/null' |
    H="$h" python3 -c 'import json,os,sys
for l in sys.stdin:
    try: d=json.loads(l)
    except Exception: continue
    if d.get("status")=="running" and d.get("host")==os.environ["H"]: print("mqtt running:", d.get("run_id"), d.get("pipeline"), d.get("volumepath"))'
}
busy && { echo "ABORT busy (ask the owning sessions first):"; show_jobs; exit 2; }
pwsh -NoLogo -NoProfile -File /srv/docker/stack.ps1 nornir-build pull 2>&1 | tail -1
d=$(docker image inspect nornir:cupy --format '{{index .Config.Labels "org.opencontainers.image.revision"}} {{.RepoDigests}}'); echo "$d"
echo "$d" | grep -q "$W" || { echo "ABORT digest mismatch"; exit 3; }
for i in 1 2; do busy && { echo ABORT busy; exit 2; }
  pwsh -NoLogo -NoProfile -File /srv/docker/stack.ps1 nornir-build rebuild 2>&1 | tail -1; sleep 5
  img=$(docker inspect nornir-build --format '{{.Image}}'); echo "try $i: $img"; [ "$img" = "$W" ] && break; done
[ "$img" = "$W" ] || { echo "ABORT rebuild failed"; exit 4; }
timeout 180 bash -c 'until docker logs nornir-build 2>&1 | grep -q drop_sys_admin; do sleep 5; done'
docker inspect nornir-build --format '{{.State.Status}} {{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}'
docker exec nornir-build bash -c 'echo "offline: $(cat /run/nornir-offline-mounts | tr "\n" " ")"; echo "cifs: $(awk "\$3==\"cifs\"{print \$2}" /proc/mounts | tr "\n" " ")"; nvidia-smi -L | cut -c1-40; echo "forkservers: $(ps -eo args | grep -c "[f]orkserver")"'; true
