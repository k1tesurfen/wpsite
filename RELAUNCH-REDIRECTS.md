# Relaunch redirects with wpsite

A runbook for carrying the **old URLs into a relaunched site** as `.htaccess` redirects,
using `wpsite redirect`. The flow is: **build a URL inventory → map old → new in the Google
Sheet → export CSV → import with wpsite → verify → monitor.**

The hard part isn't the import — it's the *reconnaissance*: knowing **which old URLs actually
matter** (are indexed, get traffic, have backlinks) so you redirect those and don't waste
effort on dead ones. Step 1 is the meat of this guide.

---

## 0. Prerequisites

- The client is onboarded in the shared registry (`mandos client add …`) and reachable:
  ```bash
  wpsite test <client>     # SSH + wp_root + WP-CLI/DB must be green
  ```
- You know the **live domain** and can reach **Google Search Console (GSC)** for it. GSC is the
  single most important source below — if the client hasn't verified the property, do that first
  (it can take a day for data to populate, so start early).

---

## 1. Reconnaissance — build the "old URL" inventory

No single source is complete. Pull from several, then merge + dedupe. In rough priority order:

### 1a. Google Search Console — *what Google actually indexed & serves* (primary)
This is the authoritative answer to your question ("which URLs does Google present?").

1. **Indexing → Pages** report → click **"Indexed"** → **Export** (top-right). This is the set
   Google currently serves in results.
2. **Performance → Search results** → **Pages** tab → set the date range to **16 months** (the
   max) → **Export**. These are URLs that earned **impressions/clicks** — i.e. the ones a lost
   redirect would actually hurt. Sort by clicks/impressions; the top of this list is your
   must-redirect set.

> GSC gives **full URLs**. You'll strip the domain to a **path** for the CSV `source` (§2).

### 1b. Current XML sitemap — *what the old site publishes*
```bash
# Try the usual locations; Yoast/RankMath expose a sitemap index of sub-sitemaps.
curl -s https://<domain>/sitemap_index.xml
curl -s https://<domain>/sitemap.xml
```
Extract every `<loc>` URL. This catches published pages that may have few clicks but still exist.

