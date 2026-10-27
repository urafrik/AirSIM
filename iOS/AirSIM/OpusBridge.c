#include "OpusBridge.h"
#include "../Opus/include/opus.h"
#include <stdlib.h>
typedef struct { OpusEncoder *encoder; OpusDecoder *decoder; } AirSIMOpus;
void airsim_opus_destroy(void *state) {
    AirSIMOpus *s = state;
    if (!s) return;
    if (s->encoder) opus_encoder_destroy(s->encoder);
    if (s->decoder) opus_decoder_destroy(s->decoder);
    free(s);
}
void *airsim_opus_create(void) {
    AirSIMOpus *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    int error = 0;
    s->encoder = opus_encoder_create(8000, 1, OPUS_APPLICATION_VOIP, &error);
    if (error || !s->encoder) { airsim_opus_destroy(s); return NULL; }
    s->decoder = opus_decoder_create(8000, 1, &error);
    if (error || !s->decoder) { airsim_opus_destroy(s); return NULL; }
    if (opus_encoder_ctl(s->encoder, OPUS_SET_BITRATE(12000)) < 0 ||
        opus_encoder_ctl(s->encoder, OPUS_SET_COMPLEXITY(5)) < 0 ||
        opus_encoder_ctl(s->encoder, OPUS_SET_INBAND_FEC(1)) < 0 ||
        opus_encoder_ctl(s->encoder, OPUS_SET_PACKET_LOSS_PERC(10)) < 0) {
        airsim_opus_destroy(s); return NULL;
    }
    return s;
}
int airsim_opus_encode(void *state, const int16_t *pcm, unsigned char *out) {
    return opus_encode(((AirSIMOpus *)state)->encoder, pcm, 160, out, 400);
}
int airsim_opus_decode(void *state, const unsigned char *packet, int length, int fec, int16_t *out) {
    return opus_decode(((AirSIMOpus *)state)->decoder, packet, length, out, 160, fec);
}
