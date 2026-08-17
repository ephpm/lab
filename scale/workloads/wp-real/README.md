# wp-real — real WordPress on the per-site Turso path

This workload runs **real WordPress core** on ePHPm multi-tenancy: one shared
core served as N vhosts, each talking to its own per-site Turso database through
the [`ephpm/db-wordpress`](https://github.com/ephpm/db-wordpress) drop-in
(`wp-content/db.php` → `ephpm_db_*` SAPI functions → `<db.dir>/<site>.db`). No
mysqli, no socket, no external database.

## The one gotcha: the drop-in must live INSIDE the docroot

Multi-tenant mode confines every vhost with `open_basedir =
<sites_dir>/<site>` **+** the vhost's private temp dir (the #285 per-tenant
temp/session isolation). So a `wp-content/db.php` **symlinked to a shared
external checkout** (e.g. `/opt/db-wordpress/dropin/db.php`) is **denied** by
open_basedir — `require` fails, the drop-in does nothing, and WordPress silently
falls back to the stock mysqli `wpdb`, which then fails with *"Error
establishing a database connection."* (This is verified behaviour on v0.7.0, not
hypothetical.)

**Fix:** the drop-in **and its classes** must be real files under the docroot,
and `wp-config.php` points the drop-in at an in-docroot autoloader via
`EPHPM_DB_AUTOLOAD` (already set in this directory's `wp-config.php`). That is
exactly what `composer require ephpm/db-wordpress` does inside a normal WP tree —
the shared-symlink shortcut is the only thing that breaks.

## Assembling a wp-real docroot

```bash
WP=/root/wp-real-docroot                       # WSL-native, NOT /mnt/c
mkdir -p "$WP" && cd "$WP"
curl -sL https://wordpress.org/latest.tar.gz | tar xz --strip-components=1

# the ePHPm database drop-in + its classes, all INSIDE the docroot:
git clone https://github.com/ephpm/db-wordpress /tmp/db-wordpress
cp /tmp/db-wordpress/dropin/db.php "$WP/wp-content/db.php"     # real file, not a symlink
mkdir -p "$WP/ephpm-db/src"
cp /tmp/db-wordpress/src/*.php "$WP/ephpm-db/src/"
cat > "$WP/ephpm-db/autoload.php" <<'PHP'
<?php
require_once __DIR__ . '/src/DbOpsInterface.php';
require_once __DIR__ . '/src/SapiDbOps.php';
require_once __DIR__ . '/src/PdoSqliteDbOps.php';
require_once __DIR__ . '/src/Db.php';
PHP
#   (composer require ephpm/db-wordpress into the docroot works too — then the
#    drop-in finds wp-content/vendor/autoload.php and EPHPM_DB_AUTOLOAD is
#    unnecessary.)

# the multi-tenant, dynamic-host wp-config (one template serves every vhost;
# it already defines EPHPM_DB_AUTOLOAD = <docroot>/ephpm-db/autoload.php)
cp /path/to/multitenant-scalebench/workloads/wp-real/wp-config.php "$WP/wp-config.php"
```

Then point the sweep at it:

```bash
export WORKLOAD=wp-real WP_DOCROOT=$WP
export NS="10 50 100 250"                       # anchor at lower N
export CAPS="4096"
bash scripts/run_sweep.sh
```

`run_sweep.sh` seeds one install via `scripts/seed_wp_real.sh` (the WordPress web
installer over HTTP), then copies that site's closed Turso database file to all N
sites. Because `wp-config.php` derives `WP_HOME`/`WP_SITEURL` from the request
`Host`, the copied DB serves every vhost with no cross-host redirect. The sweep
also overrides the REST path to `/?rest_route=/wp/v2/posts` (WordPress
301-redirects `/wp-json`), so the mix stays 2xx.

## What "modest content" means here

A default `wp core install` ships one post (Hello World), one page (Sample
Page), and one comment. That is enough to drive the front page + a permalink +
a REST hit. The report labels the wp-real content level explicitly.
