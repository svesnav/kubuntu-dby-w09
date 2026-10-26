/*
 * matepad-volkeys: volume keys that follow the tablet's orientation, like
 * Android's rotation-aware volume keys, for the MatePad 11 (DBY-W09) under
 * Ubuntu.
 *
 * The two volume keys sit on one edge of the case, so in some orientations
 * the key that points "up" (or right) is Volume Down. The keys come from
 * two input devices: gpio-keys (volume up) and qpnp_pon (power, volume
 * down). This daemon grabs both (EVIOCGRAB, so KWin/libinput no longer see
 * them), re-emits all their key and switch events on one uinput device
 * ("MatePad buttons") and swaps KEY_VOLUMEUP/KEY_VOLUMEDOWN while the
 * accelerometer orientation is in the swap set. The orientation comes from
 * matepad-sensord (net.hadess.SensorProxy on the system bus, iio-sensor-proxy
 * API); the daemon holds an accelerometer claim so it keeps streaming.
 *
 *   MATEPAD_VOLKEYS_SWAP  orientations that swap the keys
 *                         (default "right-up bottom-up"; values: normal,
 *                         bottom-up, left-up, right-up)
 *   MATEPAD_VOLKEYS_DEFAULT  orientation assumed until the sensor reports
 *                         one (default "right-up", the desktop's landscape);
 *                         while it says "undefined" (lying flat) the last
 *                         orientation is kept, as the screen rotation is
 *   MATEPAD_ORIENTATION_FILE  the current orientation is also written here
 *                         (default /run/matepad-orientation) for
 *                         matepad-smartpa, which turns the speakers' stereo
 *                         image with it
 *   MATEPAD_VOLKEYS_INPUTS  comma-separated input device names to grab
 *                         (default "gpio-keys,qpnp_pon", the 4.19 kernel;
 *                         Linux 7.0: "gpio-keys,pm8941_resin,pm8941_pwrkey")
 *   matepad-volkeys -v    log every key and orientation change
 *
 * The magnetic cover (2026-10-21): the AK8789 hall driver reports its three
 * sensors (bit 0x01 cover closed over the screen, 0x04 keyboard in the stand,
 * 0x10 pen on its magnet) on /dev/apsensorhub (blocking read, no poll; one
 * packet per read: 8-byte timestamp, sensor type 101 at byte 8, the bits at
 * byte 16). A thread reads it. The cover works like the power key, as on
 * Android: closing it while the panel is on sends a KEY_POWER press (Plasma's
 * power button action, "Turn off screen", turns the panel and any monitor
 * off); opening it while the panel is off sends KEY_WAKEUP, which KWin eats
 * and turns the screens on. (A SW_LID switch was tried first: with a monitor
 * connected, KScreen only disabled the panel and PowerDevil's lid action did
 * nothing.) A close counts after MATEPAD_COVER_CLOSE_MS (default 1000) closed:
 * the cover sweeping past while it is opened flickers the sensor for ~0.6 s.
 * The state is also written to /run/matepad-cover (for the sleep hook).
 * MATEPAD_COVER=0 turns this off.
 * Linux 7.0 has no Huawei hall driver: the cover sensor is a gpio-keys
 * SW_LID switch ("matepad-cover", add it to MATEPAD_VOLKEYS_INPUTS). It is
 * grabbed like the keys and fed to the same logic, but not forwarded: a lid
 * switch would make logind/PowerDevil suspend or only disable the panel.
 *
 * After a system suspend, the power key press that woke the tablet arrives
 * here as a normal press; forwarded, PowerDevil would turn the screen off
 * again at once. A press within 2 s of a resume (CLOCK_BOOTTIME jumped ahead
 * of CLOCK_MONOTONIC) is dropped if the screen is already on (the sleep hook
 * turns it on); while it is still off, KWin gets it and wakes the screens.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>
#include <systemd/sd-bus.h>

#define MAX_DEV 4
#define NBITS(x) ((((x) - 1) / (8 * sizeof(long))) + 1)
#define TEST_BIT(b, a) (((a)[(b) / (8 * sizeof(long))] >> ((b) % (8 * sizeof(long)))) & 1)

static char *dev_names[MAX_DEV];
static unsigned n_dev_names;

static void parse_dev_names(void)
{
	const char *e = getenv("MATEPAD_VOLKEYS_INPUTS");
	char *s = strdup(e && *e ? e : "gpio-keys,qpnp_pon"), *tok;

	for (tok = strtok(s, ","); tok && n_dev_names < MAX_DEV; tok = strtok(NULL, ","))
		dev_names[n_dev_names++] = tok;
}
static int in_fd[MAX_DEV], n_in;
static int out_fd = -1;
static int verbose;
static int swap;
static char orientation[32] = "undefined";
static const char *swap_set;
static volatile sig_atomic_t stop;

#define HALL_SYSFS "/sys/devices/platform/huawei_hall_sensor"
#define HALL_COVER 0x01
static int hall_pipe[2] = { -1, -1 };
static int cover_raw = -1;          /* last sensor state: 1 closed */
static int cover_reported = -1;     /* last state acted on */
static double close_at;             /* report "closed" at this time (0: none) */
static int cover_input = -1;        /* input device with SW_LID (Linux 7.0) */
static int close_ms = 1000;
static double resumed_at = -10;     /* monotonic time of the last resume seen */
static double sleep_offset = -1;    /* CLOCK_BOOTTIME - CLOCK_MONOTONIC */
static int power_drop;              /* dropping a power key press until release */

