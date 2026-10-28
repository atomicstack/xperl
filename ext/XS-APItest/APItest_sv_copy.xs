MODULE = XS::APItest            PACKAGE = XS::APItest

void
test_sv_setsv_failure(kind)
    const char *kind
    CODE:
        SV *dsv;
        SV *ssv;

        if (strEQ(kind, "bizarre")) {
            dsv = sv_2mortal(newSV(0));
            ssv = (SV *)sv_2mortal((SV *)newAV());
        }
        else if (strEQ(kind, "copy_to")) {
            dsv = (SV *)sv_2mortal((SV *)newAV());
            ssv = sv_2mortal(newSVpvs("value"));
        }
        else {
            croak("unknown sv_setsv failure fixture");
        }

        sv_setsv_flags(dsv, ssv, 0);
