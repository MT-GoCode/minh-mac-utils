/* nextdns_discipline.c — self-discipline NextDNS list manager.
 *
 * Compiled three ways:
 *   block:        cc -O2 -Wall -DMODE_BLOCK       -o nextdns-block       nextdns_discipline.c
 *   allow:        cc -O2 -Wall -DMODE_ALLOW       -o nextdns-allow       nextdns_discipline.c
 *   delay-allow:  cc -O2 -Wall -DMODE_DELAY_ALLOW -o nextdns-delay-allow nextdns_discipline.c
 *
 * Per domain (NextDNS API; 204 = success):
 *   block <d>  ->  DELETE allowlist/<d>   then  POST denylist  {"id":<d>,"active":true}
 *   allow <d>  ->  DELETE denylist/<d>    then  POST allowlist {"id":<d>,"active":true}
 *
 * We shell out to the system `curl` (which NextDNS's Cloudflare edge accepts) —
 * an in-process libcurl request is silently no-op'd (returns 204 but does not
 * persist). The API key is fed to curl via a stdin config (`-K -`), so it never
 * appears in argv / `ps` / the environment.
 *
 * Privileges:
 *   nextdns-block : setuid-root (mode 4711). Reads the root-only credentials,
 *                   then drops to the invoking user before running curl.
 *   nextdns-allow : mode 0700 root:wheel, NOT setuid; refuses unless EUID==0,
 *                   i.e. only via `sudo` (the admin/Pluckeye-gated escape).
 *   nextdns-delay-allow : setuid-root (4711). A NON-sudo self-serve allow that lands after 12h — the
 *                   wait IS the gate. Enqueue/status/abort run as any user (setuid lets them touch the
 *                   root-owned queue; they only ADD a delayed loosening or CANCEL one). The actual API
 *                   allow runs via `--apply`, gated on the REAL uid being root (getuid()==0), so only
 *                   the root LaunchDaemon (or sudo) applies — a user running the setuid binary can't.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>

#define CRED_FILE   "/usr/local/etc/nextdns-discipline/credentials"
#define API_BASE    "https://api.nextdns.io/profiles/"
#define CURL_BIN    "/usr/bin/curl"
#define MAX_DOMAIN  253
#define MAX_DOMAINS 8192

#ifdef MODE_BLOCK
#define ACTION_NAME "block"
#else
#define ACTION_NAME "allow"
#endif

static char g_apikey[256];
static char g_profile[64];
#ifndef MODE_DELAY_ALLOW
static char *g_domains[MAX_DOMAINS];
static int   g_ndomains = 0;
#endif

/* ----- validation ------------------------------------------------------- */

static int valid_domain(const char *d) {
    size_t n = strlen(d);
    if (n == 0 || n > MAX_DOMAIN) return 0;
    if (d[0] == '.' || d[0] == '-' || d[n - 1] == '-' || d[n - 1] == '.') return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)d[i];
        if (!(isalnum(c) || c == '.' || c == '-' || c == '_')) return 0;
    }
    return 1;
}

static int valid_profile(const char *p) {
    size_t n = strlen(p);
    if (n == 0 || n > 63) return 0;
    for (size_t i = 0; i < n; i++)
        if (!isalnum((unsigned char)p[i])) return 0;
    return 1;
}

/* ----- credentials (read while EUID==0) --------------------------------- */

