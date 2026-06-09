/*
 * sysinfo — Shareframe-Board "fastfetch"-style system banner.
 *
 * A board-agnostic *renderer*: it runs the shareframe-sysinfo overlay script
 * (the single source of board-specific reads) and parses its `key=value`
 * output, then prints a full-width logo banner across the whole row followed by
 * a column of formatted system-info rows. Missing keys are simply skipped, so a
 * metric whose source is absent just drops out of the display.
 */
#define _DEFAULT_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <pwd.h>

#ifndef EMITTER
#define EMITTER  "/usr/bin/shareframe-sysinfo"
#endif
#define MAX_KV   64

/* ---- parsed key=value store --------------------------------------------- */

struct kv { char *k; char *v; };
static struct kv g_kv[MAX_KV];
static int       g_kvn;

static const char *val(const char *key)
{
	for (int i = 0; i < g_kvn; i++)
		if (strcmp(g_kv[i].k, key) == 0)
			return g_kv[i].v;
	return NULL;
}

static void ingest(void)
{
	FILE *fp = popen(EMITTER, "r");
	if (!fp)
		return;

	char line[512];
	while (g_kvn < MAX_KV && fgets(line, sizeof line, fp)) {
		char *nl = strchr(line, '\n');
		if (nl)
			*nl = '\0';
		char *eq = strchr(line, '=');
		if (!eq || eq == line)
			continue;
		*eq = '\0';
		char *k = strdup(line);
		char *v = strdup(eq + 1);
		if (k && v) {
			g_kv[g_kvn].k = k;
			g_kv[g_kvn].v = v;
			g_kvn++;
		} else {
			free(k);
			free(v);
		}
	}
	pclose(fp);
}

/* ---- colors ------------------------------------------------------------- */

static const char *C_LOGO = "";
static const char *C_LABEL = "";
static const char *C_RESET = "";

static void init_colors(void)
{
	if (getenv("NO_COLOR"))
		return;
	C_LOGO  = "\033[1;36m"; /* bold cyan */
	C_LABEL = "\033[1;37m"; /* bold white */
	C_RESET = "\033[0m";
}

/* ---- formatters --------------------------------------------------------- */

static int get_u64(const char *key, uint64_t *out)
{
	const char *s = val(key);
	if (!s || !*s)
		return 0;
	char *end;
	unsigned long long x = strtoull(s, &end, 10);
	if (end == s)
		return 0;
	*out = (uint64_t)x;
	return 1;
}

static void human_bytes(uint64_t b, char *out, size_t n)
{
	static const char *u[] = { "B", "KiB", "MiB", "GiB", "TiB" };
	double v = (double)b;
	int i = 0;
	while (v >= 1024.0 && i < 4) {
		v /= 1024.0;
		i++;
	}
	if (i == 0)
		snprintf(out, n, "%.0f %s", v, u[i]);
	else
		snprintf(out, n, "%.1f %s", v, u[i]);
}

static void fmt_uptime(uint64_t s, char *out, size_t n)
{
	unsigned long long d = s / 86400; s %= 86400;
	unsigned long long h = s / 3600;  s %= 3600;
	unsigned long long m = s / 60;
	if (d)
		snprintf(out, n, "%llud %lluh %llum", d, h, m);
	else if (h)
		snprintf(out, n, "%lluh %llum", h, m);
	else
		snprintf(out, n, "%llum", m);
}

/* ---- banner + rows ------------------------------------------------------ */

/* ANSI-Shadow figlet of "Shareframe Board" — kept byte-identical to the
 * pre-login /etc/issue art so both entrances show the same logo. */
static const char *logo[] = {
	"███████╗██╗  ██╗ █████╗ ██████╗ ███████╗███████╗██████╗  █████╗ ███╗   ███╗███████╗",
	"██╔════╝██║  ██║██╔══██╗██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗████╗ ████║██╔════╝",
	"███████╗███████║███████║██████╔╝█████╗  █████╗  ██████╔╝███████║██╔████╔██║█████╗",
	"╚════██║██╔══██║██╔══██║██╔══██╗██╔══╝  ██╔══╝  ██╔══██╗██╔══██║██║╚██╔╝██║██╔══╝",
	"███████║██║  ██║██║  ██║██║  ██║███████╗██║     ██║  ██║██║  ██║██║ ╚═╝ ██║███████╗",
	"╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝",
	"",
	"                    ██████╗  ██████╗  █████╗ ██████╗ ██████╗",
	"                    ██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██╔══██╗",
	"                    ██████╔╝██║   ██║███████║██████╔╝██║  ██║",
	"                    ██╔══██╗██║   ██║██╔══██║██╔══██╗██║  ██║",
	"                    ██████╔╝╚██████╔╝██║  ██║██║  ██║██████╔╝",
	"                    ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝",
};

