#!/usr/bin/ksh -p
#
# CDDL HEADER START
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# http://www.illumos.org/license/CDDL.
#
# CDDL HEADER END
#

#
# Copyright (c) 2014 by Delphix. All rights reserved.
# Copyright 2026 Oxide Computer Company
#

. $STF_SUITE/include/libtest.shlib

#
# removal_with_ganging restores metaslab_force_ganging in its own cleanup,
# but that doesn't run if the test is killed (e.g. hung in "zpool wait"),
# and a leftover low value makes all later tests gang.  Put back the
# default, SPA_MAXBLOCKSIZE + 1.
#
log_must set_tunable64 metaslab_force_ganging $((2**24 + 1))

default_cleanup
