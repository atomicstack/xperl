MODULE = XS::APItest		PACKAGE = XS::APItest::numeric

void
grok_number(number)
	SV *number
    PREINIT:
	STRLEN len;
	const char *pv = SvPV(number, len);
	UV value;
	int result;
    PPCODE:
	EXTEND(SP,2);
	result = grok_number(pv, len, &value);
	PUSHs(sv_2mortal(newSViv(result)));
	if (result & IS_NUMBER_IN_UV)
	    PUSHs(sv_2mortal(newSVuv(value)));

void
grok_number_flags(number, flags)
	SV *number
	U32 flags
    PREINIT:
	STRLEN len;
	const char *pv = SvPV(number, len);
	UV value;
	int result;
    PPCODE:
	EXTEND(SP,2);
	result = grok_number_flags(pv, len, &value, flags);
	PUSHs(sv_2mortal(newSViv(result)));
	if (result & IS_NUMBER_IN_UV)
	    PUSHs(sv_2mortal(newSVuv(value)));

void
grok_atoUV(number, endsv)
	SV *number
	SV *endsv
    PREINIT:
	STRLEN len;
	const char *pv = SvPV(number, len);
	UV value = 0xdeadbeef;
	bool result;
	const char* endptr = pv + len;
    PPCODE:
	EXTEND(SP,2);
	if (endsv == &PL_sv_undef) {
          result = grok_atoUV(pv, &value, NULL);
        } else {
          result = grok_atoUV(pv, &value, &endptr);
        }
	PUSHs(result ? &PL_sv_yes : &PL_sv_no);
	PUSHs(sv_2mortal(newSVuv(value)));
	if (endsv == &PL_sv_undef) {
          PUSHs(sv_2mortal(newSVpvn(NULL, 0)));
	} else {
	  if (endptr) {
	    PUSHs(sv_2mortal(newSViv(endptr - pv)));
	  } else {
	    PUSHs(sv_2mortal(newSViv(0)));
	  }
	}

void
my_strtod(s)
        SV *s
    PREINIT:
        SV *sv = newSVsv(s);
        char *endptr = NULL;
        NV nv;
    PPCODE:
        nv = my_strtod(SvPV_force_nolen(sv), &endptr);
        PUSHs(sv_2mortal(newSVnv(nv)));
        if (endptr) {
            sv_chop(sv, endptr);
            PUSHs(sv_2mortal(sv));
        }

void
parse_number_types()
    PPCODE:
        XPUSHs(newSVpvs_flags("NV", SVs_TEMP));
#if defined(HAS_STRTOF) && FLT_RADIX == 2 && FLT_MANT_DIG == 24 && FLT_MAX_EXP == 128 && FLT_MIN_EXP == -125
        XPUSHs(newSVpvs_flags("Float32", SVs_TEMP));
#endif
#if defined(HAS_STRTOD) && FLT_RADIX == 2 && DBL_MANT_DIG == 53 && DBL_MAX_EXP == 1024 && DBL_MIN_EXP == -1021
        XPUSHs(newSVpvs_flags("Float64", SVs_TEMP));
#endif
#if defined(HAS_LONG_DOUBLE) && defined(HAS_STRTOLD)
        XPUSHs(newSVpvs_flags("LD", SVs_TEMP));
#endif
#ifdef USE_QUADMATH
        XPUSHs(newSVpvs_flags("Float128", SVs_TEMP));
#endif

void
parse_number_NV(number, limit = &PL_sv_undef)
        SV *number
        SV *limit
    PREINIT:
        STRLEN len;
        const char *pv = SvPV(number, len);
        char *bounded;
        char buffer[256];
        U32 flags;
        const I32 saved_errno = errno;
        bool preserved;
        bool optional_flags;
        NV value, without_flags;
    PPCODE:
        if (SvOK(limit)) len = MIN(len, SvUV(limit));
        Newx(bounded, len ? len : 1, char);
        Copy(pv, bounded, len, char);
        errno = EDOM;
        value = parse_nv(bounded, len, &flags);
        preserved = (errno == EDOM);
        without_flags = parse_nv(bounded, len, NULL);
        optional_flags = value == without_flags
                         || (value != value && without_flags != without_flags);
        errno = saved_errno;
        Safefree(bounded);
#ifdef USE_QUADMATH
        quadmath_snprintf(buffer, sizeof buffer, "%.36Qg", value);
#else
        Gconvert(value, NV_DIG + 3, 0, buffer);
#endif
        EXTEND(SP, 5);
        mPUSHn((NV) value);
        mPUSHu(flags);
        mPUSHp(buffer, strlen(buffer));
        mPUSHu(preserved);
        mPUSHu(optional_flags);

#if defined(HAS_STRTOF) && FLT_RADIX == 2 && FLT_MANT_DIG == 24 && FLT_MAX_EXP == 128 && FLT_MIN_EXP == -125

