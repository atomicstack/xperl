#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#if defined(__GLIBC__) && !defined(PERL_TRACK_MEMPOOL) && !defined(MYMALLOC)
#  include <malloc.h>
#endif

MODULE = HashOptionsCompat    PACKAGE = HashOptionsCompat

void
disable_sharing(hash)
    HV *hash
  CODE:
    HvSHAREKEYS_off(hash);

SV *
query_key(input)
    SV *input
  PREINIT:
    STRLEN len;
    const char *key;
    I32 shared_len;
  CODE:
    key = SvPV(input, len);
    if (len > I32_MAX)
        croak("query key is too long");
    shared_len = SvUTF8(input) ? -(I32)len : (I32)len;
    RETVAL = newSVpvn_share(key, shared_len, 0);
  OUTPUT:
    RETVAL

SV *
pointer_storage_info(hash)
    HV *hash
  CODE:
#ifdef HvIS_OA
    PERL_UNUSED_ARG(hash);
    croak("pointer diagnostics require a pointer-chain Perl build");
    RETVAL = NULL;
#else
    {
    HV *info;
    UV buckets, live, index_bytes, entry_bytes, allocated;
    live = HvTOTALKEYS(hash);
    buckets = HvARRAY(hash) ? HvMAX(hash) + 1 : 0;
    index_bytes = buckets ? PERL_HV_ARRAY_ALLOC_BYTES(buckets) : 0;
    entry_bytes = live * sizeof(HE);
    allocated = 0;
#if defined(__GLIBC__) && !defined(PERL_TRACK_MEMPOOL) && !defined(MYMALLOC)
    if (HvARRAY(hash))
        allocated = malloc_usable_size(HvARRAY(hash));
#endif
    info = newHV();
#define INFO(name, value) (void)hv_stores(info, name, newSVuv((UV)(value)))
    INFO("he_size", sizeof(HE));
    INFO("hv_size", sizeof(HV));
    INFO("hv_body_size", sizeof(XPVHV));
    INFO("live", live);
    INFO("index_capacity", buckets);
    INFO("integer_chained", 0);
    INFO("linear", 0);
    INFO("open_addressed", 0);
    INFO("index_width", 0);
    INFO("slot_size", sizeof(HE *));
    INFO("metadata_bytes", 0);
    INFO("entry_capacity", live);
    INFO("entry_used", live);
    INFO("arena_backed", live ? 1 : 0);
    INFO("arena_slot_size", live ? sizeof(HE) : 0);
    INFO("index_bytes", index_bytes);
    INFO("entry_bytes", entry_bytes);
    INFO("requested_bytes", index_bytes + entry_bytes);
    INFO("allocator_bytes", allocated);
#undef INFO
    RETVAL = newRV_noinc((SV *)info);
    }
#endif
  OUTPUT:
    RETVAL

SV *
pointer_shared_info()
  CODE:
#ifdef HvIS_OA
    croak("pointer diagnostics require a pointer-chain Perl build");
    RETVAL = NULL;
#else
    {
    AV *info;
    UV buckets;
    buckets = HvARRAY(PL_strtab) ? HvMAX(PL_strtab) + 1 : 0;
    info = newAV();
    av_push(info, newSVuv(buckets));
    av_push(info, newSVuv(HvTOTALKEYS(PL_strtab)));
    av_push(info, newSVuv(0));
    av_push(info, newSVuv(sizeof(HE *)));
    av_push(info, newSVuv(0));
    /* Probe distances describe open addressing, not pointer chains. */
    av_push(info, newSV(0));
    av_push(info, newSV(0));
    RETVAL = newRV_noinc((SV *)info);
    }
#endif
  OUTPUT:
    RETVAL
