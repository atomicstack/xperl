#include "EXTERN.h"
#include "perl.h"
#include "./plan9/math.h"

#define _PLAN9_SOURCE
#include <u.h>

/** Function fpclassify(double) is required by sv.c, which was refactored in perl-5.24 era and uses other libraries to classify floating points. **/

/* See /sys/src/lib/port/frexp.c */
#define SHIFT 20

int fpclassify(double d) {
        FPdbleword x;

        /* order matters: only isNaN can operate on NaN */
        if ( isNaN(d) )
                return FP_NAN;
        else if ( isInf(d, 0) )
                return FP_INFINITE;
        else if ( d == 0 )
                return FP_ZERO;

        x.x = fabs(d);
        return (x.hi >> SHIFT) ? FP_NORMAL : FP_SUBNORMAL;
}

/* Functions mentioned in /sys/include/ape/sys/socket.h but not implemented */

int recvmsg(int a, struct msghdr *b, int c)
{
    PERL_THROW_RECVMSG_NOT_IMPLEMENTED();
    return (int)NULL;
} 

int sendmsg(int a, struct msghdr *b, int c)
{
    PERL_THROW_SENDMSG_NOT_IMPLEMENTED();
    return (int)NULL;
} 


/* Functions mentioned in /sys/include/ape/sys/netdb.h but not implemented */
struct netent *getnetbyname(const char *a)
{
    PERL_THROW_GETNETBYNAME_NOT_IMPLEMENTED();
    return (struct netent *)NULL;
}

struct netent *getnetbyaddr(long a, int b)
{
    PERL_THROW_GETNETBYADDR_NOT_IMPLEMENTED();
    return (struct netent *)NULL;
}

struct netent *getnetent()
{
    PERL_THROW_GETNETENT_NOT_IMPLEMENTED();
    return (struct netent *)NULL;
}

struct protoent *getprotobyname(const char *a)
{
    PERL_THROW_GETPROTOBYNAME_NOT_IMPLEMENTED();
    return (struct protoent *)NULL;
}

struct protoent *getprotobynumber(int a)
{
    PERL_THROW_GETPROTOBYNUMBER_NOT_IMPLEMENTED();
    return (struct protoent *)NULL;
}

struct protoent *getprotoent()
{
    PERL_THROW_GETPROTOENT_NOT_IMPLEMENTED();
    return (struct protoent *)NULL;
}

struct servent *getservbyport(int a, const char *b)
{
    PERL_THROW_GETSERVBYPORT_NOT_IMPLEMENTED();
    return (struct servent *)NULL;
}

struct servent *getservent()
{
    PERL_THROW_GETSERVENT_NOT_IMPLEMENTED();
    return (struct servent *)NULL;
}

void sethostent(int a)
{
    PERL_THROW_SETHOSTENT_NOT_IMPLEMENTED();
}

void setnetent(int a)
{
    PERL_THROW_SETNETENT_NOT_IMPLEMENTED();
}

void setprotoent(int a)
{
    PERL_THROW_SETPROTOENT_NOT_IMPLEMENTED();
}

void setservent(int a)
{
    PERL_THROW_SETSERVENT_NOT_IMPLEMENTED();
}

void endnetent()
{
    PERL_THROW_ENDNETENT_NOT_IMPLEMENTED();
}

void endprotoent()
{
    PERL_THROW_ENDPROTOENT_NOT_IMPLEMENTED();
}

void endservent()
{
    PERL_THROW_ENDSERVENT_NOT_IMPLEMENTED();
}
