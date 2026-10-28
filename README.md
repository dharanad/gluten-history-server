# dpas-history-server

Spark History Server with Gluten (Velox) support.

Runs the Spark History Server in Docker to view Spark event logs. The Gluten Velox bundle jar is on its classpath, so each application also gets a **Gluten** tab in the UI.

The image only provides the runtime: Debian 12 (x86_64), Java 17 and `tini`. The Spark distribution, Gluten jar, config and event logs are bind-mounted from this directory. You can swap any of them with a restart and never need to rebuild the image.

## Layout

```
.
├── Dockerfile            # Debian 12 + Java 17 runtime only
├── docker-compose.yml    # ports + bind mounts
├── dist/spark/           # Spark distribution, extracted here (git-ignored, not in the image)
├── conf/                 # mounted as $SPARK_HOME/conf
│   └── spark-defaults.conf
├── jars/                 # Gluten bundle + GCS connector jars, added to the History Server classpath
└── event-logs/           # local Spark event logs to browse
```

| Host path | Container path | Notes |
|---|---|---|
| `./dist/spark` (or `$SPARK_DIST`) | `/opt/spark` | read-only |
| `./conf` | `/opt/spark/conf` | read-only; replaces the distribution's own `conf/` |
| `./jars` | `/opt/extra-jars` | read-only; on the classpath via `SPARK_DAEMON_CLASSPATH=/opt/extra-jars/*` |
| `./event-logs` | `/opt/event-logs` | default `spark.history.fs.logDirectory` (see `EVENT_LOG_DIR`) |
| `~/.config/gcloud` (or `$GCLOUD_CONFIG_DIR`) | `/root/.config/gcloud` | read-only; GCP credentials for `gs://` paths |
| named volume `history-store` | `/opt/history-store` | `spark.history.store.path`; RocksDB cache of parsed apps, kept across restarts |

## Requirements

- Docker. The image is `linux/amd64`.
- Spark **Distribution built for Scala 2.13** (`spark-3.5.2-bin-hadoop3-scala2.13`). This must match the Gluten jar's `spark3.5.2_2.13` build.
- A Gluten bundle built for **Debian 12 / x86_64 / Java 17**. Its native libs need glibc ≥ 2.36, which is why the base image is Debian 12 and not Ubuntu 22.04 (glibc 2.35).

## First-time setup

1. Download the official Apache Spark release and its checksum, verify it and extract it into `./dist/spark`.
   Both files are git-ignored:
   ```bash
   curl -fLO https://archive.apache.org/dist/spark/spark-3.5.2/spark-3.5.2-bin-hadoop3-scala2.13.tgz
   curl -fLO https://archive.apache.org/dist/spark/spark-3.5.2/spark-3.5.2-bin-hadoop3-scala2.13.tgz.sha512
   shasum -a 512 -c spark-3.5.2-bin-hadoop3-scala2.13.tgz.sha512
   mkdir -p dist/spark && tar -xzf spark-3.5.2-bin-hadoop3-scala2.13.tgz -C dist/spark --strip-components=1
   ```
   If you already have the distribution elsewhere, skip this step and set `SPARK_DIST` (see below).
2. Put the Gluten bundle jar in `./jars/`. It is git-ignored (`jars/gluten-*.jar`). The GCS connector jar is committed.
3. Put event logs in `./event-logs/`. Plain and compressed (`.zstd`, `.lz4`, …) logs both work.
4. Build and start:
   ```bash
   docker compose up -d --build
   ```
5. Open http://localhost:18080.

## Day-to-day