static void load_credentials(void) {
    struct stat st;
    if (stat(CRED_FILE, &st) != 0) {
        fprintf(stderr, "error: cannot read %s (run the installer)\n", CRED_FILE);
        exit(1);
    }
    if (st.st_uid != 0) { fprintf(stderr, "error: %s must be owned by root\n", CRED_FILE); exit(1); }
    if (st.st_mode & (S_IRWXG | S_IRWXO)) {
        fprintf(stderr, "error: %s must be chmod 600 (no group/other access)\n", CRED_FILE);
        exit(1);
    }
    FILE *f = fopen(CRED_FILE, "r");
    if (!f) { fprintf(stderr, "error: cannot open %s\n", CRED_FILE); exit(1); }
    char line[512];
    while (fgets(line, sizeof line, f)) {
        char *nl = strpbrk(line, "\r\n");
        if (nl) *nl = '\0';
        if (strncmp(line, "API_KEY=", 8) == 0) snprintf(g_apikey, sizeof g_apikey, "%s", line + 8);
        else if (strncmp(line, "PROFILE=", 8) == 0) snprintf(g_profile, sizeof g_profile, "%s", line + 8);
    }
    fclose(f);
    if (!g_apikey[0] || !g_profile[0]) { fprintf(stderr, "error: credentials missing API_KEY or PROFILE\n"); exit(1); }
    if (!valid_profile(g_profile)) { fprintf(stderr, "error: PROFILE is malformed\n"); exit(1); }
    for (size_t i = 0; g_apikey[i]; i++)
        if ((unsigned char)g_apikey[i] <= ' ' || g_apikey[i] == 0x7f) {
            fprintf(stderr, "error: API_KEY is malformed\n"); exit(1);
        }
}

/* ----- one curl call; returns HTTP status (0 on transport failure) ------ */
/* The API key goes in via stdin (`-K -`), never argv. */

static long curl_call(const char *method, const char *url, const char *body) {
    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0) { perror("pipe"); return 0; }

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 0; }
    if (pid == 0) {                           /* child: become curl */
        dup2(in_pipe[0], 0);
        dup2(out_pipe[1], 1);
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, 2); close(dn); }
        char *av[20]; int n = 0;
        av[n++] = "curl";
        av[n++] = "-s";
        av[n++] = "-K"; av[n++] = "-";                 /* read auth headers from stdin */
        av[n++] = "-o"; av[n++] = "/dev/null";
        av[n++] = "-w"; av[n++] = "%{http_code}";
        av[n++] = "--max-time"; av[n++] = "20";
        if (strcmp(method, "GET") != 0) { av[n++] = "-X"; av[n++] = (char *)method; }
        if (body) { av[n++] = "-d"; av[n++] = (char *)body; }
        av[n++] = (char *)url;
        av[n] = NULL;
        execv(CURL_BIN, av);
        _exit(127);
    }

    close(in_pipe[0]); close(out_pipe[1]);
    char cfg[400];
    int cl = snprintf(cfg, sizeof cfg,
        "header = \"X-Api-Key: %s\"\nheader = \"Content-Type: application/json\"\n", g_apikey);
    for (int off = 0; off < cl; ) {
        ssize_t w = write(in_pipe[1], cfg + off, cl - off);
        if (w <= 0) break;
        off += (int)w;
    }
    close(in_pipe[1]);

    char buf[64]; size_t len = 0; ssize_t r;
    while ((r = read(out_pipe[0], buf + len, sizeof buf - 1 - len)) > 0) {
        len += (size_t)r;
        if (len >= sizeof buf - 1) break;
    }
    buf[len] = '\0';
    close(out_pipe[0]);
    int status; waitpid(pid, &status, 0);
    return strtol(buf, NULL, 10);
}

static int transient(long c) { return c == 0 || c == 429 || (c >= 500 && c < 600); }

static long call_retry(const char *method, const char *url, const char *body) {
    long c = 0;
    for (int attempt = 0; attempt < 4; attempt++) {
        c = curl_call(method, url, body);
        if (!transient(c)) break;
        sleep(attempt + 1);                    /* 1s, 2s, 3s backoff */
    }
    return c;
}

static int ok_add(long c) { return (c >= 200 && c < 300) || c == 409; }  /* 409 = already present */

static int do_domain(const char *d) {
    char url[512], body[320];
    snprintf(body, sizeof body, "{\"id\":\"%s\",\"active\":true}", d);
#ifdef MODE_BLOCK
    snprintf(url, sizeof url, "%s%s/allowlist/%s", API_BASE, g_profile, d);
    long rm  = call_retry("DELETE", url, NULL);            /* 404 = wasn't there, fine */
    snprintf(url, sizeof url, "%s%s/denylist", API_BASE, g_profile);
    long add = call_retry("POST", url, body);
    int ok = ok_add(add);
    printf("block  %-40s denylist+=%ld allowlist-=%ld  %s\n", d, add, rm, ok ? "OK" : "FAILED");
    return ok;
#else
    snprintf(url, sizeof url, "%s%s/denylist/%s", API_BASE, g_profile, d);
    long rm  = call_retry("DELETE", url, NULL);
    snprintf(url, sizeof url, "%s%s/allowlist", API_BASE, g_profile);
    long add = call_retry("POST", url, body);
    int ok = ok_add(add);
    printf("allow  %-40s allowlist+=%ld denylist-=%ld  %s\n", d, add, rm, ok ? "OK" : "FAILED");
    return ok;
#endif
}

