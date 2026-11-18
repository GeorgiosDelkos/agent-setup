Add the flags `-l`, `-w` and `-c` to `wcount`. They select which counts are printed: lines,
words, bytes. The selected counts keep that order whatever order the flags come in, flags can
be combined as in `-lc`, and with no flag all three are printed as before. Flags come before the
file names. A flag other than these three is an error: a message on standard error, a non-zero
exit, and nothing printed on standard output. Include tests.
