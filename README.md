# Axiom with Docker Compose

Runs Axiom on one machine against your AWS Glue catalog, OpenMetadata and Trino. Nothing else needs
to be installed apart from Docker.

| Runs here | Comes from your environment |
|---|---|
| Portal (nginx, also proxies the API at `/v1`) | AWS Glue catalog, S3 data, KMS keys |
| API and control-plane roles: relay, ingestor, scheduler, prober, dispatcher, context-sync | OpenMetadata (assets, columns, lineage, owners) |
| Workers: metadata, DataFusion, Trino | Trino (second engine) |
| PostgreSQL (Axiom's own database) | |
| LocalStack (Axiom's internal queues and event bus only) | |

New commits on Glue tables are found by **polling**: every 5 min for Tier-1 products, 15 min
for Tier 2, 1 h for Tier 3. Glue events are not needed. A table's poll and minimum run interval can
be changed with `PUT /v1/assets/{id}/triggering`.

## Images

The images are `axiom-control`, `axiom-worker` and `axiom-portal`, all in the public Docker Hub
repository `sapdas/axiom` as `control-<release>`, `worker-<release>` and `portal-<release>`, built
for arm64 (Apple Silicon and other ARM machines). They contain no configuration and no secrets;
everything comes from `.env` at run time.

These files are published to the public repository
[sapta-das/axiom-deploy](https://github.com/sapta-das/axiom-deploy) for every release, with
`.env.example` naming that release's images. Images are built and published from the (private)
source repository with `REPO=docker.io/sapdas/axiom scripts/push-images.sh` and then
`scripts/publish-deploy.sh <release>`.

## Run it

On the machine that runs Axiom, clone the public deployment repository (no login needed):

```bash
git clone https://github.com/sapta-das/axiom-deploy.git && cd axiom-deploy
cp .env.example .env && chmod 600 .env
openssl rand -hex 32   # → AXIOM_API_TOKEN
openssl rand -hex 24   # → POSTGRES_PASSWORD
$EDITOR .env           # AWS, OpenMetadata, Trino (the image lines are already set)
docker compose pull
docker compose up -d
docker compose ps      # migrate and queues show "exited (0)": they are one-off steps
```

Open <http://localhost:8080> (or `AXIOM_BIND`/`AXIOM_PORT` from `.env`), click **Token** and paste
`AXIOM_API_TOKEN`. API calls use the same token: `Authorization: Bearer <token>`.

`.env` is read by every container. Keep it private (`chmod 600`), out of git, and out of images.

Memory: the DataFusion worker may use `AXIOM_DF_MEMORY_BYTES` per query, and its spill space
(`AXIOM_SCRATCH_SIZE`) is held in RAM. With 8 GB available to Docker, 2 GB and 2g are a safe start;
OpenMetadata or Trino on the same machine need room too.

## What happens after the first start

1. `context-sync` copies the OpenMetadata assets in `OM_SCOPE`: tables, columns, owners, tags and
   lineage, including the SQL that builds each table.
2. `prober` checks that DataFusion (Glue + S3) and Trino can read each copied table. See
   **Platform** in the portal.
3. In the portal, create a data product for the tables you want to watch: **Products → New
   product**.
4. Open a dataset (**Datasets**, or from **Home**): profile it to get suggested rules from the
   schema, the SQL that builds it and the data, accept the ones you want, or add your own with
   **New rule** (including rules across tables and custom SQL). Rules run when new data is
   committed (on the next poll) or when you choose **Run now**.

## AWS permissions

The AWS credentials in `.env` need read access to the Glue tables and their data. For example:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables"],
      "Resource": ["arn:aws:glue:<region>:<account>:catalog",
                   "arn:aws:glue:<region>:<account>:database/<db>",
                   "arn:aws:glue:<region>:<account>:table/<db>/*"] },
    { "Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:aws:s3:::<lake-bucket>/<prefix>/*" },
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::<lake-bucket>" },
    { "Effect": "Allow", "Action": ["kms:Decrypt"], "Resource": "<key ARNs of SSE-KMS or Iceberg-encrypted tables>" }
  ]
}
```

With Lake Formation, also grant the principal `SELECT` (and `DESCRIBE`) on the tables. Axiom never
writes to your data.

## Logs

Every Axiom service writes its log to `logs/` next to `docker-compose.yml` on this machine, as well as to
`docker compose logs`:

| File | What it shows |
|---|---|
| `api.log` | API requests and every refused or failed one, with its error code |
| `context-sync.log` | OpenMetadata syncs: assets copied, changed, removed, errors |
| `prober.log`, `worker-*.log` | Reachability probes: can DataFusion and Trino read each table, and why not |
| `scheduler.log` | Polls, commit classifications (data / compaction / nothing new), deferred runs |
| `worker-<engine>.<date>.log` | Every execution: scope, the SQL run, metrics returned, errors, timing |
| `ingestor.log` | Results recorded, pass/fail per check, trust evaluations, incidents |
| `relay.log`, `dispatcher.log` | Events sent, notifications delivered (host only) |
| `portal-access.log`, `portal-error.log` | Portal and API requests through nginx |
| `doctor-<time>.txt` | Doctor reports |

Lines are JSON at debug detail (`AXIOM_LOG_LEVEL` in `.env` lowers it). They contain no
secrets and no data rows: SQL appears as compiled checks, results as counts and statistics.
Files rotate at 50 MB (10 kept) and daily for workers (14 kept).

## Getting help: send a support bundle

This machine only runs Axiom; fixes are made elsewhere and come back as new images and a new
commit. When something is wrong:

```bash
./collect-logs.sh     # in the folder with docker-compose.yml and .env
```

It writes `logs/axiom-support-<time>.tar.gz` with:
- versions: the git commit of these files, the image digests and Docker;
- container status;
- the doctor report, which checks every dependency (database, queues, AWS identity, Glue/S3/KMS
  on the copied tables, OpenMetadata, Trino) from inside the stack and lists failed and stuck
  executions;
- each container's output and all the log files.

It never includes `.env`. It removes the value of every secret in `.env` (tokens, passwords,
keys) from everything it collects, as well as anything shaped like a bearer token, JWT or AWS
access key. Look through it before sending it.

To check the dependencies on their own at any time: `docker compose run --rm --no-deps api doctor`.

## Applying a fix

```bash
git pull                      # the new compose file and settings template, if they changed
# set the three AXIOM_*_IMAGE lines in .env to the new release (as in .env.example)
docker compose pull
docker compose up -d          # migrations run first; data is kept
```

Compare `.env` with `.env.example` after pulling: new settings appear there first.

## Operating it

| Task | Command |
|---|---|
| Follow one part | `docker compose logs -f worker-datafusion` or `tail -f logs/scheduler.log` |
| Check every dependency | `docker compose run --rm --no-deps api doctor` |
| Support bundle | `./collect-logs.sh` |
| Upgrade | `git pull`, set the three `AXIOM_*_IMAGE` lines in `.env` to the new release, then `docker compose pull && docker compose up -d` (migrations run first) |
| Stop | `docker compose down` (data stays in the `pgdata` volume) |
| Remove everything, including Axiom's database | `docker compose down -v` |
| Back up Axiom's database | `docker compose exec postgres pg_dump -U axiom axiom > axiom.sql` |

LocalStack does not keep its queues across restarts. `docker compose up -d` recreates them (the
`queues` step). Messages in flight when LocalStack stops are lost: a lost commit classification is
retried after 10 minutes, but a lost run is not; those executions stay `queued`, so use **Run now**
on the affected datasets after such a restart.

## Limits of this deployment

- One shared API token instead of sign-in through your identity provider (OIDC is supported by the
  API; the portal's sign-in flow is not built yet).
- No telemetry stack (Prometheus, Grafana, tracing): logs and the doctor instead.
- Notifications (webhook, Slack) need the machine to reach those endpoints.
- Glue events are not used; polling finds commits.
