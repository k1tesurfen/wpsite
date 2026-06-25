# wpsite Project Hand-off & Learnings

This document compiles key insights, user preferences, hoster quirks, and architectural solutions discovered and implemented during development. It serves as instructional context for future engineers and AI agents working on `wpsite`.

---

## 1. User & Tool Preferences

### A. Rehearsals Must Be Complete & Identical to Production
*   **The Policy**: We boot plugins and themes fully during local upgrades (`wpsite upgrade`). 
*   **Why**: Gating updates by skipping plugins (`--skip-plugins`/`--skip-themes`) is a "disaster waiting to happen." Rehearsals must load all active components so we can catch compatibility issues, fatal errors, and let third-party update checkers run natively before going live.
*   **The Upgrade Default**: Local upgrades now default to running with visual reviews and screenshots (`review=1` is mandatory by default), requiring the `--noreview` flag only to bypass it.

### B. Client-Facing Reports: Hard Facts Only
*   **The Policy**: The German client report (`wartungsbericht.txt` and `wartungsbericht.pdf`) must contain strictly structured technical facts with **zero conversational "email-like" fluff**.
*   **Structure**: 
    1.  Boxed WARTUNGSBERICHT header.
    2.  Structured `PROJEKT-DETAILS` (Client, Date/Time, HTTP 200 Confirmation).
    3.  Structured `DURCHGEFÜHRTE AKTUALISIERUNGEN` (WordPress Core, Plugins, Themes version diffs).
    4.  Structured `UNSERE QUALITÄTSSICHERUNG` checklist outlining the 5 maintenance stages.
    *   No greetings ("Sehr geehrte Damen und Herren"), no intros, and no signatures.

### C. Live SMTP Email Verification Natively
*   **The Policy**: At the end of a successful production deployment (`wpsite apply`), we automatically send a real test email through WordPress to verify the site's email capability.
*   **Implementation**: Done by dynamically looking up the site's `admin_email` on the live database and executing a native `wp eval` call:
    ```bash
    wp eval "exit(wp_mail('$admin_email', '[wpsite] E-Mail-Funktionstest...', '...') ? 0 : 1);"
    ```
    *This runs the actual `wp_mail()` function, forcing WordPress to load your active SMTP plugin (e.g., WP Mail SMTP) and verify its outbound mail delivery on production, while returning precise success/failure feedback.*

### D. Bulk Lifecycle Management
*   **The Policy**: Support a quick, clean way to halt all active replicas at once.
*   **Command**: `wpsite stop --all` loops over all configured clients and shuts down their containers natively (integrated as a single-click button under "Global Operations" inside the GUI).

---

## 2. Hoster-Specific Quirks & Solutions

### A. Mittwald Hosting (strict CLI ceilings & custom Bash wrappers)
*   **The Quirk**: On Mittwald and similar managed hosts, `/usr/local/bin/wp` is a **Bash script wrapper**, not a PHP file. 
*   **The Danger**: If you execute WP-CLI by forcing `php` to run on the wrapper path (e.g., `php $(which wp)` to apply memory overrides), the PHP engine interprets the Bash code as plain text, echoes it directly to stdout, and crashes.
*   **The Solution**: We implemented an atomic remote shell-type check inside `_prod_wp` over SSH:
    ```bash
    wp_bin=$(which wp 2>/dev/null || echo wp)
    if [ -f "$wp_bin" ] && head -n1 "$wp_bin" 2>/dev/null | grep -qE "sh|bash"; then
        # Run natively (the wrapper handles its own php limits)
        wp <args>
    else
        # Run with our performance overrides
        php -d memory_limit=512M -d max_execution_time=300 "$wp_bin" <args>
    fi
    ```

### B. WordPress Bootstrap Fatals inside local Replicas (The `aule` Plugin)
*   **The Quirk**: The active plugin `aule` calls the WordPress admin-only function `add_settings_error()` globally during the `plugins_loaded` hook. Because admin templates are not loaded on a standard frontend or WP-CLI boot, this crashes WP-CLI commands with an un-catchable Fatal Error.
*   **The Danger**: This blocked local rehearsals, causing the `wpsite upgrade` script to silently exit (due to `set -e` on subshell execution).
*   **The Solution**: We developed an automatic **Compatibility MU-Plugin** (`wp-content/mu-plugins/wpsite-compat.php`) that gets injected inside containers during build:
    ```php
    if (defined('WP_CLI') && WP_CLI) {
        if (!function_exists('add_settings_error')) {
            include_once ABSPATH . 'wp-admin/includes/template.php';
        }
    }
    ```
    *Using `include_once` on `template.php` loads the function early (satisfying custom plugin dependencies) and completely avoids "Cannot redeclare" compile fatals when WordPress core eventually loads `template.php` natively later in the cycle.*

### C. Bypass-Mailing Integrations (The WPO365 Plugin)
*   **The Quirk**: WPO365 (used on clients like `eabb`) does not use standard SMTP or PHPMailer. Instead, it hooks into `wp_mail()` and dispatches direct HTTP REST API calls to Microsoft Graph.
*   **The Danger**: Local SMTP traps (like our Mailpit container) only capture SMTP/PHPMailer traffic. WPO365 **completely bypasses Mailpit**, sending real emails to real recipients from your local staging replicas!
*   **The Guardrail**: When testing forms locally on `eabb`, **always manually change the notifications recipient address** to a safe, private testing email first, and be careful of background Wordfence alerts.

### D. Live Site Archiving Warnings (GNU Tar exit codes)
*   **The Quirk**: On active, high-traffic production sites, log or cache files inside `wp-content` frequently change sizes/modification times while `tar` is reading them.
*   **The Danger**: This causes `tar` to output `tar: file changed as we read it` and exit with status `1`. In standard bash scripts, `set -e` intercepts `1` as a fatal crash and aborts, leading to false-alarm backup failures.
*   **The Solution**: We updated the remote script to explicitly accept both `0` (clean success) and `1` (warning):
    ```bash
    tar -czf ... || [ $? -eq 1 ]
    ```
    *This lets warnings pass safely, while still correctly triggering `set -e` and aborting on real fatal issues like exit code `2` (out of space).*

---

## 3. Core Commands Cheat Sheet

*   **`wpsite test <client>`**: Real-time remote readiness check. Verifies SSH keys, remote commands (`tar`, `php`, `mysql`, `mysqldump`), remote `wp_root` existence, and runs a mock WP-CLI command to verify database connectivity.
*   **`wpsite stop --all`**: Halts all active local Docker replica containers at once.
*   **`wpsite upgrade <client> [--noreview]`**: Performs a local upgrade rehearsal on the replica (review is mandatory by default; `--noreview` skips screenshots and HTML visual comparison).
*   **`wpsite apply <client>`**: Runs production upgrades over SSH sequentially, wrapping them in native, database-free `.maintenance` locks and sending an automated transactional verification email on success.