| I want to… | Do this |
|---|---|
| Add or remove event logs | Drop files into `./event-logs/`. They are picked up within `spark.history.fs.update.interval` (10s). No restart. |
| Change History Server config | Edit `conf/spark-defaults.conf`, then `docker compose restart` |
| Update the Gluten jar | Replace the jar in `./jars/` (keep only one Gluten jar there), then `docker compose restart` |
| Use a different Spark distribution | Replace `./dist/spark`, then `docker compose restart`. To point elsewhere: `SPARK_DIST=/path/to/spark docker compose up -d` |
| See logs | `docker compose logs -f` |
| Read event logs from GCS | `EVENT_LOG_DIR=gs://bucket/path docker compose up -d` (see [Reading event logs from GCS](#reading-event-logs-from-gcs)) |
| Give the server more heap for big logs | `export SPARK_DAEMON_MEMORY=8g` then `docker compose up -d` |
| Stop | `docker compose down` (add `-v` to also wipe the parsed-app cache) |

Rebuild (`docker compose up -d --build`) only when the `Dockerfile` itself changes.

### Settings

Compose variables go in your shell or in a `.env` file next to `docker-compose.yml`:

| Variable | Default | Purpose |
|---|---|---|
| `EVENT_LOG_DIR` | `file:///opt/event-logs` (the mounted `./event-logs`) | `spark.history.fs.logDirectory`; can be `gs://bucket/path` |
| `SPARK_DIST` | `./dist/spark` | Spark distribution to mount |
| `GCLOUD_CONFIG_DIR` | `~/.config/gcloud` | gcloud config dir with `application_default_credentials.json` |
| `SPARK_DAEMON_MEMORY` | `4g` | History Server JVM heap (`-Xmx`); raise to 8g+ for very large logs |

Everything else lives in `conf/spark-defaults.conf`: update interval, UI port, GCS settings and the store settings below.

## Large event logs

There are two settings to tune:

- **Heap:** `SPARK_DAEMON_MEMORY` (default `4g`). The Docker VM must have more memory than this. Check it in Docker Desktop → Settings → Resources.
- **Hybrid store** (`conf/spark-defaults.conf`): each app is parsed into memory first and then dumped to a RocksDB store on disk (`/opt/history-store`). The heap therefore doesn't have to hold every app at once, and an app that has been parsed isn't re-parsed after a restart.

  | Setting | Value | Notes |
  |---|---|---|
  | `spark.history.store.path` | `/opt/history-store` | disk store location; required for the hybrid store |
  | `spark.history.store.maxDiskUsage` | `50g` | least recently used apps are evicted past this |
  | `spark.history.store.hybridStore.enabled` | `true` | |
  | `spark.history.store.hybridStore.maxMemoryUsage` | `1g` | in-memory parse budget. Keep it well below the heap. Apps that don't fit are parsed straight to disk |
  | `spark.history.store.hybridStore.diskBackend` | `ROCKSDB` | or `LEVELDB` |
  | `spark.history.store.serializer` | `PROTOBUF` | `JSON` (default) or `PROTOBUF`. There is no `KRYO` option, and the setting is not under `hybridStore.` |

  After changing store settings or upgrading Spark, wipe the cache with `docker compose down -v` so apps are re-parsed.

## Reading event logs from GCS

`jars/gcs-connector-3.1.20-shaded.jar` adds `gs://` support. This version is built against Hadoop 3.3.x, which matches Spark 3.5.2. Don't use connector 4.x, which targets Hadoop 3.4. `conf/spark-defaults.conf` already registers it, with `fs.gs.auth.type=APPLICATION_DEFAULT`.

1. Create Application Default Credentials on the host. This is a one-time step:
   ```bash
   gcloud auth application-default login
   ```
   `~/.config/gcloud` is mounted into the container, where ADC picks it up automatically.
   To use a service-account key instead, put the key under that directory and add
   `GOOGLE_APPLICATION_CREDENTIALS: /root/.config/gcloud/<key>.json` to the service's `environment` in `docker-compose.yml`.
2. Point the server at the bucket path, the directory that contains the event log files:
   ```bash
   EVENT_LOG_DIR=gs://my-bucket/spark-events docker compose up -d
   ```
   Or put `EVENT_LOG_DIR=gs://my-bucket/spark-events` in `.env`. Changing it needs `up -d`, not `restart`, because it changes the container's environment.
3. The account needs `storage.objects.list` and `storage.objects.get` on the bucket, e.g. `roles/storage.objectViewer`.

The History Server reads one log directory at a time. Unset `EVENT_LOG_DIR` to go back to `./event-logs`.

## Troubleshooting

- **No Gluten tab.** Check that the jar is in `./jars/` and that it is on the classpath:
  `docker exec dpas-history-server bash -c 'tr "\0" " " < /proc/$(pgrep -o java)/cmdline'`
  The output should contain `/opt/extra-jars/*`.
- **`Is a directory` / `start-history-server.sh: not found`.** `./dist/spark` is empty or wrongly nested. `./dist/spark/sbin/start-history-server.sh` must exist (use `--strip-components=1` when extracting).
- **GCS: `401`/`403` or `No FileSystem for scheme "gs"`.** Check `gcloud auth application-default print-access-token` on the host, check bucket permissions, and check that `jars/gcs-connector-*-shaded.jar` exists.
- **App missing from the list.** Look at `docker compose logs` for parse errors, and check that the file is readable and finished. An in-progress log ends in `.inprogress`.
- **Running Gluten queries (not just viewing logs) in this container** needs more than this setup provides. It needs the JVM `--add-opens` / `-Dio.netty.tryReflectionSetAccessible=true` options and any classes the bundle depends on, e.g. the spark-bigquery connector's repackaged Guava.