### 1c. Crawl the live site — *what's linked* (Screaming Frog or similar)
Point [Screaming Frog SEO Spider](https://www.screamingfrog.co.uk/seo-spider/) at the live domain
and crawl. The free tier covers 500 URLs (enough for most sites). Export the **Internal → HTML**
list of 200-OK URLs. Bonus: connect Frog to the **GSC and GA4 APIs** and it will pull
clicks/impressions/sessions per URL into one sheet — a shortcut for 1a + 1e.

### 1d. Server access logs — *real hits, incl. bookmarks & external links* (optional, via SSH)
A crawl only finds *linked* URLs. The logs show everything actually requested, including deep
links from other sites and bookmarks. You already have SSH:
```bash
# adjust the log path per host (Apache combined format assumed)
wpsite test <client>   # confirms the SSH target
ssh <ssh-target> "awk '{print \$7}' /var/www/logs/access.log | sort | uniq -c | sort -rn | head -300"
```
Keep the frequently-hit paths that aren't already in your list.

### 1e. Analytics — *top organic landing pages* (optional)
In **GA4** (or Matomo): *Engagement → Landing page*, last 12 months, sort by sessions. Export the
top landing pages — these are entry points people reach from Google/links and must survive.

### 1f. Backlinks — *pages with external link equity* (optional, if you have the tool)
In **Ahrefs / SEMrush**: *Top pages by backlinks* (or "Best by links"). A relaunch that breaks a
heavily-linked URL throws away ranking. These get priority targets even if traffic is modest.

### 1g. Existing Redirection plugin — *redirects the old site already had*
If the old site uses the **Redirection** plugin, don't re-key those by hand — wpsite reads them
straight off production in Step 3 (`wpsite redirect migrate`). Just note that they exist so you
don't duplicate them in the sheet.

### Consolidate
Paste all sources into one working sheet, **dedupe by URL**, and **sort by clicks/impressions**
(then backlinks). Now you have a prioritized list of old URLs. You do **not** need a redirect for
every URL — focus on: indexed + traffic + backlinks. Truly dead/zero-signal URLs can be left to
404 (that's a valid outcome; a 404 is better than a misleading redirect).

---

## 2. Build the redirect map (the Google Sheet → CSV)

For each old URL that matters, decide the **new target**. Fill the blueprint sheet with these
columns (this is exactly what wpsite imports):

| Column   | Meaning | Example |
|----------|---------|---------|
| `source` | **Old path** (domain stripped, leading slash). | `/alte-produktseite` |
| `target` | New path, **or** a full URL for external. | `/produkte/neu` · `https://shop.example/x` |
| `code`   | HTTP status. Relaunch = **301** (permanent). `302` only for temporary. | `301` |
| `regex`  | `0` = exact path (normal). `1` = the source is a regex pattern. | `0` |

The Google Sheet's **first row must be the header** `source,target,code,regex` (wpsite
auto-detects and skips it). Then **File → Download → Comma-separated values (.csv)**.

### Mapping rules of thumb
- **Map to the closest equivalent page.** A discontinued product → its category or successor, not
  the homepage. Redirecting everything to `/` reads as a soft-404 to Google and loses the ranking.
- **301 for relaunches** — it passes ranking signals to the new URL.
- **No chains, no loops.** Point each old URL *directly* at the final target. Never `source == target`.
- **One row per old URL.** If duplicates sneak in, the *last* one wins on import.
- **Paths, not full URLs, in `source`** — strip `https://<domain>`; keep everything from the first
  `/`. Drop `?query=strings` (see the skipped note below).
- **Use `regex: 1` sparingly** — e.g. move a whole tree: `source ^/blog/(.*)$`, `target /news/$1`,
  `regex 1`. Author your own anchors; migrated regex is emitted case-sensitive (add `(?i)` if needed).

### What wpsite will skip (and tell you about)
On import/migrate, rows that can't become a plain rule are written to
`<base_dir>/clients/<client>/redirects/<timestamp>.skipped.txt` with a reason — handle these by
hand. They are: a **literal source containing `?`** (query string — needs a `RewriteCond`), an
**empty target**, and (from `migrate`) plugin redirects with **conditional/complex match types**
(cookie/header/login/etc.). Commas inside a field are unsupported in v1.

---

## 3. Import into wpsite

Do this **once the relaunched site is the live site on the domain** (the redirects live in the
new site's `.htaccess`; the `source` paths are the old ones that no longer exist there).

### If the old site used the Redirection plugin — migrate first
```bash
wpsite redirect migrate <client>                       # pull all groups into the htaccess block
wpsite redirect migrate <client> --deactivate-plugin   # …and switch the plugin off afterwards
```

### Import the CSV
```bash
wpsite redirect import <client> /path/to/redirects.csv          # merge into the managed block
wpsite redirect import <client> /path/to/redirects.csv --replace # make the CSV the sole source
```
wpsite prints a summary and asks to confirm. It **backs up `.htaccess` first** (a remote `.bak`
plus a local copy under `…/clients/<client>/redirects/`), writes atomically, checks the home page
still responds, and **rolls back automatically on a server error** — so a bad rule can't strand
the site.

### Or via the GUI
Select the client → the **"Weiterleitungen"** card → **CSV importieren** (file picker) or **Aus
Redirection-Plugin übernehmen**. The current rules show in a table; you can add single ones inline
and remove rows with 🗑. (Same backup/verify/rollback under the hood.)

---

## 4. Verify

```bash
wpsite redirect list <client>          # what's now in the managed block
# spot-check a few high-value old URLs actually 301 to the right place:
curl -sI https://<domain>/alte-produktseite | grep -iE 'HTTP/|location'
#   expect:  HTTP/… 301
#            location: https://<domain>/produkte/neu
```
Check a couple from your top-clicks list, one external target, and any regex rule.

---

## 5. Post-launch monitoring (the feedback loop)

1. **Submit the new sitemap** in GSC (Sitemaps → add `sitemap_index.xml`).
2. Over the next few weeks watch **GSC → Indexing → Pages → "Not found (404)"** and the
   **Page Indexing** report. Any old URL that shows up as a 404 and still matters is a redirect
   you missed — add it:
   ```bash
   wpsite redirect add <client> /missed-url /correct-target      # quick single add
   ```
   or append to the sheet and re-import.
3. Confirm the `…/redirects/<timestamp>.skipped.txt` entries from Step 3 were each handled.

---

## Cheat sheet

```bash
wpsite test <client>                                   # 0. SSH/WP reachable?
wpsite redirect migrate <client> --deactivate-plugin   # 3. (only if old Redirection plugin)
wpsite redirect import  <client> redirects.csv          # 3. import the mapped CSV
wpsite redirect list    <client>                        # 4. verify
wpsite redirect add     <client> /old /new              #    one-off / a missed URL later
wpsite redirect remove  <client> /old                   #    drop one
```

CSV header: `source,target,code,regex` — old path → new path/URL, `301`, `0` (or `1` for regex).
Reconnaissance priority: **GSC (indexed + performance/pages) → sitemap → crawl → logs/analytics/backlinks.**
