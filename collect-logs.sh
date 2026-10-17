#!/usr/bin/env bash
# Collect everything needed to diagnose this Axiom deployment into one file to send for support.
#
#   cd deploy/compose && ./collect-logs.sh            # → logs/axiom-support-<time>.tar.gz
#   TAIL=20000 ./collect-logs.sh                      # more container output per service
#
# Contents: versions (git commit, images, Docker), container status, the doctor report (every
# dependency checked from inside the stack), each service's output, and the service log files in
# ./logs. Never included: .env. Removed from everything: the values of every secret in .env, and
# anything shaped like a bearer token, JWT or AWS access key. Review the file before sending it.
set -euo pipefail
cd "$(dirname "$0")"

tail_lines=${TAIL:-5000}
log_dir=${AXIOM_LOG_PATH:-./logs}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
name="axiom-support-$stamp"
out="$log_dir/$name"
mkdir -p "$out/compose" "$out/files"

step() { printf '• %s\n' "$*"; }

step "versions"
{
  echo "collected: $stamp"
  echo "host: $(uname -srm)"
  echo "docker: $(docker version --format '{{.Server.Version}} (server), {{.Client.Version}} (client)' 2>&1)"
  echo "compose: $(docker compose version --short 2>&1)"
  echo "repo commit: $(git rev-parse HEAD 2>&1) ($(git rev-parse --abbrev-ref HEAD 2>&1))"
  echo "repo changes:"; { git status --short 2>&1 || true; } | sed 's/^/  /'
  echo; echo "images:"
  docker compose images 2>&1 | sed 's/^/  /'
  echo; echo "image digests:"
  for img in $(docker compose config --images 2>/dev/null | sort -u); do
    echo "  $img → $(docker image inspect --format '{{join .RepoDigests ", "}} {{.Architecture}} created {{.Created}}' "$img" 2>&1)"
  done
} > "$out/versions.txt" 2>&1

step "container status"
docker compose ps -a > "$out/ps.txt" 2>&1 || true

step "settings (names; values only for non-secrets)"
shown='^(AXIOM_ENV|AXIOM_AWS_REGION|AWS_REGION|AXIOM_GLUE_CATALOG_ID|AXIOM_TRINO_ENDPOINT|AXIOM_TRINO_CATALOG|AXIOM_TRINO_USER|OM_BASE_URL|OM_SCOPE|OM_FRESHNESS_BUDGET_S|OM_RECONCILE_INTERVAL_S|AXIOM_BIND|AXIOM_PORT|AXIOM_PORTAL_URL|AXIOM_[A-Z]+_IMAGE|AXIOM_REGISTRY|AXIOM_VERSION|AXIOM_LOG_LEVEL|AXIOM_DF_MEMORY_BYTES|AXIOM_SCRATCH_SIZE|AXIOM_API_TOKEN_SUBJECT)$'
if [[ -f .env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# || "$line" != *=* ]] && continue
    key=${line%%=*}; value=${line#*=}
    if [[ "$key" =~ $shown ]]; then echo "$key=$value"
    elif [[ -n "$value" ]]; then echo "$key=(set)"
    else echo "$key=(empty)"; fi
  done < .env > "$out/settings.txt"
else
  echo "no .env next to docker-compose.yml" > "$out/settings.txt"
fi

step "doctor (checks every dependency from inside the stack; up to 2 minutes)"
docker compose run --rm --no-deps -T api doctor > "$out/doctor.txt" 2>&1 \
  || echo "(doctor exited with $?: see the FAIL lines above)" >> "$out/doctor.txt"

step "container output (last $tail_lines lines each)"
for svc in $(docker compose config --services); do
  docker compose logs --no-color --timestamps --tail "$tail_lines" "$svc" > "$out/compose/$svc.log" 2>&1 || true
done

step "service log files"
find "$log_dir" -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.*' -o -name 'doctor-*.txt' \) \
  -exec cp {} "$out/files/" \; 2>/dev/null || true

step "removing secrets"
secrets_file=$(mktemp)
trap 'rm -f "$secrets_file"' EXIT
if [[ -f .env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# || "$line" != *=* ]] && continue
    key=${line%%=*}; value=${line#*=}
    value=${value%\"}; value=${value#\"}; value=${value%\'}; value=${value#\'}
    [[ "$key" =~ _SUBJECT$ || -z "$value" ]] && continue   # names, not secrets
    if [[ "$key" =~ (TOKEN|SECRET|PASSWORD|PASS|KEY|JWT|CREDENTIAL) ]]; then
      if (( ${#value} >= 8 )); then
        printf '%s\t%s\n' "$key" "$value" >> "$secrets_file"
      else
        # Too short to remove without mangling ordinary words; use longer secrets.
        echo "  warning: $key is shorter than 8 characters and was not scrubbed; check the bundle" >&2
      fi
    fi
  done < .env
fi
SECRETS_FILE="$secrets_file" find "$out" -type f -exec perl -i -pe '
  BEGIN {
    open(my $f, "<", $ENV{SECRETS_FILE}) or die;
    while (<$f>) { chomp; my ($k, $v) = split /\t/, $_, 2; push @s, [$k, $v] if defined $v; }
    @s = sort { length($b->[1]) <=> length($a->[1]) } @s;
  }
  for my $p (@s) { my ($k, $v) = @$p; s/\Q$v\E/[REDACTED $k]/g; }
  s/(Bearer\s+)[A-Za-z0-9._~+\/=-]{16,}/$1\[REDACTED]/gi;
  s/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[REDACTED JWT]/g;
  s/\b((?:AKIA|ASIA)[A-Z0-9]{12})[A-Z0-9]{4}\b/$1****/g;
' {} +

tar -czf "$log_dir/$name.tar.gz" -C "$log_dir" "$name"
rm -rf "$out"
size=$(du -h "$log_dir/$name.tar.gz" | cut -f1)
echo
echo "Created $log_dir/$name.tar.gz ($size)."
echo "Review it before sending: tar -xzf $log_dir/$name.tar.gz -C /tmp && less /tmp/$name/doctor.txt"
