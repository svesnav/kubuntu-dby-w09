/*
 * matepad-sensord: accelerometer -> screen orientation for the MatePad 11
 * (DBY-W09, SM8250) under Ubuntu.
 *
 * The accelerometer is not an IIO or input device on the Huawei 4.19 kernel:
 * it sits behind the SLPI sensor DSP and is reached over QRTR with Qualcomm's
 * QMI "SEE" sensor client service (service 400), whose payloads are protobuf
 * (sns_client.proto, sns_suid.proto, sns_std_sensor.proto).  This daemon
 *   1. finds the "accel" sensor through the SUID lookup sensor,
 *   2. streams it at a low rate while a client holds a claim,
 *   3. turns gravity into normal / bottom-up / left-up / right-up and
 *   4. publishes it as net.hadess.SensorProxy on the system bus (the
 *      iio-sensor-proxy API that QtSensors, and so KWin, use).
 *
 * Build without -DWITH_SDBUS for a static test tool that only prints
 * readings (-d); that runs on HarmonyOS as well.
 *
 *   matepad-sensord          D-Bus service (needs WITH_SDBUS)
 *   matepad-sensord -d [n]   print n accel samples and orientations, exit
 */
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#ifdef WITH_SDBUS
#include <systemd/sd-bus.h>
#endif

#ifndef AF_QIPCRTR
#define AF_QIPCRTR 42
#endif
struct sockaddr_qrtr {
    unsigned short sq_family;
    uint32_t sq_node;
    uint32_t sq_port;
};
#define QRTR_PORT_CTRL 0xfffffffeu
#define QRTR_TYPE_NEW_SERVER 4
#define QRTR_TYPE_DEL_SERVER 5
#define QRTR_TYPE_NEW_LOOKUP 10
struct qrtr_ctrl_pkt {
    uint32_t cmd;
    uint32_t service, instance, node, port;
};

#define SNS_CLIENT_SVC 400
#define QMI_REQUEST 0
#define QMI_RESPONSE 2
#define QMI_INDICATION 4
#define SNS_CLIENT_REQ 0x20
#define SNS_CLIENT_REPORT_IND 0x21
#define SNS_CLIENT_JUMBO_REPORT_IND 0x22

/* SEE message ids */
#define SNS_CLIENT_MSGID_DISABLE_REQ 10
#define SNS_SUID_MSGID_REQ 512
#define SNS_SUID_MSGID_EVENT 768
#define SNS_STD_SENSOR_MSGID_CONFIG 513
#define SNS_STD_SENSOR_MSGID_EVENT 1025
#define SNS_STD_MSGID_ATTR_REQ 1
#define SNS_STD_MSGID_ATTR_EVENT 128
#define SNS_STD_SENSOR_ATTRID_NAME 0
#define SNS_STD_SENSOR_ATTRID_VENDOR 1

static int verbose;
static volatile sig_atomic_t quit;
static void logmsg(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}
#define dbg(...) do { if (verbose) logmsg(__VA_ARGS__); } while (0)

/* ---------- minimal protobuf ---------- */
struct pb {
    uint8_t buf[512];
    size_t len;
};
static void pb_byte(struct pb *p, uint8_t b) { if (p->len < sizeof(p->buf)) p->buf[p->len++] = b; }
static void pb_varint(struct pb *p, uint64_t v)
{
    while (v >= 0x80) { pb_byte(p, (uint8_t)(v | 0x80)); v >>= 7; }
    pb_byte(p, (uint8_t)v);
}
static void pb_tag(struct pb *p, unsigned field, unsigned wt) { pb_varint(p, (field << 3) | wt); }
static void pb_fixed64(struct pb *p, unsigned field, uint64_t v)
{
    pb_tag(p, field, 1);
    for (int i = 0; i < 8; i++) pb_byte(p, (uint8_t)(v >> (8 * i)));
}
static void pb_fixed32(struct pb *p, unsigned field, uint32_t v)
{
    pb_tag(p, field, 5);
    for (int i = 0; i < 4; i++) pb_byte(p, (uint8_t)(v >> (8 * i)));
}
static void pb_float(struct pb *p, unsigned field, float f)
{
    uint32_t v;
    memcpy(&v, &f, 4);
    pb_fixed32(p, field, v);
}
static void pb_uint(struct pb *p, unsigned field, uint64_t v) { pb_tag(p, field, 0); pb_varint(p, v); }
static void pb_bytes(struct pb *p, unsigned field, const void *d, size_t n)
{
    pb_tag(p, field, 2);
    pb_varint(p, n);
    for (size_t i = 0; i < n; i++) pb_byte(p, ((const uint8_t *)d)[i]);
}
static void pb_msg(struct pb *p, unsigned field, const struct pb *m) { pb_bytes(p, field, m->buf, m->len); }

