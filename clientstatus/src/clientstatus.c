/*
 * clientstatus.c — High-performance LAN client status monitor daemon
 * Drop-in replacement for clientstatus.sh
 * Copyright (C) 2026 @Mige99
 *
 *
 * Build: $(CC) -O2 -Wall -o clientstatus clientstatus.c
 *
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <ctype.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <ifaddrs.h>
#include <arpa/inet.h>

/* ─── Limits ─────────────────────────────────────────── */

#define MAX_CT      1024
#define MAX_WIFI    256
#define MAX_ARP     512
#define MAX_DHCP    512
#define MAX_CLI     512
#define MAX_AP      32
#define MAX_LINE    4096
#define MAX_FORK    64      /* max concurrent ping child processes */
#define ML  18      /* MAC_LEN  */
#define IL  16      /* IP_LEN   */
#define NL  128     /* NAME_LEN */
#define SL  64      /* SSID_LEN */

/* ─── Paths & defaults ───────────────────────────────── */

#define STATE_FILE  "/tmp/clientstatus.state"
#define OUTPUT_FILE "/tmp/clientstatus"
#define PID_FILE    "/tmp/clientstatus.pid"
#define DEF_INTERVAL  30
#define IDLE_INTERVAL 300
#define DEF_LAN       "br-lan"

/* ─── Types ──────────────────────────────────────────── */

typedef struct { char ip[IL]; } IpE;
typedef struct { char mac[ML]; char ssid[SL]; } WfE;
typedef struct { char mac[ML]; char ip[IL]; } ArE;
typedef struct { char mac[ML]; char ip[IL]; char host[NL]; } DhE;
typedef struct { char ifn[32]; char ssid[SL]; } ApI;

typedef struct {
    char mac[ML], ip[IL], host[NL];
    char dtype[16], conn[SL];
    int  online, prio, miss;
    time_t since;
    int  fl_wifi, fl_conn, fl_ping, fl_dhcp;
} Cli;

typedef struct { pid_t pid; char ip[IL]; } PingRun;

/* ─── Globals ────────────────────────────────────────── */

static int  g_interval = DEF_INTERVAL;
static char g_lan[32]  = DEF_LAN;
static int  g_has_wifi, g_ct_thresh = 6840;
static int  g_wifi_byte_stats;  /* 0=undetermined, 1=enabled, -1=conntrack */
static uint32_t g_lan_net, g_lan_mask;
static char g_lan_ip[IL];
static int  g_lan_prefix;

static IpE  g_ct[MAX_CT];     static int g_ct_n;
static WfE  g_wf[MAX_WIFI];   static int g_wf_n;
static ArE  g_arp[MAX_ARP];   static int g_arp_n;
static DhE  g_dhcp[MAX_DHCP]; static int g_dhcp_n;
static IpE  g_ping[MAX_CT];   static int g_ping_n;
static ApI  g_ap[MAX_AP];     static int g_ap_n;
static Cli  g_cli[MAX_CLI];   static int g_cli_n;

static volatile sig_atomic_t g_usr1, g_run = 1;

/* ─── Helpers ────────────────────────────────────────── */

static void on_usr1(int s) { (void)s; g_usr1 = 1; }
static void on_term(int s) { (void)s; g_run = 0; }

static int in_lan(const char *ip) {
    struct in_addr a;
    if (!ip || !*ip || !inet_aton(ip, &a)) return 0;
    return (a.s_addr & g_lan_mask) == g_lan_net;
}

static int ip_hit(const IpE *s, int n, const char *ip) {
    for (int i = 0; i < n; i++)
        if (strcmp(s[i].ip, ip) == 0) return 1;
    return 0;
}

static int wf_hit(const char *mac) {
    for (int i = 0; i < g_wf_n; i++)
        if (strcasecmp(g_wf[i].mac, mac) == 0) return 1;
    return 0;
}

static const char *wf_ssid(const char *mac) {
    for (int i = 0; i < g_wf_n; i++)
        if (strcasecmp(g_wf[i].mac, mac) == 0) return g_wf[i].ssid;
    return "";
}

