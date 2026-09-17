# XPerl differences from mainline Perl

This document summarizes the intentional and material differences between
the current XPerl branch and mainline Perl's `blead` branch. It is a guide
to the shape of the fork, not an exhaustive patch listing. The exact changes
can be inspected with:

```text
git diff origin/blead..HEAD
```

## AI policy is now permissive

We have removed the AI-POLICY document, it was divisive and unbecomming of Perl.

## Compatibility posture

Most existing Perl behavior is intentionally preserved where practical, and
the branch contains compatibility fixes for feature-disabled code, `CORE`
handling, threaded builds, and bundled distributions. 