void
parse_number_Float32(number, limit = &PL_sv_undef)
        SV *number
        SV *limit
    PREINIT:
        STRLEN len;
        const char *pv = SvPV(number, len);
        char *bounded;
        char buffer[256];
        U32 flags;
        const I32 saved_errno = errno;
        bool preserved;
        bool optional_flags;
        float value, without_flags;
    PPCODE:
        if (SvOK(limit)) len = MIN(len, SvUV(limit));
        Newx(bounded, len ? len : 1, char);
        Copy(pv, bounded, len, char);
        errno = EDOM;
        value = parse_float(bounded, len, &flags);
        preserved = (errno == EDOM);
        without_flags = parse_float(bounded, len, NULL);
        optional_flags = value == without_flags
                         || (value != value && without_flags != without_flags);
        errno = saved_errno;
        Safefree(bounded);
        sprintf(buffer, "%.9g", (double) value);
        EXTEND(SP, 5);
        mPUSHn((NV) value);
        mPUSHu(flags);
        mPUSHp(buffer, strlen(buffer));
        mPUSHu(preserved);
        mPUSHu(optional_flags);

#endif

#if defined(HAS_STRTOD) && FLT_RADIX == 2 && DBL_MANT_DIG == 53 && DBL_MAX_EXP == 1024 && DBL_MIN_EXP == -1021

void
parse_number_Float64(number, limit = &PL_sv_undef)
        SV *number
        SV *limit
    PREINIT:
        STRLEN len;
        const char *pv = SvPV(number, len);
        char *bounded;
        char buffer[256];
        U32 flags;
        const I32 saved_errno = errno;
        bool preserved;
        bool optional_flags;
        double value, without_flags;
    PPCODE:
        if (SvOK(limit)) len = MIN(len, SvUV(limit));
        Newx(bounded, len ? len : 1, char);
        Copy(pv, bounded, len, char);
        errno = EDOM;
        value = parse_double(bounded, len, &flags);
        preserved = (errno == EDOM);
        without_flags = parse_double(bounded, len, NULL);
        optional_flags = value == without_flags
                         || (value != value && without_flags != without_flags);
        errno = saved_errno;
        Safefree(bounded);
        sprintf(buffer, "%.17g", value);
        EXTEND(SP, 5);
        mPUSHn((NV) value);
        mPUSHu(flags);
        mPUSHp(buffer, strlen(buffer));
        mPUSHu(preserved);
        mPUSHu(optional_flags);

#endif

#if defined(HAS_LONG_DOUBLE) && defined(HAS_STRTOLD)

void
parse_number_LD(number, limit = &PL_sv_undef)
        SV *number
        SV *limit
    PREINIT:
        STRLEN len;
        const char *pv = SvPV(number, len);
        char *bounded;
        char buffer[256];
        U32 flags;
        const I32 saved_errno = errno;
        bool preserved;
        bool optional_flags;
        long double value, without_flags;
    PPCODE:
        if (SvOK(limit)) len = MIN(len, SvUV(limit));
        Newx(bounded, len ? len : 1, char);
        Copy(pv, bounded, len, char);
        errno = EDOM;
        value = parse_ld(bounded, len, &flags);
        preserved = (errno == EDOM);
        without_flags = parse_ld(bounded, len, NULL);
        optional_flags = value == without_flags
                         || (value != value && without_flags != without_flags);
        errno = saved_errno;
        Safefree(bounded);
#ifdef PERL_PRIgldbl
        sprintf(buffer, "%.36" PERL_PRIgldbl, value);
#else
        sprintf(buffer, "%.17g", (double) value);
#endif
        EXTEND(SP, 5);
        mPUSHn((NV) value);
        mPUSHu(flags);
        mPUSHp(buffer, strlen(buffer));
        mPUSHu(preserved);
        mPUSHu(optional_flags);

#endif

#ifdef USE_QUADMATH

void
parse_number_Float128(number, limit = &PL_sv_undef)
        SV *number
        SV *limit
    PREINIT:
        STRLEN len;
        const char *pv = SvPV(number, len);
        char *bounded;
        char buffer[256];
        U32 flags;
        const I32 saved_errno = errno;
        bool preserved;
        bool optional_flags;
        __float128 value, without_flags;
    PPCODE:
        if (SvOK(limit)) len = MIN(len, SvUV(limit));
        Newx(bounded, len ? len : 1, char);
        Copy(pv, bounded, len, char);
        errno = EDOM;
        value = parse_f128(bounded, len, &flags);
        preserved = (errno == EDOM);
        without_flags = parse_f128(bounded, len, NULL);
        optional_flags = value == without_flags
                         || (value != value && without_flags != without_flags);
        errno = saved_errno;
        Safefree(bounded);
        quadmath_snprintf(buffer, sizeof buffer, "%.36Qg", value);
        EXTEND(SP, 5);
        mPUSHn((NV) value);
        mPUSHu(flags);
        mPUSHp(buffer, strlen(buffer));
        mPUSHu(preserved);
        mPUSHu(optional_flags);

#endif