static void banner(void)
{
	printf("%s", C_LOGO);
	for (size_t i = 0; i < sizeof logo / sizeof logo[0]; i++)
		printf("%s\n", logo[i]);
	printf("%s", C_RESET);
}

static void row(const char *label, const char *value)
{
	if (!value || !*value)
		return;
	printf("  %s%-8s%s %s\n", C_LABEL, label, C_RESET, value);
}

static void disk_row(const char *label, const char *total_key, const char *free_key)
{
	uint64_t total, freeb;
	if (!get_u64(total_key, &total) || !get_u64(free_key, &freeb))
		return;
	char f[32], t[32], buf[80];
	human_bytes(freeb, f, sizeof f);
	human_bytes(total, t, sizeof t);
	snprintf(buf, sizeof buf, "%s free of %s", f, t);
	row(label, buf);
}

int main(void)
{
	init_colors();
	ingest();

	banner();

	/* title: <user>@<host>, fastfetch-style, underlined */
	const char *user = getenv("USER");
	if (!user || !*user) {
		struct passwd *pw = getpwuid(geteuid());
		if (pw && pw->pw_name)
			user = pw->pw_name;
	}
	if (!user || !*user)
		user = "user";
	const char *host = val("hostname");
	char title[256];
	if (host)
		snprintf(title, sizeof title, "%s@%s", user, host);
	else
		snprintf(title, sizeof title, "%s", user);
	printf("\n  %s%s%s\n  ", C_LABEL, title, C_RESET);
	for (size_t i = 0, n = strlen(title); i < n; i++)
		putchar('-');
	putchar('\n');

	char buf[96];

	row("OS", val("os_pretty_name"));
	row("Kernel", val("kernel"));

	uint64_t up;
	if (get_u64("uptime_seconds", &up)) {
		fmt_uptime(up, buf, sizeof buf);
		row("Uptime", buf);
	}

	row("Boots", val("boot_count"));

	if (val("cpu_usage_percent")) {
		snprintf(buf, sizeof buf, "%s %%", val("cpu_usage_percent"));
		row("CPU", buf);
	}

	if (val("cpu_temp_celsius")) {
		snprintf(buf, sizeof buf, "%s \xc2\xb0" "C", val("cpu_temp_celsius"));
		row("Temp", buf);
	}

	if (val("load_1") && val("load_5") && val("load_15")) {
		snprintf(buf, sizeof buf, "%s %s %s",
		         val("load_1"), val("load_5"), val("load_15"));
		row("Load", buf);
	}

	uint64_t mem_total, mem_avail;
	if (get_u64("ram_total_bytes", &mem_total) &&
	    get_u64("ram_available_bytes", &mem_avail)) {
		uint64_t used = mem_total > mem_avail ? mem_total - mem_avail : 0;
		char u[32], t[32];
		human_bytes(used, u, sizeof u);
		human_bytes(mem_total, t, sizeof t);
		int pct = mem_total ? (int)((used * 100) / mem_total) : 0;
		snprintf(buf, sizeof buf, "%s / %s (%d%%)", u, t, pct);
		row("Memory", buf);
	}

	disk_row("Root", "storage_root_total_bytes", "storage_root_free_bytes");
	disk_row("Data", "storage_data_total_bytes", "storage_data_free_bytes");

	/* WLAN: ip, signal, link state — show whatever is present */
	const char *ipw = val("ip_wlan0");
	const char *sig = val("wlan_signal_dbm");
	const char *conn = val("wlan_connected");
	if (ipw || sig || conn) {
		char w[96];
		size_t off = 0;
		if (ipw)
			off += (size_t)snprintf(w + off, sizeof w - off, "%s", ipw);
		if (sig)
			off += (size_t)snprintf(w + off, sizeof w - off,
			                        "%s%s dBm", off ? "  " : "", sig);
		if (conn && off < sizeof w)
			snprintf(w + off, sizeof w - off, "%s%s",
			         off ? "  " : "",
			         strcmp(conn, "true") == 0 ? "up" : "down");
		row("WLAN", w);
	}

	row("USB", val("ip_usb0"));

	putchar('\n');
	return 0;
}