static void upper(char *s)
    { for (; *s; s++) *s = toupper((unsigned char)*s); }

static void trim(char *s) {
    char *e;
    while (isspace((unsigned char)*s)) memmove(s, s + 1, strlen(s));
    for (e = s + strlen(s) - 1; e >= s && isspace((unsigned char)*e); e--)
        *e = '\0';
}

static int valid_mac(const char *m) {
    if (!m || strlen(m) != 17) return 0;
    for (int i = 0; i < 17; i++) {
        if (i == 2 || i == 5 || i == 8 || i == 11 || i == 14) {
            if (m[i] != ':') return 0;
        } else {
            if (!isxdigit((unsigned char)m[i])) return 0;
        }
    }
    return 1;
}

static int uci_int(const char *key, int def) {
    char cmd[128], buf[32];
    snprintf(cmd, sizeof cmd, "uci -q get %s 2>/dev/null", key);
    FILE *f = popen(cmd, "r");
    if (f) {
        if (fgets(buf, sizeof buf, f) && atoi(buf) > 0)
            { int v = atoi(buf); pclose(f); return v; }
        pclose(f);
    }
    return def;
}

static void uci_str(const char *key, char *o, int l, const char *d) {
    char cmd[128], buf[128];
    snprintf(cmd, sizeof cmd, "uci -q get %s 2>/dev/null", key);
    FILE *f = popen(cmd, "r");
    if (f) {
        if (fgets(buf, sizeof buf, f)) { trim(buf); if (buf[0])
            { strncpy(o, buf, l - 1); pclose(f); return; } }
        pclose(f);
    }
    strncpy(o, d, l - 1);
}

static void fmt_dur(int s, char *b, int l) {
    if (s < 60)        snprintf(b, l, "%ds", s);
    else if (s < 3600)  snprintf(b, l, "%dm%ds", s / 60, s % 60);
    else if (s < 86400) snprintf(b, l, "%dh%dm", s / 3600, (s % 3600) / 60);
    else                snprintf(b, l, "%dd%dh", s / 86400, (s % 86400) / 3600);
}

/* ─── LAN subnet ─────────────────────────────────────── */

static int init_lan(void) {
    struct ifaddrs *ifa, *p;
    if (getifaddrs(&ifa) < 0) return -1;
    for (p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(p->ifa_name, g_lan) != 0) continue;
        struct sockaddr_in *a = (void *)p->ifa_addr;
        struct sockaddr_in *m = (void *)p->ifa_netmask;
        g_lan_net  = a->sin_addr.s_addr & m->sin_addr.s_addr;
        g_lan_mask = m->sin_addr.s_addr;
        inet_ntop(AF_INET, &a->sin_addr, g_lan_ip, IL);
        uint32_t mv = ntohl(m->sin_addr.s_addr);
        for (g_lan_prefix = 0; mv & 0x80000000; mv <<= 1) g_lan_prefix++;
        freeifaddrs(ifa); return 0;
    }
    freeifaddrs(ifa); return -1;
}

static void init_ct_thresh(void) {
    FILE *f = fopen("/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established", "r");
    int t = 7440;
    if (f) { fscanf(f, "%d", &t); fclose(f); }
    g_ct_thresh = t - 600;
    if (g_ct_thresh < 0) g_ct_thresh = 0;
}

/* ─── AP discovery ───────────────────────────────────── */

