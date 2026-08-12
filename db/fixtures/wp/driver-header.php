<?php
/**
 * Plugin Name: ePHPm Lab — DB driver header
 * Description: Emits X-Db-Driver with the concrete wpdb class serving this
 * request. This is the gate that keeps the WordPress bridge lanes honest:
 * a "bridge" cell whose drop-in silently fell back to mysqli (wrong image,
 * missing [db.sqlite], classes not found) would otherwise benchmark the
 * wire path while wearing the bridge label. Stock wpdb reports "wpdb";
 * the ephpm/db-wordpress drop-in reports "Ephpm\Db\WordPress\Db".
 *
 * Installed as a mu-plugin in BOTH cells so its (trivial) cost is
 * identical on the two sides of the comparison.
 */

add_action( 'send_headers', static function () {
    global $wpdb;
    if ( ! headers_sent() && $wpdb instanceof wpdb ) {
        header( 'X-Db-Driver: ' . get_class( $wpdb ) );
    }
} );