/* reader */
struct pbr {
    const uint8_t *p, *end;
};
struct pbf {
    unsigned field, wt;
    uint64_t v;            /* varint / fixed */
    const uint8_t *d;      /* length-delimited */
    size_t n;
};
static int pbr_varint(struct pbr *r, uint64_t *v)
{
    *v = 0;
    for (int s = 0; s < 64 && r->p < r->end; s += 7) {
        uint8_t b = *r->p++;
        *v |= (uint64_t)(b & 0x7f) << s;
        if (!(b & 0x80)) return 0;
    }
    return -1;
}
static int pbr_next(struct pbr *r, struct pbf *f)
{
    uint64_t key;
    if (r->p >= r->end || pbr_varint(r, &key)) return 0;
    f->field = (unsigned)(key >> 3);
    f->wt = key & 7;
    f->d = NULL;
    f->n = 0;
    switch (f->wt) {
    case 0: return pbr_varint(r, &f->v) ? 0 : 1;
    case 1:
        if (r->end - r->p < 8) return 0;
        f->v = 0;
        for (int i = 0; i < 8; i++) f->v |= (uint64_t)r->p[i] << (8 * i);
        r->p += 8;
        return 1;
    case 5:
        if (r->end - r->p < 4) return 0;
        f->v = 0;
        for (int i = 0; i < 4; i++) f->v |= (uint64_t)r->p[i] << (8 * i);
        r->p += 4;
        return 1;
    case 2:
        if (pbr_varint(r, &f->v) || (uint64_t)(r->end - r->p) < f->v) return 0;
        f->d = r->p;
        f->n = (size_t)f->v;
        r->p += f->n;
        return 1;
    default: return 0;
    }
}
static float u32_float(uint32_t v) { float f; memcpy(&f, &v, 4); return f; }

/* ---------- QMI over QRTR ---------- */
struct suid { uint64_t lo, hi; };
static const struct suid suid_lookup = { 0xababababababababull, 0xababababababababull };

static int qfd = -1;
static struct sockaddr_qrtr ssc_addr;
static uint16_t txn = 1;

/* -l: list every QRTR service (service 0); also used to find one service */
static int qrtr_find_ssc_service(unsigned service, int timeout_ms)
{
    struct sockaddr_qrtr me;
    socklen_t sl = sizeof(me);
    if (getsockname(qfd, (struct sockaddr *)&me, &sl)) return -1;
    struct sockaddr_qrtr ns = { AF_QIPCRTR, me.sq_node, QRTR_PORT_CTRL };
    struct qrtr_ctrl_pkt pkt = { QRTR_TYPE_NEW_LOOKUP, service, 0, 0, 0 };
    if (sendto(qfd, &pkt, sizeof(pkt), 0, (struct sockaddr *)&ns, sizeof(ns)) < 0) {
        logmsg("qrtr lookup send: %s", strerror(errno));
        return -1;
    }
    struct pollfd pfd = { qfd, POLLIN, 0 };
    while (poll(&pfd, 1, timeout_ms) > 0) {
        struct qrtr_ctrl_pkt r;
        struct sockaddr_qrtr from;
        sl = sizeof(from);
        ssize_t n = recvfrom(qfd, &r, sizeof(r), 0, (struct sockaddr *)&from, &sl);
        if (n < (ssize_t)sizeof(r) || r.cmd != QRTR_TYPE_NEW_SERVER) continue;
        if (!r.service && !r.node && !r.port) break;      /* end of lookup list */
        if (!service) {
            printf("service %u instance 0x%x node %u port %u\n", r.service, r.instance, r.node, r.port);
            continue;
        }
        if (r.service != SNS_CLIENT_SVC) continue;
        logmsg("SEE client service: node %u port %u instance 0x%x", r.node, r.port, r.instance);
        ssc_addr.sq_family = AF_QIPCRTR;
        ssc_addr.sq_node = r.node;
        ssc_addr.sq_port = r.port;
        return 0;
    }
    return -1;
}