static void build_ap(void) {
    g_ap_n = 0;
    FILE *f = popen("iw dev 2>/dev/null", "r");
    if (!f) return;
    char line[256], ifn[32] = "";
    while (fgets(line, sizeof line, f)) {
        char *p;
        if ((p = strstr(line, "Interface "))) {
            p += 10; while (*p == ' ') p++;
            char *e = p; while (*e && !isspace((unsigned char)*e)) e++;
            *e = '\0'; strncpy(ifn, p, 31);
        }
        if (strstr(line, "type AP") && ifn[0] && g_ap_n < MAX_AP) {
            char cmd[256], ssid[SL] = "";
            snprintf(cmd, sizeof cmd,
                "ubus call iwinfo info '{\"device\":\"%s\"}' 2>/dev/null "
                "| grep -o '\"ssid\"[[:space:]]*:[[:space:]]*\"[^\"]*\"' "
                "| sed 's/.*: *\"//;s/\"$//'", ifn);
            FILE *sf = popen(cmd, "r");
            if (sf) { if (fgets(ssid, sizeof ssid, sf)) trim(ssid); pclose(sf); }
            if (ssid[0]) {
                strncpy(g_ap[g_ap_n].ifn, ifn, 31);
                strncpy(g_ap[g_ap_n].ssid, ssid, SL - 1);
                g_ap_n++;
            }
            ifn[0] = '\0';
        }
    }
    pclose(f);
    g_has_wifi = g_ap_n > 0;

    /* ─── WiFi driver byte stats capability detection ─── */
    if (g_wifi_byte_stats != 0) return;   /* already determined */
    if (g_ap_n == 0) { g_wifi_byte_stats = -1; return; }

    for (int i = 0; i < g_ap_n; i++) {
        char cmd[256];
        snprintf(cmd, sizeof cmd,
            "ubus call iwinfo assoclist '{\"device\":\"%s\"}' 2>/dev/null",
            g_ap[i].ifn);
        FILE *af = popen(cmd, "r");
        if (!af) continue;

        char aline[MAX_LINE];
        int has_mac = 0;
        int has_positive_ct = 0;

        while (fgets(aline, sizeof aline, af)) {
            if (!has_mac && strstr(aline, "\"mac\""))
                has_mac = 1;
            char *ct = strstr(aline, "\"connected_time\"");
            if (ct) {
                ct = strchr(ct, ':');
                if (ct) {
                    ct++;
                    while (*ct && isspace((unsigned char)*ct)) ct++;
                    if (atoi(ct) > 0) has_positive_ct = 1;
                }
            }
        }
        pclose(af);

        if (!has_mac) continue;   /* no clients on this AP, try next */

        /* Has clients — check if driver reports connected_time > 0 */
        if (has_positive_ct) {
            g_wifi_byte_stats = 1;   /* enabled */
        } else {
            g_wifi_byte_stats = -1;  /* conntrack fallback */
        }
        return;
    }
    /* All APs had no clients → keep undetermined (0), retry next loop */
}

static void flush_neigh(void) {
    char cmd[128];
    snprintf(cmd, sizeof cmd, "ip -4 neigh flush dev %s >/dev/null 2>&1", g_lan);
    system(cmd);
    for (int i = 0; i < g_ap_n; i++) {
        snprintf(cmd, sizeof cmd,
            "ip -4 neigh flush dev %s >/dev/null 2>&1", g_ap[i].ifn);
        system(cmd);
    }
}

/* ─── Data collectors ────────────────────────────────── */

static void collect_conntrack(void) {
    FILE *f = fopen("/proc/net/nf_conntrack", "r");
    char line[MAX_LINE];
    g_ct_n = 0;
    if (!f) return;
    while (fgets(line, sizeof line, f) && g_ct_n < MAX_CT) {
        if (strncmp(line, "ipv6", 4) == 0) continue;
        char *src = strstr(line, "src=");
        if (!src) continue;
        src += 4;
        char ip[IL]; int j = 0;
        while (src[j] && !isspace((unsigned char)src[j]) && j < IL - 1)
            { ip[j] = src[j]; j++; }
        ip[j] = '\0';
        if (!in_lan(ip) || ip_hit(g_ct, g_ct_n, ip)) continue;
        char *est = strstr(line, "ESTABLISHED");
        if (est) {
            char *p = est - 1;
            while (p > line && isspace((unsigned char)*p)) p--;
            char *end = p + 1;
            while (p > line && !isspace((unsigned char)*p)) p--;
            if (*p == ' ') p++;
            char num[32]; int len = end - p;
            if (len > 0 && len < 32) {
                memcpy(num, p, len); num[len] = '\0';
                if (atoi(num) <= g_ct_thresh) continue;
            }
        }
        strncpy(g_ct[g_ct_n++].ip, ip, IL);
    }
    fclose(f);
}

