# shellcheck shell=bash
# Multisite (subdomain + domain-mapped) replica support for `build`. Gated behind
# MULTISITE=1 in the backup's meta.env; the single-site path is untouched.
#
# Mapping rule: read every network domain from sites.csv and swap only the TLD to
# .test, keeping the original host (shop.example.com -> shop.example.test). Handles
# subdomain AND mapped subsites uniformly, all resolve via dnsmasq *.test.

# Swap the TLD of a domain to .test.
_swap_tld() { printf '%s.test' "${1%.*}"; }

# Main (blog 1) production domain from sites.csv (first data row).
_ms_main_domain() { tail -n +2 "$1" 2>/dev/null | head -1 | cut -d, -f2; }

# "prod_domain local_domain" for every site in sites.csv (one per line).
_ms_pairs() { # sites.csv
  local d
  tail -n +2 "$1" 2>/dev/null | cut -d, -f2 | while IFS= read -r d; do
    [ -n "$d" ] && printf '%s %s\n' "$d" "$(_swap_tld "$d")"
  done
}

# The multisite wp-config defines (unindented). DOMAIN_CURRENT_SITE = main local host.
_ms_config_extra() { # main_local_domain subdomain_install(0/1)
  local sub=false; [ "$2" = "1" ] && sub=true
  cat <<EOF
define('WP_ALLOW_MULTISITE', true);
define('MULTISITE', true);
define('SUBDOMAIN_INSTALL', $sub);
define('DOMAIN_CURRENT_SITE', '$1');
define('PATH_CURRENT_SITE', '/');
define('SITE_ID_CURRENT_SITE', 1);
define('BLOG_ID_CURRENT_SITE', 1);
EOF
}

# Fix the network's domains with RAW SQL (no WP bootstrap needed) so wp-cli can then
# load the network — breaks the bootstrap chicken-and-egg. wp_site forced to the main
# local domain; each wp_blogs row to its swapped domain. Assumes the wp_ table prefix.
_ms_fix_domains() { # db_container main_local sites.csv
  local db="$1" main_local="$2" csv="$3"
  local sql="UPDATE wp_site SET domain='$main_local';" blog_id domain rest local_d
  while IFS=, read -r blog_id domain rest; do
    case "$blog_id" in ''|blog_id) continue ;; esac
    [ -n "$domain" ] || continue
    local_d="$(_swap_tld "$domain")"
    sql="$sql UPDATE wp_blogs SET domain='$local_d' WHERE blog_id=$blog_id;"
  done < "$csv"
  docker exec -i "$db" mariadb -h127.0.0.1 -uwordpress -pwordpress wordpress -e "$sql"
}

# Per-domain content rewrite across the network — each prod domain → its local .test.
# Covers http/https × plain/escaped × protocol-relative (same matrix as single-site).
_ms_rewrite_content() { # app_container sites.csv
  local app="$1" csv="$2"
  local wp=(docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes)
  local f=(--all-tables --skip-columns=guid)
  local prod local_d
  while read -r prod local_d; do
    [ -n "$prod" ] || continue
    "${wp[@]}" search-replace "https://$prod"      "http://$local_d"      "${f[@]}" || true
    "${wp[@]}" search-replace "http://$prod"       "http://$local_d"      "${f[@]}" || true
    "${wp[@]}" search-replace "https:\\/\\/$prod"  "http:\\/\\/$local_d"  "${f[@]}" || true
    "${wp[@]}" search-replace "http:\\/\\/$prod"   "http:\\/\\/$local_d"  "${f[@]}" || true
    "${wp[@]}" search-replace "//$prod"            "//$local_d"           "${f[@]}" || true
  done < <(_ms_pairs "$csv")
}

# Proxy route listing every local domain: Host(`a`) || Host(`b`) || …
_ms_write_route() { # client sites.csv
  local client="$1" csv="$2" dyn rule="" prod local_d
  dyn="$(_proxy_dynamic_dir)"; mkdir -p "$dyn"
  while read -r prod local_d; do
    [ -n "$local_d" ] || continue
    rule="${rule:+$rule || }Host(\`$local_d\`)"
  done < <(_ms_pairs "$csv")
  cat > "$dyn/$client.yml" <<EOF
http:
  routers:
    $client:
      rule: "$rule"
      entryPoints: [web]
      service: $client
  services:
    $client:
      loadBalancer:
        servers:
          - url: "http://wp_${client}_app:80"
EOF
}

# Add the known admin to EVERY blog as administrator, so the admin-bar "My Sites"
# menu lists all subsites (super-admin grants caps but not blog membership — without
# this the replica admin only sees the main site, unlike the production admin).
_ms_join_all_sites() { # app_container known_user sites.csv
  local app="$1" user="$2" csv="$3" ids
  ids="$(tail -n +2 "$csv" 2>/dev/null | cut -d, -f1 | grep -E '^[0-9]+$' | paste -sd, -)"
  [ -n "$ids" ] || return 0
  docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes \
    eval "\$u=get_user_by('login','$user'); if(\$u){ foreach([$ids] as \$bid){ add_user_to_blog(\$bid,\$u->ID,'administrator'); } }" \
    >/dev/null 2>&1 || true
}

# Ensure every local domain resolves (dnsmasq *.test covers all; else /etc/hosts each).
_ms_ensure_dns() { # sites.csv
  local prod local_d
  while read -r prod local_d; do
    [ -n "$local_d" ] && _ensure_local_dns "$local_d"
  done < <(_ms_pairs "$1")
}
