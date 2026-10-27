#include <stdint.h>
void *airsim_opus_create(void);
void airsim_opus_destroy(void *state);
int airsim_opus_encode(void *state, const int16_t *pcm, unsigned char *out);
int airsim_opus_decode(void *state, const unsigned char *packet, int length, int fec, int16_t *out);