static int ssc_send(const struct suid *s, uint32_t msg_id, const struct pb *payload)
{
    struct pb susp = { .len = 0 }, req = { .len = 0 }, suid = { .len = 0 }, m = { .len = 0 };
    pb_fixed64(&suid, 1, s->lo);
    pb_fixed64(&suid, 2, s->hi);
    pb_uint(&susp, 1, 1);           /* client_proc_type = APSS */
    pb_uint(&susp, 2, 1);           /* delivery_type = NO_WAKEUP */
    if (payload) pb_msg(&req, 2, payload);
    pb_msg(&m, 1, &suid);
    pb_fixed32(&m, 2, msg_id);
    pb_msg(&m, 3, &susp);
    pb_msg(&m, 4, &req);

    uint8_t q[600];
    size_t tl = 2 + m.len;
    q[0] = QMI_REQUEST;
    q[1] = txn & 0xff; q[2] = txn >> 8; txn++;
    q[3] = SNS_CLIENT_REQ & 0xff; q[4] = SNS_CLIENT_REQ >> 8;
    size_t body = 3 + tl;
    q[5] = body & 0xff; q[6] = body >> 8;
    q[7] = 0x01;                     /* TLV: payload */
    q[8] = tl & 0xff; q[9] = tl >> 8;
    q[10] = m.len & 0xff; q[11] = m.len >> 8;
    memcpy(q + 12, m.buf, m.len);
    if (sendto(qfd, q, 12 + m.len, 0, (struct sockaddr *)&ssc_addr, sizeof(ssc_addr)) < 0) {
        logmsg("ssc send: %s", strerror(errno));
        return -1;
    }
    dbg("sent msg_id %u (%zu bytes)", msg_id, m.len);
    return 0;
}

/* ---------- sensor state ---------- */
static struct suid accel_suid;
static int have_accel;
static float ax, ay, az;
static int have_sample;
static const char *orient = "undefined";
static int dump_left = -1;

/* SEE reports in the Android frame of the panel's native portrait scanout
 * (1600x2560): x to the right, y to the top, z out of the screen, and
 * +9.81 on the axis that points up.  iio-sensor-proxy's convention is the
 * negation (upright = y -1 g), and the orientation names mean the edge of the
 * native orientation that points up; KScreen turns them into output
 * rotations.  This is iio-sensor-proxy's orientation_calc() (35° thresholds,
 * 5° same-axis hysteresis, no change near the diagonal or when flat).
 * MATEPAD_ACCEL_MAP (bit0 swap x/y, bit1 negate x, bit2 negate y) corrects
 * the mount without a rebuild. */
static int accel_map = 0;
static const char *orientation_from(float x, float y, float z, const char *prev)
{
    if (accel_map & 1) { float t = x; x = y; y = t; }
    if (accel_map & 2) x = -x;
    if (accel_map & 4) y = -y;
    x = -x; y = -y; z = -z;
    int portrait = (int)lroundf(atan2f(x, sqrtf(y * y + z * z)) * 180.0f / (float)M_PI);
    int landscape = (int)lroundf(atan2f(y, sqrtf(x * x + z * z)) * 180.0f / (float)M_PI);
    const char *ret = prev;
    if (abs(portrait) > 35 && abs(landscape) > 35) return prev;
    if (abs(portrait) > 35) {
        ret = portrait > 0 ? "left-up" : "right-up";
        if ((!strcmp(prev, "left-up") || !strcmp(prev, "right-up")) && abs(portrait) < 5) ret = prev;
    } else if (abs(landscape) > 35) {
        ret = landscape > 0 ? "bottom-up" : "normal";
        if ((!strcmp(prev, "bottom-up") || !strcmp(prev, "normal")) && abs(landscape) < 5) ret = prev;
    }
    return ret;
}

static void orientation_changed(void);