static void on_signal(int s) { (void)s; stop = 1; }

static int open_inputs(void)
{
	DIR *d = opendir("/sys/class/input");
	struct dirent *e;

	if (!d)
		return -1;
	while ((e = readdir(d)) && n_in < MAX_DEV) {
		char path[300], name[64] = { 0 };
		FILE *f;
		unsigned i;

		if (strncmp(e->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/sys/class/input/%s/device/name", e->d_name);
		f = fopen(path, "r");
		if (!f)
			continue;
		if (!fgets(name, sizeof(name), f))
			name[0] = 0;
		fclose(f);
		name[strcspn(name, "\n")] = 0;
		for (i = 0; i < n_dev_names; i++) {
			if (strcmp(name, dev_names[i]))
				continue;
			snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
			int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
			if (fd < 0) {
				/* this boot's devtmpfs may lack the node */
				char dev[300]; unsigned ma, mi;
				snprintf(dev, sizeof(dev), "/sys/class/input/%s/dev", e->d_name);
				FILE *g = fopen(dev, "r");
				if (g && fscanf(g, "%u:%u", &ma, &mi) == 2 &&
				    mknod(path, 020660, makedev(ma, mi)) == 0)
					fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
				if (g)
					fclose(g);
			}
			if (fd < 0) {
				fprintf(stderr, "%s (%s): %s\n", path, name, strerror(errno));
				continue;
			}
			fprintf(stderr, "input %s = %s\n", path, name);
			in_fd[n_in++] = fd;
		}
	}
	closedir(d);
	return n_in;
}

/* One uinput device with the union of the inputs' key and switch bits. */
static int create_output(void)
{
	struct uinput_setup us;
	int fd, i, b, has_sw = 0;

	fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		perror("/dev/uinput");
		return -1;
	}
	ioctl(fd, UI_SET_EVBIT, EV_KEY);
	ioctl(fd, UI_SET_EVBIT, EV_SYN);
	for (i = 0; i < n_in; i++) {
		unsigned long keys[NBITS(KEY_CNT)] = { 0 }, sws[NBITS(SW_CNT)] = { 0 };

		ioctl(in_fd[i], EVIOCGBIT(EV_KEY, sizeof(keys)), keys);
		for (b = 0; b < KEY_CNT; b++)
			if (TEST_BIT(b, keys))
				ioctl(fd, UI_SET_KEYBIT, b);
		if (ioctl(in_fd[i], EVIOCGBIT(EV_SW, sizeof(sws)), sws) > 0)
			for (b = 0; b < SW_CNT; b++)
				if (TEST_BIT(b, sws) && b != SW_LID) {      /* the cover: not forwarded */
					if (!has_sw++)
						ioctl(fd, UI_SET_EVBIT, EV_SW);
					ioctl(fd, UI_SET_SWBIT, b);
				}
	}
	/* both directions must exist whatever the swap */
	ioctl(fd, UI_SET_KEYBIT, KEY_VOLUMEUP);
	ioctl(fd, UI_SET_KEYBIT, KEY_VOLUMEDOWN);
	ioctl(fd, UI_SET_KEYBIT, KEY_WAKEUP);    /* cover opened while the screen is off */
	memset(&us, 0, sizeof(us));
	us.id.bustype = BUS_HOST;
	us.id.vendor = 0x12d1;   /* Huawei */
	us.id.product = 0x0b01;
	snprintf(us.name, sizeof(us.name), "MatePad buttons");
	if (ioctl(fd, UI_DEV_SETUP, &us) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
		perror("uinput create");
		close(fd);
		return -1;
	}
	return fd;
}

/*
 * This boot's /dev is populated once at boot (codex-devices.service), not by
 * devtmpfs, so the uinput device's event node must be made here, or KWin
 * cannot open it and the grabbed keys would go nowhere.
 */
static int make_output_node(void)
{
	char sysname[64] = { 0 }, path[128], node[300];
	struct dirent *e;
	DIR *d;
	int ok = 0;

	if (ioctl(out_fd, UI_GET_SYSNAME(sizeof(sysname)), sysname) < 0) {
		perror("UI_GET_SYSNAME");
		return -1;
	}
	snprintf(path, sizeof(path), "/sys/devices/virtual/input/%s", sysname);
	d = opendir(path);
	if (!d) {
		perror(path);
		return -1;
	}
	while ((e = readdir(d))) {
		unsigned ma, mi;
		char dev[420];
		FILE *f;

		if (strncmp(e->d_name, "event", 5))
			continue;
		snprintf(dev, sizeof(dev), "%s/%s/dev", path, e->d_name);
		f = fopen(dev, "r");
		if (!f)
			continue;
		if (fscanf(f, "%u:%u", &ma, &mi) == 2) {
			struct stat st;

			snprintf(node, sizeof(node), "/dev/input/%s", e->d_name);
			if (stat(node, &st) == 0 && S_ISCHR(st.st_mode) && st.st_rdev == makedev(ma, mi))
				ok = 1;
			else {
				unlink(node);
				ok = mknod(node, S_IFCHR | 0660, makedev(ma, mi)) == 0;
				if (!ok)
					perror(node);
			}
			if (ok)
				fprintf(stderr, "output %s (%s)\n", node, sysname);
		}
		fclose(f);
	}
	closedir(d);
	return ok ? 0 : -1;
}

static void emit(int type, int code, int value)
{
	struct input_event ev;

	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = value;
	if (write(out_fd, &ev, sizeof(ev)) < 0 && verbose)
		perror("uinput write");
}

static double now_clock(clockid_t c)
{
	struct timespec ts;

	clock_gettime(c, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* A system suspend shows as CLOCK_BOOTTIME running ahead of CLOCK_MONOTONIC. */
static void check_resume(void)
{
	double mono = now_clock(CLOCK_MONOTONIC);
	double off = now_clock(CLOCK_BOOTTIME) - mono;

	if (sleep_offset >= 0 && off - sleep_offset > 0.5) {
		resumed_at = mono;
		fprintf(stderr, "resumed after %.1f s of suspend\n", off - sleep_offset);
	}
	sleep_offset = off;
}

/* KWin's DPMS state of the panel, as the DRM connector reports it. */
static int panel_off(void)
{
	char buf[16] = { 0 };
	FILE *f = fopen("/sys/class/drm/card0-DSI-1/dpms", "r");

	if (!f)
		return 0;
	if (!fgets(buf, sizeof(buf), f))
		buf[0] = 0;
	fclose(f);
	return !strncmp(buf, "Off", 3);
}

/* -- magnetic cover ------------------------------------------------------ */
static void write_cover(int closed)
{
	FILE *f = fopen("/run/matepad-cover.tmp", "w");

	if (!f)
		return;
	fprintf(f, "%s\n", closed ? "closed" : "open");
	if (fclose(f) == 0)
		rename("/run/matepad-cover.tmp", "/run/matepad-cover");
}

static void tap(int code)
{
	emit(EV_KEY, code, 1);
	emit(EV_SYN, SYN_REPORT, 0);
	emit(EV_KEY, code, 0);
	emit(EV_SYN, SYN_REPORT, 0);
}

/* act = 0 at start-up: only remember the state */
static void report_cover(int closed, int act)
{
	int off;

	if (closed == cover_reported)
		return;
	cover_reported = closed;
	write_cover(closed);
	if (!act)
		return;
	off = panel_off();
	if (closed && !off) {
		tap(KEY_POWER);
		fprintf(stderr, "cover closed: power key (screens off)\n");
	} else if (!closed && off) {
		tap(KEY_WAKEUP);
		fprintf(stderr, "cover opened: wake-up key (screens on)\n");
	} else {
		fprintf(stderr, "cover %s (screens already %s)\n", closed ? "closed" : "opened",
			off ? "off" : "on");
	}
}

/* New sensor state from the hall thread (or the start-up read). */
static void cover_changed(int value, int at_start)
{
	int closed = !!(value & HALL_COVER);

	if (verbose)
		fprintf(stderr, "hall 0x%02x\n", value);
	cover_raw = closed;
	if (!closed) {
		close_at = 0;
		report_cover(0, !at_start);
	} else if (at_start) {
		report_cover(1, 0);
	} else if (cover_reported != 1 && !close_at) {
		close_at = now_clock(CLOCK_MONOTONIC) + close_ms / 1000.0;
	}
}

static int open_hall(void)
{
	unsigned ma, mi;
	int fd = open("/dev/apsensorhub", O_RDONLY | O_CLOEXEC);
	FILE *f;

	if (fd >= 0)
		return fd;
	/* this boot's static /dev lacks the node */
	f = fopen("/sys/class/misc/apsensorhub/dev", "r");
	if (f && fscanf(f, "%u:%u", &ma, &mi) == 2)
		mknod("/dev/apsensorhub", S_IFCHR | 0600, makedev(ma, mi));
	if (f)
		fclose(f);
	return open("/dev/apsensorhub", O_RDONLY | O_CLOEXEC);
}

/* The driver's read blocks and has no poll(): read in a thread. */
static void *hall_thread(void *arg)
{
	int fd = (int)(long)arg;
	unsigned char buf[512];

	for (;;) {
		ssize_t n = read(fd, buf, sizeof(buf));
		int value;

		if (n < 0 && errno != EINTR) {
			perror("/dev/apsensorhub");
			sleep(1);
			continue;
		}
		if (n < 20 || buf[8] != 101)    /* SENSOR_TYPE_AP_HALL */
			continue;
		memcpy(&value, buf + 16, sizeof(value));
		if (write(hall_pipe[1], &value, sizeof(value)) < 0)
			perror("hall pipe");
	}
	return NULL;
}

static int read_hall_sysfs(void)
{
	int v = -1;
	FILE *f = fopen(HALL_SYSFS "/get_hall_status", "r");

	if (f) {
		if (fscanf(f, "%d", &v) != 1)
			v = -1;
		fclose(f);
	}
	return v;
}

static void start_cover(void)
{
	const char *e = getenv("MATEPAD_COVER");
	pthread_t t;
	FILE *f;
	int fd, v;

	if (e && !strcmp(e, "0"))
		return;
	if (getenv("MATEPAD_COVER_CLOSE_MS"))
		close_ms = atoi(getenv("MATEPAD_COVER_CLOSE_MS"));
	for (v = 0; v < n_in; v++) {
		unsigned long sws[NBITS(SW_CNT)] = { 0 };

		if (ioctl(in_fd[v], EVIOCGBIT(EV_SW, sizeof(sws)), sws) > 0 && TEST_BIT(SW_LID, sws)) {
			cover_input = v;
			memset(sws, 0, sizeof(sws));
			if (ioctl(in_fd[v], EVIOCGSW(sizeof(sws)), sws) >= 0)
				cover_changed(TEST_BIT(SW_LID, sws) ? HALL_COVER : 0, 1);
			fprintf(stderr, "cover: lid switch on input %d\n", v);
			return;
		}
	}
	fd = open_hall();
	if (fd < 0) {
		perror("/dev/apsensorhub (no cover switch)");
		return;
	}
	if (pipe2(hall_pipe, O_CLOEXEC | O_NONBLOCK) < 0) {
		close(fd);
		return;
	}
	/* make the driver report every interrupt */
	f = fopen(HALL_SYSFS "/enable_hall_sensor", "w");
	if (f) {
		fputs("1\n", f);
		fclose(f);
	}
	if (pthread_create(&t, NULL, hall_thread, (void *)(long)fd)) {
		fprintf(stderr, "hall thread failed\n");
		return;
	}
	v = read_hall_sysfs();
	if (v >= 0)
		cover_changed(v, 1);
}

static int in_swap_set(const char *o)
{
	const char *p = swap_set;
	size_t n = strlen(o);

	while ((p = strstr(p, o))) {
		if ((p == swap_set || p[-1] == ' ' || p[-1] == ',') &&
		    (p[n] == 0 || p[n] == ' ' || p[n] == ','))
			return 1;
		p += n;
	}
	return 0;
}

/* Publish the orientation for matepad-smartpa (atomic rename). */
static void write_orientation(void)
{
	const char *path = getenv("MATEPAD_ORIENTATION_FILE");
	char tmp[300];
	FILE *f;

	if (!path)
		path = "/run/matepad-orientation";
	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	f = fopen(tmp, "w");
	if (!f) {
		perror(tmp);
		return;
	}
	fprintf(f, "%s\n", orientation);
	if (fclose(f) == 0)
		rename(tmp, path);
}

static void read_orientation(sd_bus *bus)
{
	char *o = NULL;

	if (sd_bus_get_property_string(bus, "net.hadess.SensorProxy", "/net/hadess/SensorProxy",
				       "net.hadess.SensorProxy", "AccelerometerOrientation",
				       NULL, &o) < 0 || !o)
		return;
	/* "undefined" (flat or unknown) keeps the last state */
	if (strcmp(o, "undefined") && strcmp(o, orientation)) {
		snprintf(orientation, sizeof(orientation), "%s", o);
		swap = in_swap_set(orientation);
		fprintf(stderr, "orientation %s: volume keys %s\n", orientation,
			swap ? "swapped" : "normal");
		write_orientation();
	}
	free(o);
}

static int on_props(sd_bus_message *m, void *u, sd_bus_error *e)
{
	(void)m; (void)e;
	read_orientation(u);
	return 0;
}

/* (Re)claim the accelerometer whenever sensord (re)appears. */
static void claim(sd_bus *bus)
{
	sd_bus_error err = SD_BUS_ERROR_NULL;

	if (sd_bus_call_method(bus, "net.hadess.SensorProxy", "/net/hadess/SensorProxy",
			       "net.hadess.SensorProxy", "ClaimAccelerometer", &err, NULL, "") < 0)
		fprintf(stderr, "ClaimAccelerometer: %s\n", err.message ? err.message : "failed");
	sd_bus_error_free(&err);
	read_orientation(bus);
}

static int on_owner(sd_bus_message *m, void *u, sd_bus_error *e)
{
	const char *name, *old, *new;

	(void)e;
	if (sd_bus_message_read(m, "sss", &name, &old, &new) >= 0 && new && *new)
		claim(u);
	return 0;
}

int main(int argc, char **argv)
{
	sd_bus *bus = NULL;
	struct pollfd pfd[MAX_DEV + 2];
	int i, r;

	verbose = argc > 1 && !strcmp(argv[1], "-v");
	parse_dev_names();
	swap_set = getenv("MATEPAD_VOLKEYS_SWAP");
	if (!swap_set)
		swap_set = "right-up bottom-up";
	snprintf(orientation, sizeof(orientation), "%s",
		 getenv("MATEPAD_VOLKEYS_DEFAULT") ? getenv("MATEPAD_VOLKEYS_DEFAULT") : "right-up");
	swap = in_swap_set(orientation);
	fprintf(stderr, "start as %s: volume keys %s\n", orientation, swap ? "swapped" : "normal");
	setvbuf(stderr, NULL, _IOLBF, 0);
	write_orientation();
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);

	if (open_inputs() <= 0) {
		fprintf(stderr, "none of the MATEPAD_VOLKEYS_INPUTS devices found\n");
		return 1;
	}
	out_fd = create_output();
	if (out_fd < 0)
		return 1;
	/* Without a usable output node, grabbing would kill the keys: leave
	 * them to KWin unswapped instead. */
	if (make_output_node() < 0) {
		fprintf(stderr, "no event node for the uinput device; not grabbing\n");
		ioctl(out_fd, UI_DEV_DESTROY);
		return 1;
	}
	start_cover();
	/* give udev/libinput a moment to add the new device before we grab */
	usleep(300000);
	for (i = 0; i < n_in; i++)
		if (ioctl(in_fd[i], EVIOCGRAB, 1) < 0)
			perror("EVIOCGRAB");

	r = sd_bus_open_system(&bus);
	if (r < 0) {
		fprintf(stderr, "system bus: %s (keys stay unswapped)\n", strerror(-r));
		bus = NULL;
	} else {
		r = sd_bus_match_signal(bus, NULL, "net.hadess.SensorProxy", "/net/hadess/SensorProxy",
					"org.freedesktop.DBus.Properties", "PropertiesChanged", on_props, bus);
		if (r < 0)
			fprintf(stderr, "PropertiesChanged match: %s\n", strerror(-r));
		r = sd_bus_match_signal(bus, NULL, "org.freedesktop.DBus", "/org/freedesktop/DBus",
					"org.freedesktop.DBus", "NameOwnerChanged", on_owner, bus);
		if (r < 0)
			fprintf(stderr, "NameOwnerChanged match: %s\n", strerror(-r));
		claim(bus);
	}
	fprintf(stderr, "swap set \"%s\"; forwarding %d devices\n", swap_set, n_in);

	check_resume();
	while (!stop) {
		int n = 0, ready, timeout = bus ? 1000 : -1, hall_i = -1;

		/* messages read during synchronous calls wait in sd-bus's queue,
		 * where poll() cannot see them */
		if (bus)
			while (sd_bus_process(bus, NULL) > 0)
				;
		for (i = 0; i < n_in; i++) {
			pfd[n].fd = in_fd[i];
			pfd[n++].events = POLLIN;
		}
		if (hall_pipe[0] >= 0) {
			hall_i = n;
			pfd[n].fd = hall_pipe[0];
			pfd[n++].events = POLLIN;
		}
		if (bus) {
			pfd[n].fd = sd_bus_get_fd(bus);
			pfd[n].events = sd_bus_get_events(bus);
			n++;
		}
		if (close_at) {
			int ms = (int)((close_at - now_clock(CLOCK_MONOTONIC)) * 1000) + 1;

			if (ms < 0)
				ms = 0;
			if (timeout < 0 || ms < timeout)
				timeout = ms;
		}
		/* Also re-read the orientation every second: in one boot
		 * (2026-10-19) the PropertiesChanged signals never arrived. */
		ready = poll(pfd, n, timeout);
		if (ready < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		check_resume();
		if (close_at && now_clock(CLOCK_MONOTONIC) >= close_at) {
			close_at = 0;
			if (cover_raw == 1)
				report_cover(1, 1);
		}
		if (ready == 0) {
			read_orientation(bus);
			continue;
		}
		if (hall_i >= 0 && (pfd[hall_i].revents & POLLIN)) {
			int v;

			while (read(hall_pipe[0], &v, sizeof(v)) == sizeof(v))
				cover_changed(v, 0);
		}
		for (i = 0; i < n_in; i++) {
			struct input_event ev[16];
			ssize_t len;

			if (!(pfd[i].revents & POLLIN))
				continue;
			while ((len = read(in_fd[i], ev, sizeof(ev))) > 0) {
				for (size_t k = 0; k < len / sizeof(ev[0]); k++) {
					int code = ev[k].code;

					if (ev[k].type == EV_SW && code == SW_LID) {
						if (cover_input >= 0)
							cover_changed(ev[k].value ? HALL_COVER : 0, 0);
						continue;
					}

					if (ev[k].type == EV_KEY && code == KEY_POWER) {
						/* the press that woke the system, once the
						 * sleep hook has turned the screens on (while
						 * they are off, KWin eats it and wakes them) */
						if (ev[k].value == 1 && !panel_off() &&
						    now_clock(CLOCK_MONOTONIC) - resumed_at < 2.0) {
							power_drop = 1;
							fprintf(stderr, "power key right after resume: dropped\n");
						}
						if (power_drop) {
							if (ev[k].value == 0)
								power_drop = 0;
							continue;
						}
					}
					if (ev[k].type == EV_KEY && swap) {
						if (code == KEY_VOLUMEUP)
							code = KEY_VOLUMEDOWN;
						else if (code == KEY_VOLUMEDOWN)
							code = KEY_VOLUMEUP;
					}
					if (ev[k].type == EV_KEY || ev[k].type == EV_SW ||
					    ev[k].type == EV_SYN) {
						if (verbose && ev[k].type == EV_KEY)
							fprintf(stderr, "key %d -> %d value %d\n",
								ev[k].code, code, ev[k].value);
						emit(ev[k].type, code, ev[k].value);
					}
				}
			}
		}
		if (bus)
			while (sd_bus_process(bus, NULL) > 0)
				;
	}
	for (i = 0; i < n_in; i++)
		ioctl(in_fd[i], EVIOCGRAB, 0);
	ioctl(out_fd, UI_DEV_DESTROY);
	return 0;
}
