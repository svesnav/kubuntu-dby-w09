/*
 * matepad-tfa9874: speaker amplifier control for the MatePad 11 (DBY-W09)
 * under Linux 7.0, where Huawei's smartpakit driver (/dev/smartpakit) does
 * not exist.  Same job and same register lists as the 4.19 matepad-smartpa
 * (../../matepad_smartpa.c), but the four NXP TFA9874 amps are driven
 * directly over i2c-dev: I2C bus 3 (i2c@98c000), addresses 0x34-0x37 = amp
 * 0-3, 8-bit register numbers, 16-bit big-endian values.
 *
 * Lists: /odm/etc/audio/nxp/tfa9874_<n>_configs.xml (copied to
 * MATEPAD_SMARTPA_DIR/nxp, default /usr/local/share/matepad-sound/smartpa),
 * scenes INIT_CHIP, POWER_ON_L, POWER_OFF_L.  A node is
 * "reg, mask, value, delay_ms, type" (smartpakit):
 *   type 0  write; a mask other than 0xffff is a read-modify-write
 *   type 2  delay only
 *   type 3  skip
 *   type 4  reg = read(value) ^ mask  (TFA key-2 unlock: 0xa0 = 0xfb ^ 0x5a)
 *   type 1, 5  read (status registers; logged with -v)
 * then sleep delay_ms.
 *
 *   matepad-tfa9874 init | on | off
 *   matepad-tfa9874 regs [reg...]          read registers of each amp
 *   matepad-tfa9874 slots S0 S1 S2 S3      make amp n play TDM slot Sn
 *   matepad-tfa9874 watch [pcm-status]     init, then amps on while the
 *       playback PCM is prepared/running (default
 *       /proc/asound/card0/pcm0p/sub0/status), slots follow the orientation
 *       in MATEPAD_ORIENTATION_FILE (default /run/matepad-orientation, from
 *       matepad-volkeys) as set in MATEPAD_SMARTPA_SLOTS, e.g.
 *       "right-up=0101 left-up=1010" (digit n = slot of amp n).
 *
 * MATEPAD_TFA_BUS=/dev/i2c-N overrides the bus lookup.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define N_AMPS 4
#define AMP_ADDR0 0x34
#define BUS_OF_NAME "i2c@98c000"

#define NODE_WRITE 0
#define NODE_READ 1
#define NODE_DELAY 2
#define NODE_SKIP 3
#define NODE_RXORW 4
#define NODE_READ5 5

struct node {
	unsigned int reg, mask, value, delay, type;
};

static int bus = -1;
static int verbose;

static const char *cfg_dir(void)
{
	const char *d = getenv("MATEPAD_SMARTPA_DIR");
	return d ? d : "/usr/local/share/matepad-sound/smartpa";
}

static void msleep(unsigned int ms)
{
	struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

/* /dev/i2c-N of the adapter whose DT node is i2c@98c000. */
static int open_bus(void)
{
	const char *env = getenv("MATEPAD_TFA_BUS");
	char path[300], link[512];
	struct dirent *e;
	DIR *d;
	ssize_t n;

	if (env) {
		bus = open(env, O_RDWR);
		if (bus < 0)
			perror(env);
		return bus;
	}
	d = opendir("/sys/class/i2c-dev");
	if (!d) {
		perror("/sys/class/i2c-dev");
		return -1;
	}
	while ((e = readdir(d))) {
		if (strncmp(e->d_name, "i2c-", 4))
			continue;
		snprintf(path, sizeof(path), "/sys/class/i2c-dev/%s/device/of_node",
			 e->d_name);
		n = readlink(path, link, sizeof(link) - 1);
		if (n <= 0)
			continue;
		link[n] = 0;
		if (!strstr(link, BUS_OF_NAME))
			continue;
		snprintf(path, sizeof(path), "/dev/%s", e->d_name);
		bus = open(path, O_RDWR);
		if (bus < 0)
			perror(path);
		break;
	}
	closedir(d);
	if (bus < 0 && !e)
		fprintf(stderr, "no i2c-dev adapter for %s (i2c3 enabled?)\n",
			BUS_OF_NAME);
	return bus;
}