static void handle_event(const uint8_t *d, size_t n)
{
    struct pbr r = { d, d + n };
    struct pbf f;
    struct suid from = { 0, 0 };
    while (pbr_next(&r, &f)) {
        if (f.field == 1 && f.wt == 2) {
            struct pbr s = { f.d, f.d + f.n };
            struct pbf g;
            while (pbr_next(&s, &g)) {
                if (g.field == 1) from.lo = g.v;
                if (g.field == 2) from.hi = g.v;
            }
        } else if (f.field == 2 && f.wt == 2) {
            uint32_t msg_id = 0;
            const uint8_t *pl = NULL;
            size_t pn = 0;
            struct pbr e = { f.d, f.d + f.n };
            struct pbf g;
            while (pbr_next(&e, &g)) {
                if (g.field == 1) msg_id = (uint32_t)g.v;
                if (g.field == 3 && g.wt == 2) { pl = g.d; pn = g.n; }
            }
            dbg("event suid %016llx%016llx msg %u len %zu", (unsigned long long)from.hi,
                (unsigned long long)from.lo, msg_id, pn);
            struct pbr p = { pl, pl + pn };
            if (msg_id == SNS_SUID_MSGID_EVENT && from.lo == suid_lookup.lo && from.hi == suid_lookup.hi) {
                char type[64] = "";
                while (pbr_next(&p, &g)) {
                    if (g.field == 1 && g.wt == 2 && g.n < sizeof(type)) {
                        memcpy(type, g.d, g.n);
                        type[g.n] = 0;
                    } else if (g.field == 2 && g.wt == 2) {
                        struct suid s = { 0, 0 };
                        struct pbr q = { g.d, g.d + g.n };
                        struct pbf h;
                        while (pbr_next(&q, &h)) {
                            if (h.field == 1) s.lo = h.v;
                            if (h.field == 2) s.hi = h.v;
                        }
                        logmsg("SUID for \"%s\": %016llx%016llx", type,
                               (unsigned long long)s.hi, (unsigned long long)s.lo);
                        if (!strcmp(type, "accel") && !have_accel) {
                            accel_suid = s;
                            have_accel = 1;
                        }
                    }
                }
            } else if (msg_id == SNS_STD_MSGID_ATTR_EVENT) {
                while (pbr_next(&p, &g)) {
                    if (g.field != 1 || g.wt != 2) continue;
                    struct pbr a = { g.d, g.d + g.n };
                    struct pbf h;
                    int64_t id = -1;
                    while (pbr_next(&a, &h)) {
                        if (h.field == 1) id = (int64_t)h.v;
                        if (h.field == 2 && h.wt == 2 && (id == SNS_STD_SENSOR_ATTRID_NAME ||
                                                          id == SNS_STD_SENSOR_ATTRID_VENDOR)) {
                            struct pbr v = { h.d, h.d + h.n };
                            struct pbf k, s;
                            while (pbr_next(&v, &k)) {
                                struct pbr vd = { k.d, k.d + k.n };
                                while (k.wt == 2 && pbr_next(&vd, &s))
                                    if (s.field == 2 && s.wt == 2)
                                        logmsg("accel %s: %.*s", id ? "vendor" : "name", (int)s.n, s.d);
                            }
                        }
                    }
                }
            } else if (msg_id == SNS_STD_SENSOR_MSGID_EVENT) {
                float v[3] = { 0, 0, 0 };
                int i = 0;
                while (pbr_next(&p, &g)) {
                    if (g.field != 1) continue;
                    if (g.wt == 5 && i < 3) v[i++] = u32_float((uint32_t)g.v);
                    else if (g.wt == 2)       /* packed */
                        for (size_t k = 0; k + 4 <= g.n && i < 3; k += 4)
                            v[i++] = u32_float((uint32_t)g.d[k] | (uint32_t)g.d[k + 1] << 8 |
                                               (uint32_t)g.d[k + 2] << 16 | (uint32_t)g.d[k + 3] << 24);
                }
                if (i < 3) continue;
                ax = v[0]; ay = v[1]; az = v[2];
                have_sample = 1;
                const char *o = orientation_from(ax, ay, az, orient);
                if (dump_left >= 0) {
                    printf("accel %8.3f %8.3f %8.3f  -> %s\n", ax, ay, az, o);
                    fflush(stdout);
                    if (dump_left > 0) dump_left--;
                }
                if (strcmp(o, orient)) {
                    orient = o;
                    orientation_changed();
                }
            }
        }
    }
}

