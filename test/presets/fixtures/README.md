# Fixtures for the preset build's verification tests

`SHA256SUMS` and `SHA256SUMS.asc` are a real, unmodified pair taken from
linuxcontainers.org — the Debian trixie arm64 build of 2026-08-29 05:24. They are
carried here rather than generated because the point of these tests is that the
verification runs against the key this repository pins, and a fixture signed by a
key invented for the test would prove only that the code path executes.

They are 1.5 kB together. The 90 MB archive they attest to is not carried, which
is why the tests they support are the ones that must fail: a build handed these
checksums and any other bytes has to refuse, and that refusal is the whole
guarantee.

The signature is over the file's exact bytes, so nothing here may be reformatted,
re-indented or line-ending-converted. `.gitattributes` marks both files `-text`
for that reason, which turns off the line-ending conversion git would otherwise
be entitled to apply.
