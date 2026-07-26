/* sudome.c — self-discipline gate that grants/revokes passwordless sudo for one user.
 *
 * Compiled to a setuid-root binary (mode 4711 root:wheel), exactly like
 * nextdns-block: the invoking user can EXECUTE it (so it runs as root, to read
 * the root-only credentials file) but cannot READ the binary itself (no read
 * bit). The password is NOT baked into the binary — it lives in a root-only
 * file (see below); the setuid bit is just what lets the gate run as root.
 *
 *   sudome add      -> prompts for the password (hidden). If correct, adds the
 *                      invoking user to the `admin` group via dseditgroup, which
 *                      grants sudo through macOS's default %admin rule. Takes
 *                      effect on next login (already-open shells keep cached
 *                      group membership for a while).
 *   sudome remove   -> removes the user from `admin`, deletes any stale
 *                      /etc/sudoers.d/sudome-<user> override, and wipes cached
 *                      sudo timestamps. No password — revoking/tightening is
 *                      always allowed (same logic as nextdns block-vs-allow).
 *
 * Self-binding threat model: the adversary is *you*, weakly trying to loosen
 * your own restrictions. The password makes the loosening deliberate. This is
 * NOT hardened against an attacker who already has root or a disk backup — the
 * password lives plaintext in a root-only file.
 *
 * The password is read from a root-only credentials file (created mode 600
 * root:wheel by install.sh). Edit it with `sudo nano` to change the password;
 * no recompile needed.
 *
 * Build/install: see install.sh (cc + `install -m 4711 -o root -g wheel`).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <pwd.h>

#define DSEDITGROUP_BIN "/usr/sbin/dseditgroup"
#define CRED_FILE       "/usr/local/etc/sudome/Allpassword"

/* The user sudome operates on is the REAL (invoking) user — not a hardcoded
 * name. sudome is setuid-root, so getuid() is whoever actually ran it; this
 * makes the tool portable to any machine / any account with no edit. It's taken
 * from the kernel's real uid (never argv/env), so it can't be spoofed. */
static char g_user[256];
static char g_sudoers[512];

static void resolve_user(void) {
    struct passwd *pw = getpwuid(getuid());
    if (getuid() == 0 || !pw || !pw->pw_name || !pw->pw_name[0]) {
        fprintf(stderr, "sudome: run it directly as your own user, not via sudo/root\n");
        exit(1);
    }
    snprintf(g_user, sizeof g_user, "%s", pw->pw_name);
    snprintf(g_sudoers, sizeof g_sudoers, "/etc/sudoers.d/sudome-%s", g_user);
}

/* Set the target to an EXPLICIT username (for the root-only --give/--take modes).
 * Validates the account exists; exits otherwise. */
static void set_user_explicit(const char *name) {
    struct passwd *pw = getpwnam(name);
    if (!pw || !pw->pw_name || !pw->pw_name[0]) {
        fprintf(stderr, "sudome: no such user '%s'\n", name);
        exit(1);
    }
    snprintf(g_user, sizeof g_user, "%s", pw->pw_name);
    snprintf(g_sudoers, sizeof g_sudoers, "/etc/sudoers.d/sudome-%s", g_user);
}

/* Load the password from the root-only credentials file. Read while EUID==0
 * (setuid), and refuse if the file isn't locked down. The whole file IS the
 * password; surrounding whitespace / trailing newline is trimmed. */
static int load_password(char *buf, size_t buflen) {
    struct stat st;
    if (stat(CRED_FILE, &st) != 0) {
        fprintf(stderr, "sudome: cannot read %s (run install.sh, then set the password)\n", CRED_FILE);
        return -1;
    }
    if (st.st_uid != 0) {
        fprintf(stderr, "sudome: %s must be owned by root\n", CRED_FILE);
        return -1;
    }
    if (st.st_mode & (S_IRWXG | S_IRWXO)) {
        fprintf(stderr, "sudome: %s must be chmod 600 (no group/other access)\n", CRED_FILE);
        return -1;
    }
    FILE *f = fopen(CRED_FILE, "r");
    if (!f) { perror("sudome: open password file"); return -1; }

    if (!fgets(buf, (int)buflen, f)) { buf[0] = '\0'; }
    fclose(f);

    /* trim leading/trailing whitespace (passwords here are alphanumeric) */
    size_t L = strlen(buf);
    while (L > 0 && isspace((unsigned char)buf[L - 1])) buf[--L] = '\0';
    char *p = buf;
    while (*p && isspace((unsigned char)*p)) p++;
    if (p != buf) memmove(buf, p, strlen(p) + 1);

    if (buf[0] == '\0') {
        fprintf(stderr, "sudome: %s is empty — set a password first\n", CRED_FILE);
        return -1;
    }
    return 0;
}

