/*
AES (ECB, 16-byte blocks) for the registration key and server messages.
Implemented in Zig: src/zencrypt_aes.zig (the original C++ version was based
on code by Niyaz PK, www.hoozi.com).
*/

#ifndef AES_ENCRYPT_H
#define AES_ENCRYPT_H

#include "qzod_dnseparate_global.h"
#include <zod_zig.h>

// Keep the fields in sync with `ZEncryptAES` in src/zencrypt_aes.zig.
class QZOD_DNSEPARATESHARED_EXPORT ZEncryptAES
{
private:
	int key_bits;              // 0 until Init_Key succeeds, then 128 or 256
	unsigned char key[32];

public:
	ZEncryptAES() { zod_aes_init(this); }

	// size in bits: 128 or 256. Returns 0 for other sizes.
	int Init_Key(unsigned char *key, int size) { return zod_aes_set_key(this, key, size); }
	// in_size is rounded up to whole 16-byte blocks.
	void AES_Encrypt(char *input, int in_size, char *output) { zod_aes_encrypt(this, input, in_size, output); }
	void AES_Decrypt(char *input, int in_size, char *output) { zod_aes_decrypt(this, input, in_size, output); }
};

static_assert(sizeof(ZEncryptAES) == 36, "ZEncryptAES layout must match src/zencrypt_aes.zig");

#endif