static void handle_qmi(const uint8_t *b, size_t n)
{
    if (n < 7) return;
    unsigned type = b[0], msg = b[3] | b[4] << 8, len = b[5] | b[6] << 8;
    if (len > n - 7) return;
    const uint8_t *t = b + 7, *end = b + 7 + len;
    while (end - t >= 3) {
        unsigned tt = t[0], tl = t[1] | t[2] << 8;
        const uint8_t *v = t + 3;
        if (tl > (size_t)(end - v)) break;
        if (type == QMI_RESPONSE && tt == 0x02 && tl >= 4) {
            unsigned res = v[0] | v[1] << 8, err = v[2] | v[3] << 8;
            if (res || err) logmsg("SEE request failed: result %u error %u", res, err);
            else dbg("SEE response ok");
        } else if (type == QMI_INDICATION && tt == 0x02 && tl >= 2 &&
                   (msg == SNS_CLIENT_REPORT_IND || msg == SNS_CLIENT_JUMBO_REPORT_IND)) {
            unsigned pl = v[0] | v[1] << 8;
            if (pl <= tl - 2) handle_event(v + 2, pl);
        }
        t = v + tl;
    }
}

static int streaming;
static int want_stream;     /* -d, or at least one D-Bus claim */
static time_t next_try;

static void ssc_reset(void)
{
    if (qfd >= 0) close(qfd);
    qfd = -1;
    memset(&ssc_addr, 0, sizeof(ssc_addr));
    have_accel = 0;
    streaming = 0;
    next_try = 0;
}

static void accel_enable(int on)
{
    if (!have_accel || on == streaming) return;
    if (on) {
        struct pb c = { .len = 0 };
        pb_float(&c, 1, 10.0f);  /* sample_rate Hz */
        ssc_send(&accel_suid, SNS_STD_SENSOR_MSGID_CONFIG, &c);
    } else {
        ssc_send(&accel_suid, SNS_CLIENT_MSGID_DISABLE_REQ, NULL);
    }
    streaming = on;
    logmsg("accelerometer %s", on ? "on" : "off");
}

static void accel_found(void)
{
    struct pb a = { .len = 0 };
    pb_uint(&a, 1, 0);
    ssc_send(&accel_suid, SNS_STD_MSGID_ATTR_REQ, &a);
    if (want_stream) accel_enable(1);
}

/* 0: nothing (or timeout), 1: handled a packet */
static int ssc_pump(int timeout_ms)
{
    struct pollfd pfd = { qfd, POLLIN, 0 };
    if (qfd < 0 || poll(&pfd, 1, timeout_ms) <= 0) return 0;
    uint8_t b[4096];
    struct sockaddr_qrtr from;
    socklen_t sl = sizeof(from);
    ssize_t n = recvfrom(qfd, b, sizeof(b), 0, (struct sockaddr *)&from, &sl);
    if (n <= 0) return 0;
    if (from.sq_port == QRTR_PORT_CTRL) {
        const struct qrtr_ctrl_pkt *c = (const void *)b;
        if (n < (ssize_t)sizeof(*c) || c->service != SNS_CLIENT_SVC) return 1;
        if (c->cmd == QRTR_TYPE_NEW_SERVER && !ssc_addr.sq_family) {
            logmsg("SEE client service: node %u port %u", c->node, c->port);
            ssc_addr.sq_family = AF_QIPCRTR;
            ssc_addr.sq_node = c->node;
            ssc_addr.sq_port = c->port;
            next_try = 0;
        } else if (c->cmd == QRTR_TYPE_DEL_SERVER && c->node == ssc_addr.sq_node &&
                   c->port == ssc_addr.sq_port) {
            logmsg("SEE service went away (SLPI restart?)");
            ssc_reset();
        }
        return 1;
    }
    int had = have_accel;
    handle_qmi(b, (size_t)n);
    if (!had && have_accel) accel_found();
    return 1;
}

/* Called about once a second until the accelerometer is known: open the
 * socket and look up the SEE service (qrtr-ns answers with the server, and
 * again whenever it reappears), then ask SEE for "accel".
 * Right after the SLPI boots, SEE answers before its sensors have
 * registered (empty SUID event), so the question is repeated. */