/* Read a line from the controlling terminal with echo disabled. */
static int read_password(char *buf, size_t buflen) {
    int fd = open("/dev/tty", O_RDWR);
    if (fd < 0) { fprintf(stderr, "sudome: no controlling terminal\n"); return -1; }

    struct termios old, raw;
    if (tcgetattr(fd, &old) != 0) { close(fd); return -1; }
    raw = old;
    raw.c_lflag &= ~ECHO;                       /* turn off echo */
    tcsetattr(fd, TCSAFLUSH, &raw);

    const char *prompt = "Password: ";
    (void)write(fd, prompt, strlen(prompt));

    size_t n = 0;
    char c;
    while (n < buflen - 1) {
        ssize_t r = read(fd, &c, 1);
        if (r <= 0 || c == '\n' || c == '\r') break;
        buf[n++] = c;
    }
    buf[n] = '\0';

    tcsetattr(fd, TCSAFLUSH, &old);             /* restore echo */
    (void)write(fd, "\n", 1);
    close(fd);
    return 0;
}

/* Constant-time-ish comparison so we don't leak length via early exit. */
static int pw_matches(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    unsigned char diff = (unsigned char)(la ^ lb);
    size_t n = la > lb ? la : lb;
    for (size_t i = 0; i < n; i++)
        diff |= (unsigned char)(a[i % (la ? la : 1)] ^ b[i % (lb ? lb : 1)]);
    return diff == 0;
}

/* Run a program to completion; returns its exit code (-1 on spawn failure).
 * stdout/stderr are silenced so dseditgroup chatter doesn't leak. */
static int run(char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, 1); dup2(dn, 2); close(dn); }
        execv(argv[0], argv);
        _exit(127);
    }
    int st; if (waitpid(pid, &st, 0) < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* Is g_user currently a member of the admin group? */
static int is_admin(void) {
    char *av[] = { DSEDITGROUP_BIN, "-o", "checkmember", "-m", g_user, "admin", NULL };
    return run(av) == 0;
}

/* Add/remove g_user to/from the admin group. Returns 0 on success. */
static int set_admin(int add) {
    char *av[] = { DSEDITGROUP_BIN, "-o", "edit",
                   add ? "-a" : "-d", g_user, "-t", "user", "admin", NULL };
    return run(av);
}

static int do_add(void) {
    char real[256];
    if (load_password(real, sizeof real) != 0) return 1;

    char entered[256];
    if (read_password(entered, sizeof entered) != 0) { memset(real, 0, sizeof real); return 1; }

    int ok = pw_matches(entered, real);
    memset(entered, 0, sizeof entered);         /* don't leave them on the stack */
    memset(real, 0, sizeof real);
    if (!ok) {
        fprintf(stderr, "sudome: incorrect password\n");
        return 1;
    }

    if (set_admin(1) != 0) {
        fprintf(stderr, "sudome: failed to add %s to the admin group\n", g_user);
        return 1;
    }
    printf("sudome: granted admin/sudo to %s (effective on next login; "
           "current shells may keep cached group membership)\n", g_user);
    return 0;
}

/* Wipe ALL cached sudo credentials so revocation takes effect immediately in
 * every terminal, not after the 5-minute timeout. Removes every timestamp
 * record in /var/db/sudo/ts/ (one file per uid; a single file may also hold
 * several tty records). sudo recreates them on the next successful auth. */
#define SUDO_TS_DIR "/var/db/sudo/ts"
static void clear_sudo_cache(void) {
    DIR *d = opendir(SUDO_TS_DIR);
    if (!d) return;                             /* dir absent == nothing cached */
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        char path[512];
        snprintf(path, sizeof path, "%s/%s", SUDO_TS_DIR, e->d_name);
        unlink(path);                           /* ignore errors: best-effort */
    }
    closedir(d);
}

static int do_remove(void) {
    int was_admin = is_admin();
    int rc = set_admin(0);                       /* remove from admin group */
    unlink(g_sudoers);                           /* drop any stale NOPASSWD override too */
    clear_sudo_cache();                          /* kill cached sudo timestamps now */
    if (rc != 0) {
        fprintf(stderr, "sudome: failed to remove %s from the admin group\n", g_user);
        return 1;
    }
    if (was_admin)
        printf("sudome: removed admin/sudo from %s — no sudo, no GUI admin elevation "
               "(fully effective after logout/login)\n", g_user);
    else
        printf("sudome: %s was already not an admin; cleaned up anyway\n", g_user);
    return 0;
}