static void collect_wifi(void) {
    g_wf_n = 0;
    if (!g_has_wifi) return;
    for (int a = 0; a < g_ap_n && g_wf_n < MAX_WIFI; a++) {
        char cmd[256];
        snprintf(cmd, sizeof cmd,
            "ubus call iwinfo assoclist '{\"device\":\"%s\"}' 2>/dev/null",
            g_ap[a].ifn);
        FILE *f = popen(cmd, "r");
        if (!f) continue;
        char line[MAX_LINE];
        while (fgets(line, sizeof line, f) && g_wf_n < MAX_WIFI) {
            char *p = line;
            while (*p && strlen(p) >= 17) {
                int ok = 1;
                for (int k = 0; k < 17; k++) {
                    if (k == 2 || k == 5 || k == 8 || k == 11 || k == 14)
                        { if (p[k] != ':') { ok = 0; break; } }
                    else { if (!isxdigit((unsigned char)p[k])) { ok = 0; break; } }
                }
                if (ok) {
                    char mac[ML]; memcpy(mac, p, 17); mac[17] = '\0'; upper(mac);
                    int dup = 0;
                    for (int j = 0; j < g_wf_n; j++)
                        if (strcmp(g_wf[j].mac, mac) == 0) { dup = 1; break; }
                    if (!dup) {
                        strncpy(g_wf[g_wf_n].mac, mac, ML);
                        strncpy(g_wf[g_wf_n].ssid, g_ap[a].ssid, SL);
                        g_wf_n++;
                    }
                    p += 17;
                } else p++;
            }
        }
        pclose(f);
    }
}

static void collect_arp(void) {
    FILE *f = fopen("/proc/net/arp", "r");
    char line[256];
    g_arp_n = 0;
    if (!f) return;
    fgets(line, sizeof line, f); /* header */
    while (fgets(line, sizeof line, f) && g_arp_n < MAX_ARP) {
        char ip[IL], hw[16], fg[16], mac[ML], mk[16], dv[32];
        if (sscanf(line, "%15s %15s %15s %17s %15s %31s",
                   ip, hw, fg, mac, mk, dv) < 6) continue;
        if (strcmp(dv, g_lan) != 0) continue;
        if (strcmp(mac, "00:00:00:00:00:00") == 0) continue;
        if (!in_lan(ip)) continue;
        upper(mac);
        strncpy(g_arp[g_arp_n].mac, mac, ML);
        strncpy(g_arp[g_arp_n].ip, ip, IL);
        g_arp_n++;
    }
    fclose(f);
}

static void collect_dhcp(void) {
    FILE *f = fopen("/tmp/dhcp.leases", "r");
    char line[256];
    g_dhcp_n = 0;
    if (!f) return;
    while (fgets(line, sizeof line, f) && g_dhcp_n < MAX_DHCP) {
        long ts; char mac[ML], ip[IL], host[NL], cid[128];
        if (sscanf(line, "%ld %17s %15s %127s %127s",
                   &ts, mac, ip, host, cid) < 4) continue;
        int col = 0;
        for (char *p = mac; *p; p++) if (*p == ':') col++;
        if (col != 5 || strchr(ip, ':') || !in_lan(ip)) continue;
        upper(mac);
        strncpy(g_dhcp[g_dhcp_n].mac, mac, ML);
        strncpy(g_dhcp[g_dhcp_n].ip, ip, IL);
        strncpy(g_dhcp[g_dhcp_n].host, host, NL);
        g_dhcp_n++;
    }
    fclose(f);
}