static void ssc_tick(void)
{
    static int said_svc, said_accel;
    time_t now = time(NULL);
    if (have_accel || now < next_try) return;
    next_try = now + 1;
    if (qfd < 0) {
        qfd = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
        if (qfd < 0) {
            if (!said_svc++) logmsg("AF_QIPCRTR socket: %s", strerror(errno));
            return;
        }
    }
    if (!ssc_addr.sq_family) {
        /* Repeat the lookup: a lookup sent before qrtr-ns has bound its
         * control port is dropped, and a fresh qrtr-ns knows no lookups. */
        struct sockaddr_qrtr me;
        socklen_t sl = sizeof(me);
        if (getsockname(qfd, (struct sockaddr *)&me, &sl)) { ssc_reset(); return; }
        struct sockaddr_qrtr ns = { AF_QIPCRTR, me.sq_node, QRTR_PORT_CTRL };
        struct qrtr_ctrl_pkt pkt = { QRTR_TYPE_NEW_LOOKUP, SNS_CLIENT_SVC, 0, 0, 0 };
        if (sendto(qfd, &pkt, sizeof(pkt), 0, (struct sockaddr *)&ns, sizeof(ns)) < 0)
            dbg("QRTR lookup: %s", strerror(errno));
        if (!said_svc++) logmsg("waiting for the SEE sensor service (QRTR service 400)");
        return;
    }
    if (!said_accel++) logmsg("looking up the accelerometer");
    struct pb q = { .len = 0 };
    pb_bytes(&q, 1, "accel", 5);
    pb_uint(&q, 2, 0);   /* register_updates */
    pb_uint(&q, 3, 1);   /* default_only */
    ssc_send(&suid_lookup, SNS_SUID_MSGID_REQ, &q);
}

/* ---------- D-Bus: net.hadess.SensorProxy ---------- */
#ifdef WITH_SDBUS
static sd_bus *bus;
static int claims;

struct claimer { char *name; struct claimer *next; };
static struct claimer *claimers;

/* The last orientation stays readable while nobody holds a claim. */
static void update_stream(void)
{
    want_stream = claims > 0;
    accel_enable(want_stream);
}

static int add_claim(const char *who)
{
    for (struct claimer *c = claimers; c; c = c->next)
        if (!strcmp(c->name, who)) return 0;
    struct claimer *c = calloc(1, sizeof(*c));
    c->name = strdup(who);
    c->next = claimers;
    claimers = c;
    claims++;
    logmsg("claim by %s (%d)", who, claims);
    update_stream();
    return 0;
}
static void drop_claim(const char *who)
{
    for (struct claimer **p = &claimers; *p; p = &(*p)->next)
        if (!strcmp((*p)->name, who)) {
            struct claimer *c = *p;
            *p = c->next;
            free(c->name);
            free(c);
            claims--;
            logmsg("release by %s (%d)", who, claims);
            update_stream();
            return;
        }
}

static int m_claim(sd_bus_message *m, void *u, sd_bus_error *e)
{
    (void)u; (void)e;
    add_claim(sd_bus_message_get_sender(m));
    return sd_bus_reply_method_return(m, NULL);
}
static int m_release(sd_bus_message *m, void *u, sd_bus_error *e)
{
    (void)u; (void)e;
    drop_claim(sd_bus_message_get_sender(m));
    return sd_bus_reply_method_return(m, NULL);
}
static int m_noop(sd_bus_message *m, void *u, sd_bus_error *e)
{
    (void)u; (void)e;
    return sd_bus_reply_method_return(m, NULL);
}
static int p_bool(sd_bus *b, const char *path, const char *iface, const char *prop,
                  sd_bus_message *reply, void *u, sd_bus_error *e)
{
    (void)b; (void)path; (void)iface; (void)e;
    /* Always true: the name is taken before SEE is up (QtSensors only
     * registers its backend if the service exists when a client starts),
     * and the orientation stays "undefined" until the first sample. */
    int v = !strcmp(prop, "HasAccelerometer");
    (void)u;
    return sd_bus_message_append(reply, "b", v);
}
static int p_orient(sd_bus *b, const char *path, const char *iface, const char *prop,
                    sd_bus_message *reply, void *u, sd_bus_error *e)
{
    (void)b; (void)path; (void)iface; (void)prop; (void)u; (void)e;
    return sd_bus_message_append(reply, "s", orient);
}
static int p_str(sd_bus *b, const char *path, const char *iface, const char *prop,
                 sd_bus_message *reply, void *u, sd_bus_error *e)
{
    (void)b; (void)path; (void)iface; (void)u; (void)e;
    return sd_bus_message_append(reply, "s", !strcmp(prop, "LightLevelUnit") ? "lux" : "");
}
static int p_double(sd_bus *b, const char *path, const char *iface, const char *prop,
                    sd_bus_message *reply, void *u, sd_bus_error *e)
{
    (void)b; (void)path; (void)iface; (void)prop; (void)u; (void)e;
    return sd_bus_message_append(reply, "d", 0.0);
}