/* Root-only grant/revoke for a NAMED user, no password. For a genuinely root
 * caller (a root daemon like demonlock's scheduler, or `sudo sudome …`); root is
 * already the authority, so no password gate. Reuses set_admin + the same cleanup
 * as remove. See the getuid()==0 gate in main() — it's what keeps non-root out. */
static int do_give(void) {
    if (set_admin(1) != 0) {
        fprintf(stderr, "sudome: failed to add %s to the admin group\n", g_user);
        return 1;
    }
    printf("sudome: granted admin/sudo to %s (effective on next login)\n", g_user);
    return 0;
}

static int do_take(void) {
    int was_admin = is_admin();
    int rc = set_admin(0);
    unlink(g_sudoers);
    clear_sudo_cache();
    if (rc != 0) {
        fprintf(stderr, "sudome: failed to remove %s from the admin group\n", g_user);
        return 1;
    }
    printf("sudome: removed admin/sudo from %s%s\n", g_user,
           was_admin ? "" : " (was already not an admin)");
    return 0;
}

/* Pipe `text` into /usr/bin/pbcopy (no shell, no trailing newline → the clipboard is exactly the
 * password). Same fork/exec discipline as run(). */
static int copy_to_clipboard(const char *text) {
    int fds[2];
    if (pipe(fds) != 0) { perror("sudome: pipe"); return -1; }
    pid_t pid = fork();
    if (pid < 0) { perror("sudome: fork"); close(fds[0]); close(fds[1]); return -1; }
    if (pid == 0) {                              /* child: pbcopy reads from the pipe */
        close(fds[1]);
        dup2(fds[0], STDIN_FILENO);
        close(fds[0]);
        char *av[] = { "/usr/bin/pbcopy", NULL };
        execv(av[0], av);
        _exit(127);
    }
    close(fds[0]);
    size_t len = strlen(text);
    ssize_t w = write(fds[1], text, len);
    close(fds[1]);
    int status;
    waitpid(pid, &status, 0);
    return (w == (ssize_t)len && WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : -1;
}

/* Root-only: read the held master password and put it on the clipboard. Adds no capability a root
 * caller lacks (root can already `cat` the file) — it's convenience. NOTE: this means anyone who can
 * reach root can extract the master secret, so the password is only as strong as your admin gate. */
static int do_copy_password(void) {
    char pw[256];
    if (load_password(pw, sizeof pw) != 0) return 1;
    int rc = copy_to_clipboard(pw);
    memset(pw, 0, sizeof pw);                    /* don't leave it on the stack */
    if (rc != 0) { fprintf(stderr, "sudome: failed to copy to clipboard (is pbcopy reachable?)\n"); return 1; }
    printf("sudome: master password copied to the clipboard — paste it, then clear your clipboard\n");
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "usage: sudome {add|remove}                    # you toggle your OWN admin (add is password-gated)\n"
        "       sudome --give-to-user <user>           # ROOT-ONLY: grant admin to <user>, no password\n"
        "       sudome --take-from-user <user>         # ROOT-ONLY: revoke admin from <user>\n"
        "       sudome copy-master-password            # ROOT-ONLY: copy the held password to the clipboard\n");
}

int main(int argc, char **argv) {
    if (geteuid() != 0) {
        fprintf(stderr, "sudome: not running as root — must be installed setuid-root (mode 4711)\n");
        return 1;
    }

    /* Root-only, explicit-target modes. Gated on the REAL uid (getuid), NOT euid:
     * the setuid bit forces euid==0 for every caller, so only a process genuinely
     * INVOKED by root (a root daemon, or `sudo sudome …`) has getuid()==0. A normal
     * user hitting these gets refused — they must use the password-gated `add`. */
    if (argc == 3 && (strcmp(argv[1], "--give-to-user") == 0 ||
                      strcmp(argv[1], "--take-from-user") == 0)) {
        if (getuid() != 0) {
            fprintf(stderr, "sudome: %s is root-only — run it as root (e.g. via sudo or a root daemon)\n", argv[1]);
            return 1;
        }
        set_user_explicit(argv[2]);
        return strcmp(argv[1], "--give-to-user") == 0 ? do_give() : do_take();
    }
    if (argc == 2 && strcmp(argv[1], "copy-master-password") == 0) {
        if (getuid() != 0) {
            fprintf(stderr, "sudome: copy-master-password is root-only — run it as root (e.g. via sudo)\n");
            return 1;
        }
        return do_copy_password();
    }

    /* Self-service: the invoking (non-root) user toggles their OWN admin. */
    resolve_user();   /* target = whoever ran us (real uid); forbids root */
    if (argc != 2) { usage(); return 2; }
    if (strcmp(argv[1], "add") == 0)    return do_add();
    if (strcmp(argv[1], "remove") == 0) return do_remove();

    usage();
    return 2;
}
