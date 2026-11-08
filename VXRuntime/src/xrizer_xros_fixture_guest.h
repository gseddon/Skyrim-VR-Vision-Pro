#pragma once
#include "vx.h"
/* Fixture-only Windows ABI export; validates provider mailbox pixels and IDs. */
int WINAPI vx_xros_fixture_verify_pair(unsigned variant);
int WINAPI vx_xros_fixture_prepare_shutdown(void);
int WINAPI vx_xros_fixture_verify_shutdown(void);
int WINAPI vx_xros_fixture_inject_loss(void);