static int tfa_read(int amp, unsigned int reg, unsigned int *val)
{
	uint8_t r = reg, b[2];
	struct i2c_msg m[2] = {
		{ .addr = AMP_ADDR0 + amp, .flags = 0, .len = 1, .buf = &r },
		{ .addr = AMP_ADDR0 + amp, .flags = I2C_M_RD, .len = 2, .buf = b },
	};
	struct i2c_rdwr_ioctl_data x = { m, 2 };

	if (ioctl(bus, I2C_RDWR, &x) != 2)
		return -1;
	*val = (b[0] << 8) | b[1];
	return 0;
}

static int tfa_write(int amp, unsigned int reg, unsigned int val)
{
	uint8_t b[3] = { reg, val >> 8, val & 0xff };
	struct i2c_msg m = { .addr = AMP_ADDR0 + amp, .flags = 0, .len = 3, .buf = b };
	struct i2c_rdwr_ioctl_data x = { &m, 1 };

	if (ioctl(bus, I2C_RDWR, &x) != 1)
		return -1;
	if (verbose)
		fprintf(stderr, "amp%d %02x <- %04x\n", amp, reg, val);
	return 0;
}

static int run_node(int amp, const struct node *n)
{
	unsigned int old = 0, v;
	int ret = 0;

	switch (n->type) {
	case NODE_WRITE:
		v = n->value & 0xffff;
		if ((n->mask & 0xffff) != 0xffff) {
			ret = tfa_read(amp, n->reg, &old);
			v = (old & ~n->mask) | (n->value & n->mask);
		}
		if (!ret)
			ret = tfa_write(amp, n->reg, v & 0xffff);
		break;
	case NODE_RXORW:
		ret = tfa_read(amp, n->value, &old);
		if (!ret)
			ret = tfa_write(amp, n->reg, (old ^ n->mask) & 0xffff);
		break;
	case NODE_READ:
	case NODE_READ5:
		ret = tfa_read(amp, n->reg, &old);
		if (!ret && verbose)
			fprintf(stderr, "amp%d %02x = %04x\n", amp, n->reg, old);
		break;
	case NODE_DELAY:
	case NODE_SKIP:
		break;
	default:
		fprintf(stderr, "amp%d: unknown node type %u (reg %02x), skipped\n",
			amp, n->type, n->reg);
	}
	if (ret)
		fprintf(stderr, "amp%d (0x%02x): i2c error at reg %02x: %s\n",
			amp, AMP_ADDR0 + amp, n->reg, strerror(errno));
	if (n->type != NODE_SKIP && n->delay)
		msleep(n->delay);
	return ret;
}

static char *read_file(const char *path)
{
	FILE *f = fopen(path, "r");
	char *buf;
	long n;

	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = calloc(1, n + 1);
	if (buf && fread(buf, 1, n, f) != (size_t)n) {
		free(buf);
		buf = NULL;
	}
	fclose(f);
	return buf;
}

/* Parse SCENCE NAME="scene" VALUE="{ ... }" of one config file. */
static int load_scene(const char *path, const char *scene, struct node **nodes)
{
	char key[128];
	char *xml, *p, *end, *q;
	unsigned int vals[4096];
	int n = 0;

	xml = read_file(path);
	if (!xml) {
		fprintf(stderr, "cannot read %s\n", path);
		return -1;
	}
	snprintf(key, sizeof(key), "NAME=\"%s\"", scene);
	p = strstr(xml, key);
	p = p ? strstr(p, "VALUE=\"{") : NULL;
	end = p ? strstr(p, "}\"") : NULL;
	if (!end) {
		fprintf(stderr, "scene %s not in %s\n", scene, path);
		free(xml);
		return -1;
	}
	*end = 0;
	q = p + 8;
	while (*q) {
		char *next;
		if (*q == '#') {               /* "# comment #" */
			char *c = strchr(q + 1, '#');
			q = c ? c + 1 : q + strlen(q);
			continue;
		}
		if (*q == ',' || *q == ' ' || *q == '\t' || *q == '\r' || *q == '\n') {
			q++;
			continue;
		}
		unsigned long v = strtoul(q, &next, 0);
		if (next == q) {
			fprintf(stderr, "%s/%s: bad token near '%.12s'\n", path, scene, q);
			free(xml);
			return -1;
		}
		if (n >= (int)(sizeof(vals) / sizeof(vals[0]))) {
			free(xml);
			return -1;
		}
		vals[n++] = (unsigned int)v;
		q = next;
	}
	free(xml);
	if (n == 0 || n % 5) {
		fprintf(stderr, "%s/%s: %d values, not whole nodes\n", path, scene, n);
		return -1;
	}
	*nodes = malloc(n * sizeof(unsigned int));
	memcpy(*nodes, vals, n * sizeof(unsigned int));
	return n / 5;
}