/* ----- delayed allow: root-owned queue + periodic root applier ---------- */
/* nextdns-delay-allow enqueues {domain, apply_at} lines; a root LaunchDaemon runs `--apply` on a
 * timer and applies the ones whose time has come (reusing do_domain's allow path). The 12h wait is
 * the commitment device — impulse-you can queue a loosening, only calm-you-12h-later gets it. */
#ifdef MODE_DELAY_ALLOW
#ifndef QUEUE_FILE                 /* overridable at compile time for tests */
#define QUEUE_FILE    "/usr/local/etc/nextdns-discipline/delay-allow-queue"
#endif
#ifndef DELAY_SECONDS
#define DELAY_SECONDS (12L * 3600L)
#endif

struct qent { long apply_at; char domain[MAX_DOMAIN + 1]; };

/* Read the queue (missing = empty). Malformed lines are skipped, fail-closed. */
static int q_read(struct qent *e, int max) {
    FILE *f = fopen(QUEUE_FILE, "r");
    if (!f) return 0;
    int n = 0; char line[512];
    while (n < max && fgets(line, sizeof line, f)) {
        char *nl = strpbrk(line, "\r\n"); if (nl) *nl = '\0';
        if (line[0] == '\0' || line[0] == '#') continue;
        long t; char d[MAX_DOMAIN + 1];
        if (sscanf(line, "%ld %252s", &t, d) == 2 && valid_domain(d)) {
            e[n].apply_at = t; snprintf(e[n].domain, sizeof e[n].domain, "%s", d); n++;
        }
    }
    fclose(f);
    return n;
}

/* Atomic replace: tmp -> rename, forced root:wheel 0600 (the user can't tamper the queue directly). */
static int q_write(const struct qent *e, int n) {
    char tmp[600]; snprintf(tmp, sizeof tmp, "%s.tmp", QUEUE_FILE);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { perror("open queue"); return -1; }
    FILE *f = fdopen(fd, "w");
    if (!f) { close(fd); unlink(tmp); return -1; }
    for (int i = 0; i < n; i++) fprintf(f, "%ld %s\n", e[i].apply_at, e[i].domain);
    fflush(f);
    if (fchown(fileno(f), 0, 0) != 0) { /* best-effort; euid is root here */ }
    fchmod(fileno(f), 0600);
    fclose(f);
    if (rename(tmp, QUEUE_FILE) != 0) { perror("rename queue"); unlink(tmp); return -1; }
    return 0;
}

static void fmt_when(long t, char *out, size_t n) {
    time_t tt = (time_t)t; struct tm lt; localtime_r(&tt, &lt);
    strftime(out, n, "%a %Y-%m-%d %H:%M", &lt);
}

static int delay_status(void) {
    struct qent e[MAX_DOMAINS]; int n = q_read(e, MAX_DOMAINS);
    if (n == 0) { printf("delay-allow: nothing queued.\n"); return 0; }
    long now = (long)time(NULL);
    printf("delay-allow queue (%d):\n", n);
    for (int i = 0; i < n; i++) {
        long left = e[i].apply_at - now; if (left < 0) left = 0;
        char w[64]; fmt_when(e[i].apply_at, w, sizeof w);
        printf("  %-40s lands %s  (%ldh %ldm left)\n", e[i].domain, w, left / 3600, (left % 3600) / 60);
    }
    return 0;
}

