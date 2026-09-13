## REMOVED Requirements

### Requirement: A backend that is designed but not implemented is refused with the reason

**Reason**: it described exactly one value, `systemd-credentials`, and that value is no longer a name
the chart knows. A requirement kept against a future value nobody has named is a requirement that
invents work the first time somebody reads it literally. The refusal a reader now meets is the
general one, which is required elsewhere: an unknown backend is refused and the two that exist are
listed.