/*
 * collect_ping — rewritten to use execvp instead of system().
 *
 * Original issues fixed:
 *   1. system("ping ...") leaked stdout/stderr to console
 *   2. system() created a double-fork (fork → shell → ping)
 *   3. Unlimited fork (up to 512 children at once)
 *
 * New design:
 *   - Fork up to MAX_FORK children at a time (sliding window)
 *   - Each child redirects stdin/stdout/stderr to /dev/null, then execvp("ping")
 *   - Parent tracks pid→IP mapping, uses waitpid exit status to record results
 *   - No pipe needed
 */
static void collect_ping(void) {
    g_ping_n = 0;
    typedef struct { char mac[ML]; char ip[IL]; } Cand;
    Cand c[MAX_CLI]; int nc = 0;
    char seen[MAX_CLI][ML]; int ns = 0;

    #define TRY_ADD(m, ip_s) do { \
        int _d = 0; for (int _i = 0; _i < ns; _i++) \
            if (strcasecmp(seen[_i], (m)) == 0) { _d = 1; break; } \
        if (!_d && nc < MAX_CLI) { strncpy(seen[ns++], (m), ML); \
            strncpy(c[nc].mac, (m), ML); strncpy(c[nc].ip, (ip_s), IL); nc++; } \
    } while (0)

    for (int i = 0; i < g_arp_n; i++) {
        if (g_has_wifi && wf_hit(g_arp[i].mac)) continue;
        if (ip_hit(g_ct, g_ct_n, g_arp[i].ip)) continue;
        TRY_ADD(g_arp[i].mac, g_arp[i].ip);
    }
    for (int i = 0; i < g_dhcp_n; i++) {
        if (g_has_wifi && wf_hit(g_dhcp[i].mac)) continue;
        if (ip_hit(g_ct, g_ct_n, g_dhcp[i].ip)) continue;
        TRY_ADD(g_dhcp[i].mac, g_dhcp[i].ip);
    }
    #undef TRY_ADD
    if (nc == 0) return;

    PingRun runs[MAX_CLI];
    int nrun = 0, idx = 0;

    while (idx < nc || nrun > 0) {
        /* Fork up to MAX_FORK children concurrently */
        while (idx < nc && nrun < MAX_FORK) {
            pid_t pid = fork();
            if (pid == 0) {
                /* ── Child: reset signals, redirect stdio, exec ping ── */
                signal(SIGTERM, SIG_DFL);
                signal(SIGINT,  SIG_DFL);
                signal(SIGUSR1, SIG_DFL);

                int devnull = open("/dev/null", O_RDWR);
                if (devnull >= 0) {
                    dup2(devnull, STDIN_FILENO);
                    dup2(devnull, STDOUT_FILENO);
                    dup2(devnull, STDERR_FILENO);
                    if (devnull > STDERR_FILENO) close(devnull);
                }
                execlp("ping", "ping", "-c1", "-W1", c[idx].ip, NULL);
                _exit(127);  /* exec failed */
            }
            if (pid > 0) {
                strncpy(runs[nrun].ip, c[idx].ip, IL);
                runs[nrun].pid = pid;
                nrun++;
            }
            /* pid < 0: fork failed, skip this candidate */
            idx++;
        }
        /* Reap exactly one child */
        if (nrun > 0) {
            int status;
            pid_t w = waitpid(-1, &status, 0);
            if (w > 0) {
                for (int i = 0; i < nrun; i++) {
                    if (runs[i].pid == w) {
                        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                            if (g_ping_n < MAX_CT)
                                strncpy(g_ping[g_ping_n++].ip, runs[i].ip, IL);
                        }
                        runs[i] = runs[--nrun];  /* swap-remove */
                        break;
                    }
                }
            }
        }
    }
}

/* ─── Old state ──────────────────────────────────────── */

typedef struct {
    char mac[ML], status[16], ip[IL], host[NL], dtype[16];
    int  prio, miss; time_t since;
} Old;

static Old g_old[MAX_CLI]; static int g_old_n;

/*
 * load_state — reads persisted client state from disk.
 *
 * Enhanced with per-field validation:
 *   - MAC must pass valid_mac() format check
 *   - Status must be "online" or "offline"
 *   - IP must pass inet_aton() if non-empty
 *   - Miss count must be in [0, 100]
 *   - dtype must be "WiFi" or "Ethernet"
 * Invalid lines are silently skipped.
 */
