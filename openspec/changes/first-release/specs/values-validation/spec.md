## ADDED Requirements

### Requirement: An LXC template's checksum is checked for its form

The chart SHALL refuse, at render time, an LXC template checksum that is not exactly sixty-four
lowercase hexadecimal characters. The message SHALL state the form that is required and SHALL name
quoting as the fix, because the most common way to produce a malformed value is to omit the quotes.

Requiring a checksum is not the same as requiring a checksum. A value of sixty-four digits with no
letters in it — which one template in every few hundred genuinely has — is a valid YAML number, so
it reaches the chart as a float and is carried to the guest as `1.23...e+61`. Nothing refuses it:
the render succeeds, the install reports success, and the machine downloads the whole template,
possibly gigabytes of it, before the comparison fails in a pod log inside a crash loop. The same
silence covers a truncated paste, an uppercase checksum that can never equal the lowercase one
`sha256sum` prints, and a whole `sha256sum` output line pasted with its filename still attached.

Checking the form costs one rule and moves every one of those failures from minutes after a
successful install to the moment of rendering, before anything is fetched. The chart already
type-checks a preset source's inputs for exactly this reason.

#### Scenario: An unquoted all-digit checksum is refused

- **WHEN** a machine declares an LXC source whose `sha256` is sixty-four digits written without
  quotes, so that YAML parses it as a number
- **THEN** rendering fails with a message stating that the checksum must be sixty-four lowercase
  hexadecimal characters and that it must be quoted

#### Scenario: A checksum of the wrong length is refused

- **WHEN** a machine declares an LXC source whose `sha256` is not sixty-four characters long
- **THEN** rendering fails, naming the required form

#### Scenario: A checksum carrying anything but lowercase hexadecimal is refused

- **WHEN** a machine declares an LXC source whose `sha256` contains a character outside `0-9a-f` —
  an uppercase letter, or the filename `sha256sum` prints beside the digest
- **THEN** rendering fails, naming the required form

#### Scenario: A well-formed checksum renders

- **WHEN** a machine declares an LXC source whose `sha256` is sixty-four lowercase hexadecimal
  characters
- **THEN** the machine renders, and the value reaches the guest unchanged