/* Run `scene` on every amp, node by node in step (as smartpakit's W_ALL). */
static int run_scene(const char *scene)
{
	struct node *lists[N_AMPS] = { 0 };
	int counts[N_AMPS], i, j, max = 0, err = 0;

	for (i = 0; i < N_AMPS; i++) {
		char path[512];

		snprintf(path, sizeof(path), "%s/nxp/tfa9874_%d_configs.xml",
			 cfg_dir(), i);
		counts[i] = load_scene(path, scene, &lists[i]);
		if (counts[i] < 0) {
			while (i--)
				free(lists[i]);
			return -1;
		}
		if (counts[i] > max)
			max = counts[i];
	}
	for (j = 0; j < max; j++)
		for (i = 0; i < N_AMPS; i++)
			if (j < counts[i] && run_node(i, &lists[i][j]))
				err = -1;
	for (i = 0; i < N_AMPS; i++)
		free(lists[i]);
	return err;
}

/* Print registers of every amp (0x00 SYS_CTRL0, 0x10-0x13 status). */
static int cmd_regs(int argc, char **argv)
{
	static const unsigned int def[] = { 0x00, 0x01, 0x03, 0x10, 0x11, 0x13, 0x26, 0x61 };
	unsigned int regs[32], v;
	int n = 0, i, amp;

	for (i = 0; i < argc && n < 32; i++)
		regs[n++] = strtoul(argv[i], NULL, 0);
	if (n == 0)
		for (n = 0; n < (int)(sizeof(def) / sizeof(def[0])); n++)
			regs[n] = def[n];
	for (amp = 0; amp < N_AMPS; amp++) {
		printf("amp%d (0x%02x):", amp, AMP_ADDR0 + amp);
		for (i = 0; i < n; i++) {
			if (tfa_read(amp, regs[i], &v))
				printf(" %02x=err", regs[i]);
			else
				printf(" %02x=%04x", regs[i], v);
		}
		printf("\n");
	}
	return 0;
}

/* TFA9874 TDM config 6: bits 0-3 = slot of sink 0 (speaker) */
#define TFA_REG_TDMCFG6 0x26
#define TFA_TDMSPKS_MASK 0x000f

static int write_slots(const int slot[N_AMPS])
{
	struct node n = { TFA_REG_TDMCFG6, TFA_TDMSPKS_MASK, 0, 0, NODE_WRITE };
	int i, err = 0;

	for (i = 0; i < N_AMPS; i++) {
		n.value = slot[i] & TFA_TDMSPKS_MASK;
		if (run_node(i, &n))
			err = -1;
	}
	return err;
}

static int cmd_slots(int argc, char **argv)
{
	int slot[N_AMPS] = { 0, 1, 2, 3 }, i;

	for (i = 0; i < argc && i < N_AMPS; i++)
		slot[i] = strtol(argv[i], NULL, 0);
	return write_slots(slot) < 0;
}

static const char *orientation_file(void)
{
	const char *f = getenv("MATEPAD_ORIENTATION_FILE");
	return f ? f : "/run/matepad-orientation";
}

static void read_orientation(char *out, size_t len)
{
	FILE *f = fopen(orientation_file(), "r");

	out[0] = 0;
	if (!f)
		return;
	if (!fgets(out, len, f))
		out[0] = 0;
	fclose(f);
	out[strcspn(out, " \t\r\n")] = 0;
}

/* Entry `name` of MATEPAD_SMARTPA_SLOTS ("name=0123 ..."); 0 if absent. */
static int slots_entry(const char *name, int slot[N_AMPS])
{
	const char *map = getenv("MATEPAD_SMARTPA_SLOTS"), *p;
	size_t n = strlen(name);
	int i;

	if (!map || !n)
		return 0;
	for (p = map; (p = strstr(p, name)); p += n) {
		if ((p != map && p[-1] != ' ' && p[-1] != ',') || p[n] != '=')
			continue;
		p += n + 1;
		for (i = 0; i < N_AMPS && p[i] >= '0' && p[i] <= '7'; i++)
			slot[i] = p[i] - '0';
		return 1;
	}
	return 0;
}