static const sd_bus_vtable proxy_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("ClaimAccelerometer", "", "", m_claim, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("ReleaseAccelerometer", "", "", m_release, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("ClaimLight", "", "", m_noop, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("ReleaseLight", "", "", m_noop, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("ClaimProximity", "", "", m_noop, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("ReleaseProximity", "", "", m_noop, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_PROPERTY("HasAccelerometer", "b", p_bool, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("AccelerometerOrientation", "s", p_orient, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("HasAmbientLight", "b", p_bool, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("LightLevelUnit", "s", p_str, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("LightLevel", "d", p_double, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("HasProximity", "b", p_bool, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("ProximityNear", "b", p_bool, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_VTABLE_END
};
static const sd_bus_vtable compass_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("ClaimCompass", "", "", m_noop, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("ReleaseCompass", "", "", m_noop, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_PROPERTY("HasCompass", "b", p_bool, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("CompassHeading", "d", p_double, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_VTABLE_END
};

static int on_name_owner(sd_bus_message *m, void *u, sd_bus_error *e)
{
    (void)u; (void)e;
    const char *name, *old, *new_;
    if (sd_bus_message_read(m, "sss", &name, &old, &new_) < 0) return 0;
    if (name[0] == ':' && !*new_) drop_claim(name);
    return 0;
}

static void orientation_changed(void)
{
    logmsg("orientation %s (%.2f %.2f %.2f)", orient, ax, ay, az);
    if (bus)
        sd_bus_emit_properties_changed(bus, "/net/hadess/SensorProxy", "net.hadess.SensorProxy",
                                       "AccelerometerOrientation", NULL);
}
#else
static void orientation_changed(void) {}
#endif

static void on_signal(int s) { (void)s; quit = 1; }

int main(int argc, char **argv)
{
    int dump = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-l")) {
            qfd = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
            if (qfd < 0) { logmsg("AF_QIPCRTR socket: %s", strerror(errno)); return 1; }
            qrtr_find_ssc_service(0, 2000);
            return 0;
        }
        if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (!strcmp(argv[i], "-d")) {
            dump = 1;
            dump_left = (i + 1 < argc && argv[i + 1][0] != '-') ? atoi(argv[++i]) : 30;
        }
    }
    const char *map = getenv("MATEPAD_ACCEL_MAP");
    if (map) accel_map = atoi(map);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    setvbuf(stderr, NULL, _IOLBF, 0);

    if (dump) {
        want_stream = 1;
        time_t t0 = time(NULL);
        while (!quit && dump_left != 0 && time(NULL) - t0 < 90) {
            ssc_tick();
            ssc_pump(200);
        }
        accel_enable(0);
        ssc_pump(200);
        return have_sample ? 0 : 2;
    }

#ifdef WITH_SDBUS
    int r = sd_bus_open_system(&bus);
    if (r < 0) { logmsg("system bus: %s", strerror(-r)); return 1; }
    sd_bus_add_object_vtable(bus, NULL, "/net/hadess/SensorProxy", "net.hadess.SensorProxy",
                             proxy_vtable, NULL);
    sd_bus_add_object_vtable(bus, NULL, "/net/hadess/SensorProxy/Compass",
                             "net.hadess.SensorProxy.Compass", compass_vtable, NULL);
    sd_bus_match_signal(bus, NULL, "org.freedesktop.DBus", "/org/freedesktop/DBus",
                        "org.freedesktop.DBus", "NameOwnerChanged", on_name_owner, NULL);
    r = sd_bus_request_name(bus, "net.hadess.SensorProxy", 0);
    if (r < 0) { logmsg("request name: %s", strerror(-r)); return 1; }
    logmsg("net.hadess.SensorProxy ready");
    while (!quit) {
        while ((r = sd_bus_process(bus, NULL)) > 0) {}
        if (r < 0) { logmsg("bus: %s", strerror(-r)); break; }
        ssc_tick();
        struct pollfd p[2] = { { sd_bus_get_fd(bus), (short)sd_bus_get_events(bus), 0 },
                               { qfd, POLLIN, 0 } };
        if (poll(p, 2, have_accel ? 1000 : 250) < 0 && errno != EINTR) break;
        if (p[1].revents & POLLIN) while (ssc_pump(0) > 0) {}
    }
    accel_enable(0);
    sd_bus_flush_close_unref(bus);
    return 0;
#else
    logmsg("built without WITH_SDBUS: only -d and -l are available");
    return 1;
#endif
}