/* Remove matching domains (or ALL if none named) — only ever tightens, so any user may. */
static int delay_abort(char **doms, int nd) {
    struct qent e[MAX_DOMAINS]; int n = q_read(e, MAX_DOMAINS);
    if (n == 0) { printf("delay-allow: nothing queued to abort.\n"); return 0; }
    int kept = 0, removed = 0;
    for (int i = 0; i < n; i++) {
        int drop = (nd == 0);
        for (int j = 0; j < nd; j++) if (strcmp(e[i].domain, doms[j]) == 0) { drop = 1; break; }
        if (drop) removed++; else e[kept++] = e[i];
    }
    if (q_write(e, kept) != 0) return 1;
    printf("delay-allow: aborted %d queued %s.\n", removed, removed == 1 ? "entry" : "entries");
    return 0;
}

static void delay_usage(void) {
    fprintf(stderr,
        "usage: nextdns-delay-allow <domain ...>    # queue an allow that lands in 12h (no sudo)\n"
        "       nextdns-delay-allow --status        # show queued allows + when they land\n"
        "       nextdns-delay-allow --abort [d ...]  # cancel queued allow(s); no name = all\n"
        "       nextdns-delay-allow --help\n"
        "  (status/abort/help also work without the leading --)\n");
}

static int delay_enqueue(char **doms, int nd) {
    for (int j = 0; j < nd; j++)
        if (!valid_domain(doms[j])) {
            fprintf(stderr, "error: not a valid domain: %s\n\n", doms[j]);
            delay_usage();
            return 2;
        }
    struct qent e[MAX_DOMAINS]; int n = q_read(e, MAX_DOMAINS);
    long apply_at = (long)time(NULL) + DELAY_SECONDS;
    int added = 0;
    for (int j = 0; j < nd; j++) {
        int dup = 0;
        for (int i = 0; i < n; i++) if (strcmp(e[i].domain, doms[j]) == 0) { dup = 1; break; }
        if (dup) { fprintf(stderr, "note: %s already queued — keeping its original landing time\n", doms[j]); continue; }
        if (n >= MAX_DOMAINS) { fprintf(stderr, "error: queue full\n"); break; }
        e[n].apply_at = apply_at; snprintf(e[n].domain, sizeof e[n].domain, "%s", doms[j]); n++; added++;
    }
    if (added == 0) { fprintf(stderr, "delay-allow: nothing new queued.\n"); return 1; }
    if (q_write(e, n) != 0) return 1;
    char w[64]; fmt_when(apply_at, w, sizeof w);
    printf("delay-allow: queued %d %s — allow lands %s (in 12h), NO sudo needed then.\n",
           added, added == 1 ? "domain" : "domains", w);
    printf("  view: nextdns-delay-allow --status    cancel: nextdns-delay-allow --abort [domain ...]\n");
    return 0;
}

/* Applied by the root LaunchDaemon on a timer. REAL-root only: a user running the setuid binary has
 * getuid()==501 and is refused, so only the daemon (or sudo) turns a queued entry into an API allow. */
static int delay_apply(void) {
    if (getuid() != 0) {
        fprintf(stderr, "nextdns-delay-allow --apply: real-root only (run by the daemon or via sudo)\n");
        return 1;
    }
    struct qent e[MAX_DOMAINS]; int n = q_read(e, MAX_DOMAINS);
    if (n == 0) return 0;
    long now = (long)time(NULL);
    int due = 0; for (int i = 0; i < n; i++) if (e[i].apply_at <= now) due++;
    if (due == 0) return 0;
    load_credentials();
    struct qent keep[MAX_DOMAINS]; int nk = 0, applied = 0, failed = 0;
    for (int i = 0; i < n; i++) {
        if (e[i].apply_at <= now) {
            if (do_domain(e[i].domain)) applied++;          /* success → drop from queue */
            else { failed++; keep[nk++] = e[i]; }           /* keep to retry next tick */
        } else keep[nk++] = e[i];
    }
    if (q_write(keep, nk) != 0) return 1;
    fprintf(stderr, "delay-allow --apply: %d applied, %d failed, %d still pending\n",
            applied, failed, nk - failed);
    return failed ? 1 : 0;
}

/* argv[1] matches a subcommand word, with or without the leading "--". */
static int is_cmd(const char *a, const char *word) {
    return !strcmp(a, word) || (a[0] == '-' && a[1] == '-' && !strcmp(a + 2, word));
}