static void load_state(void) {
    FILE *f = fopen(STATE_FILE, "r");
    char line[MAX_LINE];
    g_old_n = 0;
    if (!f) return;
    while (fgets(line, sizeof line, f) && g_old_n < MAX_CLI) {
        trim(line); if (!line[0]) continue;
        char *t[8]; int n = 0; t[n++] = line;
        for (char *p = line; *p && n < 8; p++)
            if (*p == '|') { *p = '\0'; t[n++] = p + 1; }
        if (n < 8) continue;

        /* ── Validation ── */
        if (!valid_mac(t[0])) continue;
        if (strcmp(t[1], "online") != 0 && strcmp(t[1], "offline") != 0) continue;

        long ts = atol(t[2]);
        if (ts <= 0) continue;

        struct in_addr tmp_ip;
        if (t[3][0] && !inet_aton(t[3], &tmp_ip)) continue;

        if (strcmp(t[5], "WiFi") != 0 && strcmp(t[5], "Ethernet") != 0) continue;

        int prio = atoi(t[6]);
        int miss = atoi(t[7]);
        if (miss < 0 || miss > 100) continue;

        /* ── Store (MAC already uppercase from previous write, but force it) ── */
        strncpy(g_old[g_old_n].mac, t[0], ML - 1);
        g_old[g_old_n].mac[ML - 1] = '\0';
        upper(g_old[g_old_n].mac);

        strncpy(g_old[g_old_n].status, t[1], 15);
        g_old[g_old_n].since = (time_t)ts;
        strncpy(g_old[g_old_n].ip, t[3], IL - 1);
        g_old[g_old_n].ip[IL - 1] = '\0';
        strncpy(g_old[g_old_n].host, t[4], NL - 1);
        g_old[g_old_n].host[NL - 1] = '\0';
        strncpy(g_old[g_old_n].dtype, t[5], 15);
        g_old[g_old_n].prio = prio;
        g_old[g_old_n].miss = miss;
        g_old_n++;
    }
    fclose(f);
}

static Old *find_old(const char *mac) {
    for (int i = 0; i < g_old_n; i++)
        if (strcasecmp(g_old[i].mac, mac) == 0) return &g_old[i];
    return NULL;
}

/* ─── Merge & output ─────────────────────────────────── */

