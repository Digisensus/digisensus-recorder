#include "COpusShim.h"

int copus_ms_encoder_set_bitrate(OpusMSEncoder *encoder, int bitsPerSecond) {
    return opus_multistream_encoder_ctl(encoder, OPUS_SET_BITRATE(bitsPerSecond));
}

int copus_ms_encoder_set_vbr(OpusMSEncoder *encoder, int enabled) {
    return opus_multistream_encoder_ctl(encoder, OPUS_SET_VBR(enabled));
}

int copus_ms_encoder_set_signal_voice(OpusMSEncoder *encoder) {
    return opus_multistream_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}

int copus_ms_encoder_set_complexity(OpusMSEncoder *encoder, int complexity) {
    return opus_multistream_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(complexity));
}

int copus_ms_encoder_set_max_bandwidth_wideband(OpusMSEncoder *encoder) {
    return opus_multistream_encoder_ctl(encoder, OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_WIDEBAND));
}

int copus_ms_encoder_get_lookahead(OpusMSEncoder *encoder, int *samples) {
    opus_int32 value = 0;
    int status = opus_multistream_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(&value));
    *samples = value;
    return status;
}