static int delay_main(int argc, char **argv) {
    if (argc < 2) { delay_usage(); return 2; }
    const char *a = argv[1];
    /* subcommands — bare (status/abort/help) OR flagged (--status/--abort/--help). --apply is the
     * daemon's, kept flag-only. Recognizing the bare words stops `... status` / `... help` from being
     * silently enqueued as "domains" (they pass the charset check). */
    if (is_cmd(a, "apply"))  return delay_apply();
    if (is_cmd(a, "status")) return delay_status();
    if (is_cmd(a, "abort"))  return delay_abort(argv + 2, argc - 2);
    if (is_cmd(a, "help") || !strcmp(a, "-h")) { delay_usage(); return 0; }
    /* any other dashed token is a bad flag → usage (don't treat it as a domain) */
    if (a[0] == '-') { fprintf(stderr, "error: unknown option: %s\n\n", a); delay_usage(); return 2; }
    /* otherwise the args are domains to queue */
    return delay_enqueue(argv + 1, argc - 1);
}
#endif  /* MODE_DELAY_ALLOW */

/* ----- args / file (block/allow only) ----------------------------------- */
#ifndef MODE_DELAY_ALLOW

static void add_domain(const char *d) {
    if (g_ndomains >= MAX_DOMAINS) { fprintf(stderr, "error: too many domains (max %d)\n", MAX_DOMAINS); exit(2); }
    g_domains[g_ndomains++] = strdup(d);
}

static void load_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "error: cannot open file %s\n", path); exit(2); }
    char line[512];
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p && isspace((unsigned char)*p)) p++;
        char *nl = strpbrk(p, "\r\n");
        if (nl) *nl = '\0';
        size_t L = strlen(p);
        while (L > 0 && isspace((unsigned char)p[L - 1])) p[--L] = '\0';
        if (*p == '\0' || *p == '#') continue;
        add_domain(p);
    }
    fclose(f);
}

static void usage(const char *prog) {
    fprintf(stderr,
        "usage: %s [-f FILE] [domain ...]\n"
        "  -f FILE   read domains from FILE (one per line; blank lines and #comments ignored)\n"
        "  domain    one or more domains as arguments (may combine with -f; -f may repeat)\n",
        prog);
}
#endif  /* !MODE_DELAY_ALLOW */

int main(int argc, char **argv) {
#ifdef MODE_DELAY_ALLOW
    return delay_main(argc, argv);
#else
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }

#ifdef MODE_ALLOW
    if (geteuid() != 0) {
        fprintf(stderr, "nextdns-allow: must be run as root — use `sudo %s ...`\n", argv[0]);
        return 1;
    }
#endif

    load_credentials();                        /* needs root (setuid for block, sudo for allow) */

#ifdef MODE_BLOCK
    if (setgid(getgid()) != 0 || setuid(getuid()) != 0) {
        fprintf(stderr, "error: failed to drop privileges\n");
        return 1;
    }
#endif

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-f")) {
            if (i + 1 >= argc) { fprintf(stderr, "error: -f requires a file argument\n"); return 2; }
            load_file(argv[++i]);
        } else if (argv[i][0] == '-' && argv[i][1] != '\0') {
            fprintf(stderr, "error: unknown option %s\n", argv[i]); usage(argv[0]); return 2;
        } else {
            add_domain(argv[i]);
        }
    }

    if (g_ndomains == 0) { fprintf(stderr, "error: no domains given\n"); usage(argv[0]); return 2; }
    for (int i = 0; i < g_ndomains; i++)
        if (!valid_domain(g_domains[i])) { fprintf(stderr, "error: invalid domain: %s\n", g_domains[i]); return 2; }

    int failures = 0;
    for (int i = 0; i < g_ndomains; i++)
        if (!do_domain(g_domains[i])) failures++;

    int ok = g_ndomains - failures;
    if (failures) {
        fprintf(stderr, "%s: %d/%d succeeded, %d FAILED\n", ACTION_NAME, ok, g_ndomains, failures);
        return 1;
    }
    fprintf(stderr, "%s: %d/%d succeeded\n", ACTION_NAME, ok, g_ndomains);
    return 0;
#endif  /* MODE_DELAY_ALLOW else */
}