static void merge_and_output(void) {
    time_t now = time(NULL);
    g_cli_n = 0;

    /* Collect unique MACs */
    typedef struct { char mac[ML]; } ME;
    ME all[MAX_CLI * 2]; int na = 0;
    #define ADD(m) do { int _d = 0; for (int _i = 0; _i < na; _i++) \
        if (strcasecmp(all[_i].mac, (m)) == 0) { _d = 1; break; } \
        if (!_d && na < MAX_CLI * 2) strncpy(all[na++].mac, (m), ML); } while (0)

    for (int i = 0; i < g_wf_n; i++)   ADD(g_wf[i].mac);
    for (int i = 0; i < g_arp_n; i++)  ADD(g_arp[i].mac);
    for (int i = 0; i < g_dhcp_n; i++) ADD(g_dhcp[i].mac);
    for (int i = 0; i < g_old_n; i++)  ADD(g_old[i].mac);
    #undef ADD

    /* Sort MACs for deterministic output */
    for (int i = 1; i < na; i++) {
        ME key = all[i]; int j = i - 1;
        while (j >= 0 && strcmp(all[j].mac, key.mac) > 0)
            { all[j + 1] = all[j]; j--; }
        all[j + 1] = key;
    }

    /* Build client state */
    for (int idx = 0; idx < na && g_cli_n < MAX_CLI; idx++) {
        const char *mac = all[idx].mac;
        Cli *c = &g_cli[g_cli_n];
        memset(c, 0, sizeof *c);
        strncpy(c->mac, mac, ML);
        Old *old = find_old(mac);

        /*
         * IP: DHCP > ARP only.
         * Do NOT fall back to old state IP — an offline client's stale IP
         * may have been reassigned to a new client, and since the frontend
         * already hides IPs for offline clients, preserving the old IP
         * serves no purpose while introducing false-positive online detection.
         */
        c->ip[0] = '\0';
        for (int i = 0; i < g_dhcp_n; i++)
            if (strcasecmp(g_dhcp[i].mac, mac) == 0)
                { strncpy(c->ip, g_dhcp[i].ip, IL); c->fl_dhcp = 1; break; }
        if (!c->ip[0])
            for (int i = 0; i < g_arp_n; i++)
                if (strcasecmp(g_arp[i].mac, mac) == 0)
                    { strncpy(c->ip, g_arp[i].ip, IL); break; }

        /* Hostname: DHCP > old > "unknown" */
        c->host[0] = '\0';
        for (int i = 0; i < g_dhcp_n; i++)
            if (strcasecmp(g_dhcp[i].mac, mac) == 0)
                { if (g_dhcp[i].host[0] && strcmp(g_dhcp[i].host, "*") != 0)
                    strncpy(c->host, g_dhcp[i].host, NL); break; }
        if ((!c->host[0] || strcmp(c->host, "unknown") == 0) && old)
            strncpy(c->host, old->host, NL);
        if (!c->host[0]) strcpy(c->host, "unknown");

        /* Device type */
        int is_wf = g_has_wifi && wf_hit(mac);
        if (g_has_wifi) {
            if (is_wf) strcpy(c->dtype, "WiFi");
            else if (old && strcmp(old->dtype, "WiFi") == 0) strcpy(c->dtype, "WiFi");
            else strcpy(c->dtype, "Ethernet");
        } else strcpy(c->dtype, "Ethernet");

        c->fl_wifi = is_wf;
        if (c->ip[0]) c->fl_conn = ip_hit(g_ct, g_ct_n, c->ip);
        if (c->ip[0]) c->fl_ping = ip_hit(g_ping, g_ping_n, c->ip);

        /* Miss count */
        c->miss = (old && strcmp(old->status, "online") == 0) ? old->miss : 0;

        /* Online / offline determination */
        int prio = 99;
        if (g_has_wifi && strcmp(c->dtype, "WiFi") == 0) {
            c->online = is_wf; prio = 0; c->miss = 0;
        } else if (c->fl_conn) {
            c->online = 1; prio = c->fl_dhcp ? 1 : 2; c->miss = 0;
        } else if (c->fl_ping) {
            c->online = 1; prio = 3; c->miss = 0;
        } else {
            c->miss++;
            if (old && old->prio == 1 && !c->fl_dhcp)
                { c->online = 0; prio = 1; }
            else if (old && old->prio == 3 && c->miss < 3)
                { c->online = old ? (strcmp(old->status, "online") == 0) : 0;
                  prio = old ? old->prio : 99; }
            else if (c->miss >= 3)
                { c->online = 0; prio = 99; }
            else
                { c->online = old ? (strcmp(old->status, "online") == 0) : 0;
                  prio = old ? old->prio : 99; }
        }
        c->prio = prio;

        /* Timer: reset on state transition */
        c->since = old ? old->since : now;
        if (c->online) { if (!old || strcmp(old->status, "online") != 0) c->since = now; }
        else           { if (!old || strcmp(old->status, "online") == 0) c->since = now; }

        /* Display connection */
        if (g_has_wifi && is_wf) strncpy(c->conn, wf_ssid(mac), SL);
        else if (g_has_wifi && strcmp(c->dtype, "WiFi") == 0) strcpy(c->conn, "WiFi");
        else strcpy(c->conn, "Ethernet");

        g_cli_n++;
    }

    /* ─── Write output file ──────────────────────────── */
    char tmp[256];
    snprintf(tmp, sizeof tmp, "%s.tmp", OUTPUT_FILE);
    FILE *fout = fopen(tmp, "w");
    if (!fout) return;

    char ts[64];
    struct tm *tm = localtime(&now);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", tm);

    fprintf(fout, "# Client Status — %s\n", ts);
    fprintf(fout, "# Refresh interval: %ds  |  LAN: %s (%s/%d)\n",
            g_interval, g_lan, g_lan_ip, g_lan_prefix);

    /* WiFi status: three-way branch */
    if (!g_has_wifi)
        fprintf(fout, "# WiFi: disabled\n");
    else if (g_wifi_byte_stats == 1)
        fprintf(fout, "# WiFi: enabled\n");
    else
        fprintf(fout, "# WiFi: conntrack\n");

    /* AP info lines: only when byte stats supported */
    if (g_wifi_byte_stats == 1) {
        for (int i = 0; i < g_ap_n; i++)
            fprintf(fout, "# AP: %s|%s\n", g_ap[i].ifn, g_ap[i].ssid);
    }

    fprintf(fout, "#\n");
    fprintf(fout, "# %-17s  %-8s  %-10s  %-16s  %-20s  %-10s\n",
            "MAC", "STATUS", "DURATION", "IPv4", "HOSTNAME", "CNT");
    fprintf(fout, "# %-17s  %-8s  %-10s  %-16s  %-20s  %-10s\n",
            "─────────────────", "────────", "──────────",
            "────────────────", "────────────────────", "──────────");

    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < g_cli_n; i++) {
            Cli *c = &g_cli[i];
            if ((pass == 0 && !c->online) || (pass == 1 && c->online)) continue;
            char dur[32];
            fmt_dur((int)(now - c->since), dur, sizeof dur);
            fprintf(fout, "%-17s  %-8s  %-10s  %-16s  %-20s  %-10s\n",
                    c->mac, c->online ? "online" : "offline", dur,
                    c->ip[0] ? c->ip : "—", c->host, c->conn);
        }
    }
    fclose(fout);
    rename(tmp, OUTPUT_FILE);

    /* ─── Write state file ───────────────────────────── */
    snprintf(tmp, sizeof tmp, "%s.tmp", STATE_FILE);
    FILE *fs = fopen(tmp, "w");
    if (fs) {
        for (int i = 0; i < g_cli_n; i++) {
            Cli *c = &g_cli[i];
            fprintf(fs, "%s|%s|%ld|%s|%s|%s|%d|%d\n",
                    c->mac, c->online ? "online" : "offline",
                    (long)c->since, c->ip, c->host,
                    c->dtype, c->prio, c->miss);
        }
        fclose(fs);
        rename(tmp, STATE_FILE);
    }
}

