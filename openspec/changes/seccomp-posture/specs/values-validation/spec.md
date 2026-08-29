## ADDED Requirements

### Requirement: A named syscall filter is validated for shape

Where a machine names a syscall filter, the chart SHALL accept only the forms the Kubernetes API
defines, SHALL require a profile path for the form that needs one, and SHALL reject a path supplied
alongside a form that does not take one.

A malformed filter is not caught at render time by anything else: the API server accepts the pod and
the kubelet fails to start it, which surfaces as a machine stuck before its first container.

#### Scenario: An unknown filter form is rejected

- **WHEN** a machine names a syscall filter form outside the accepted set
- **THEN** rendering fails with a message naming the offending value and listing the accepted forms

#### Scenario: A filter form requiring a path is rejected without one

- **WHEN** a machine names the form that identifies a profile on the node and supplies no path
- **THEN** rendering fails naming the values path that is missing

#### Scenario: A path supplied to a form that takes none is rejected

- **WHEN** a machine supplies a profile path alongside a form that does not use one
- **THEN** rendering fails naming the field and the form it does not belong to

### Requirement: The runtime's default filter is refused for the guest, with the reason

The chart SHALL reject a machine that asks for the container runtime's default syscall filter on its
guest container, and the rejection SHALL state that the default filter does not permit the root
change the guest performs, and SHALL name the form that can carry a filter which does.

This is the value a security-minded user reaches for first, and it is the one that produces a
machine which renders, seeds its volume over several minutes, and then dies at the root change with
an error about a system call. Rendering it would trade a clear rejection for a slow and confusing
failure, which is the trade this chart's validation exists to refuse.

#### Scenario: The runtime default is rejected for the machine

- **WHEN** a machine names the runtime's default syscall filter for its guest
- **THEN** rendering fails, the message names the operation the default filter withholds, and it
  names the form that can carry a filter which permits it

#### Scenario: The rejection does not apply to the preparation steps

- **WHEN** a machine is rendered
- **THEN** the containers that run before the guest declare the runtime's default filter, and that
  is not rejected
