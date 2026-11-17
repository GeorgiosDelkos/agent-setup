Turn this crate into a command-line tool `wcount` that prints the number of lines, words and bytes
of each file named on the command line, and a total line when there is more than one file. With no
files it reads standard input. A file that cannot be read is reported and the tool carries on with
the rest, then exits non-zero. Include tests.

The binary is named `wcount`. Each output line is the three counts in that order and then the
file name, separated by whitespace. The total line has `total` in place of the name, and the line
for standard input has no name. A line ends with a newline character, so a file's line count is
the number of newline characters in it.
