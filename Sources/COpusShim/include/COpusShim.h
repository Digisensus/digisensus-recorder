#ifndef COPUS_SHIM_H
#define COPUS_SHIM_H

// Umbrella header: Swift sees libopus and libogg through this module.
#include "opus/opus.h"
#include "opus/opus_multistream.h"
#include "ogg/ogg.h"

/// Opus configures its coders through variadic `_ctl` functions, which Swift can't call.
/// These wrap the few requests the app needs.
int copus_ms_encoder_set_bitrate(OpusMSEncoder *encoder, int bitsPerSecond);
int copus_ms_encoder_set_vbr(OpusMSEncoder *encoder, int enabled);
int copus_ms_encoder_set_signal_voice(OpusMSEncoder *encoder);
int copus_ms_encoder_set_complexity(OpusMSEncoder *encoder, int complexity);
int copus_ms_encoder_set_max_bandwidth_wideband(OpusMSEncoder *encoder);
int copus_ms_encoder_get_lookahead(OpusMSEncoder *encoder, int *samples);

#endif