/* ─── Main ───────────────────────────────────────────── */

int main(void) {
    FILE *pf = fopen(PID_FILE, "w");
    if (pf) { fprintf(pf, "%d\n", getpid()); fclose(pf); }

    struct sigaction sa = { .sa_handler = on_usr1 };
    sigaction(SIGUSR1, &sa, NULL);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    g_interval = uci_int("clientstatus.main.interval", DEF_INTERVAL);
    uci_str("clientstatus.main.lan_iface", g_lan, sizeof g_lan, DEF_LAN);

    if (init_lan() < 0) {
        fprintf(stderr, "clientstatus: cannot get LAN address for %s\n", g_lan);
        return 1;
    }
    init_ct_thresh();
    build_ap();
    flush_neigh();

    while (g_run) {
        time_t t0 = time(NULL);

        /* Retry WiFi byte stats detection if undetermined */
        if (g_has_wifi && g_wifi_byte_stats == 0)
            build_ap();

        load_state();
        collect_conntrack();
        if (g_has_wifi) collect_wifi();
        collect_arp();
        collect_dhcp();
        collect_ping();
        merge_and_output();

        int was_active = g_usr1; g_usr1 = 0;
        int sl = (was_active ? g_interval : IDLE_INTERVAL) - (int)(time(NULL) - t0);
        if (sl < 1) sl = 1;
        for (unsigned r = (unsigned)sl; g_run && r > 0; ) {
            r = sleep(r);
            if (g_usr1) break;
        }
    }

    unlink(PID_FILE);
    return 0;
}