/* Slots for `orient`, else the "default" entry, else Huawei's 0123. */
static void slots_for(const char *orient, int slot[N_AMPS])
{
	int i;

	for (i = 0; i < N_AMPS; i++)
		slot[i] = i;
	if (!slots_entry(orient, slot))
		slots_entry("default", slot);
}

static int apply_orientation(const char *orient)
{
	int slot[N_AMPS];

	slots_for(orient, slot);
	if (write_slots(slot) < 0)
		return -1;
	fprintf(stderr, "orientation %s: amp slots %d%d%d%d\n",
		*orient ? orient : "(none)", slot[0], slot[1], slot[2], slot[3]);
	return 0;
}

static volatile sig_atomic_t stop;
static void on_signal(int sig) { (void)sig; stop = 1; }

static int pcm_active(const char *status)
{
	char buf[64] = { 0 };
	int fd = open(status, O_RDONLY), n;

	if (fd < 0)
		return 0;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0 || strncmp(buf, "state:", 6))
		return 0;          /* "closed" */
	return strstr(buf, "RUNNING") || strstr(buf, "PREPARED") ||
	       strstr(buf, "DRAINING") || strstr(buf, "XRUN") ||
	       strstr(buf, "PAUSED");
}

static int cmd_watch(const char *status)
{
	struct timespec ts = { 0, 20 * 1000 * 1000 };
	char orient[32] = "", now[32];
	int on = 0, tick = 0;

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	if (run_scene("INIT_CHIP") < 0)
		fprintf(stderr, "init had errors\n");
	fprintf(stderr, "watching %s, orientation from %s\n", status, orientation_file());
	while (!stop) {
		int want = pcm_active(status);
		if (want != on) {
			if (run_scene(want ? "POWER_ON_L" : "POWER_OFF_L") == 0) {
				fprintf(stderr, "amps %s\n", want ? "on" : "off");
				on = want;
				/* POWER_ON_L rewrites reg 0x26 of amps 2 and 3 */
				if (on) {
					read_orientation(orient, sizeof(orient));
					apply_orientation(orient);
				}
			} else {
				/* retry in a second rather than spin */
				sleep(1);
			}
		} else if (on && ++tick % 5 == 0) {
			read_orientation(now, sizeof(now));
			if (*now && strcmp(now, orient)) {
				snprintf(orient, sizeof(orient), "%s", now);
				apply_orientation(orient);
			}
		}
		nanosleep(&ts, NULL);
	}
	if (on)
		run_scene("POWER_OFF_L");
	return 0;
}

int main(int argc, char **argv)
{
	const char *cmd;
	int ret;

	if (argc > 1 && !strcmp(argv[1], "-v")) {
		verbose = 1;
		argv++;
		argc--;
	}
	cmd = argc > 1 ? argv[1] : "regs";
	setvbuf(stderr, NULL, _IOLBF, 0);
	if (open_bus() < 0)
		return 1;
	if (!strcmp(cmd, "init"))
		ret = run_scene("INIT_CHIP") < 0;
	else if (!strcmp(cmd, "on"))
		ret = run_scene("POWER_ON_L") < 0;
	else if (!strcmp(cmd, "off"))
		ret = run_scene("POWER_OFF_L") < 0;
	else if (!strcmp(cmd, "regs"))
		ret = cmd_regs(argc - 2, argv + 2);
	else if (!strcmp(cmd, "slots"))
		ret = cmd_slots(argc - 2, argv + 2);
	else if (!strcmp(cmd, "watch"))
		ret = cmd_watch(argc > 2 ? argv[2] :
				"/proc/asound/card0/pcm0p/sub0/status");
	else {
		fprintf(stderr, "usage: %s [-v] init|on|off|regs [reg...]|slots S0 S1 S2 S3|watch [pcm-status]\n", argv[0]);
		ret = 2;
	}
	close(bus);
	return ret;
}
