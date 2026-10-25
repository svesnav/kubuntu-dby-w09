/*
 * sns_registry reverse-RPC interface for hexagonrpcd (Huawei MatePad DBY-W09)
 *
 * The SLPI sensors PD opens the apps-side "sns_registry" interface during
 * SNS_REG_INIT and aborts (sns_registry_sensor.c:94) when it is missing.  On
 * HarmonyOS it lives in /vendor/lib64/libsns_registry_skel.so, which has one
 * method: get_property(in string prop_name, rout string prop_value), a thin
 * wrapper around Android's property_get().  There is no property store here,
 * so every property reads as unset (empty string), the same as an Android
 * property that was never set.
 *
 * Licensed GPL-3.0-or-later like the rest of hexagonrpcd.
 */

#include <libhexagonrpc/error.h>
#include <libhexagonrpc/hexagonrpc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "listener.h"

static struct hrpc_arg_def_interp4 sns_registry_get_property_args[] = {
	{ HRPC_ARG_BLOB_SEQ, sizeof(char) },
	{ HRPC_ARG_OUT_BLOB_SEQ, sizeof(char) },
};

static const struct hrpc_method_def_interp4 sns_registry_get_property_def = {
	.msg_id = 0,
	.n_args = HRPC_ARRAY_SIZE(sns_registry_get_property_args),
	.args = sns_registry_get_property_args,
	.n_inner_types = 0,
	.inner_types = NULL,
};

static uint32_t sns_registry_get_property(void *data,
					  const struct fastrpc_io_buffer *inbufs,
					  struct fastrpc_io_buffer *outbufs)
{
	const char *name = inbufs[1].p;

	if (inbufs[1].s == 0 || name[inbufs[1].s - 1] != 0)
		return AEE_EBADPARM;

	if (outbufs[0].s)
		memset(outbufs[0].p, 0, outbufs[0].s);

#ifdef HEXAGONRPC_VERBOSE
	printf("sns_registry_get_property(%s) -> \"\"\n", name);
#endif

	return 0;
}

static const struct fastrpc_function_impl sns_registry_procs[] = {
	{
		.def = &sns_registry_get_property_def,
		.impl = sns_registry_get_property,
	},
};

static const struct fastrpc_interface sns_registry_interface = {
	.name = "sns_registry",
	.n_procs = 1,
	.procs = sns_registry_procs,
};

struct fastrpc_interface *fastrpc_sns_registry_init(void)
{
	struct fastrpc_interface *iface;

	iface = malloc(sizeof(*iface));
	if (iface == NULL)
		return NULL;

	memcpy(iface, &sns_registry_interface, sizeof(*iface));
	iface->data = NULL;

	return iface;
}
