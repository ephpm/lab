<?php
/**
 * Multi-tenant wp-config.php for the scalebench wp-real workload.
 *
 * ONE shared WordPress core is served as N vhosts; the per-site divergence is
 * the database, provided by ePHPm (each Host → its own <db.dir>/<site>.db via
 * the ephpm/db-wordpress drop-in at wp-content/db.php). So a single seeded
 * install can be copied to all N sites — the ONLY thing that must not be baked
 * into the DB is the site URL, or WordPress would redirect every tenant to the
 * host it was installed under.
 *
 * The fix: derive WP_HOME / WP_SITEURL from the request Host at runtime. Now
 * one template database serves every vhost with no cross-host redirect.
 */

// The drop-in intercepts all DB access; these constants must exist but their
// values are unused (no real MySQL is contacted).
define('DB_NAME', 'wordpress');
define('DB_USER', 'root');
define('DB_PASSWORD', '');
define('DB_HOST', '127.0.0.1:3306');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

// Per-tenant URL from the request Host — the key to one-template-for-all-sites.
$__host = $_SERVER['HTTP_HOST'] ?? 'localhost';
define('WP_HOME',    'http://' . $__host);
define('WP_SITEURL', 'http://' . $__host);

// Benchmark determinism: no cron loopback, no external HTTP, no auto-update.
define('DISABLE_WP_CRON', true);
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_HTTP_BLOCK_EXTERNAL', true);
define('WP_DEBUG', false);

define('AUTH_KEY',         'scalebench-1');
define('SECURE_AUTH_KEY',  'scalebench-2');
define('LOGGED_IN_KEY',    'scalebench-3');
define('NONCE_KEY',        'scalebench-4');
define('AUTH_SALT',        'scalebench-5');
define('SECURE_AUTH_SALT', 'scalebench-6');
define('LOGGED_IN_SALT',   'scalebench-7');
define('NONCE_SALT',       'scalebench-8');

// The db-wordpress drop-in and its classes MUST live inside the docroot:
// multi-tenant mode sets open_basedir to <sites_dir>/<site> (+ the private temp
// dir), so a drop-in symlinked to a shared external path is denied and WordPress
// silently falls back to mysqli ("Error establishing a database connection").
// Point the drop-in at an autoloader that lives under this docroot.
define('EPHPM_DB_AUTOLOAD', __DIR__ . '/ephpm-db/autoload.php');

$table_prefix = 'wp_';

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
