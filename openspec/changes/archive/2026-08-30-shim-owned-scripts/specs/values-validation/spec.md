## ADDED Requirements

### Requirement: Registry credentials are named, never embedded

Where a machine needs credentials to reach its source, the chart SHALL accept only a reference to a
Secret in the release's namespace. It SHALL NOT accept a registry username, password, token or
docker configuration as a chart value.

A value is stored in the Helm release, printed by `helm get values`, and typically committed to a
repository. A credential that can be put there will be. A reference cannot leak what it names.

The input belongs to the source kind whose fetch the chart performs; supplying it on a kind that
needs no credentials is rejected like every other cross-kind field, rather than ignored.

#### Scenario: A credential value is not accepted

- **WHEN** a user looks for an input that carries a registry username, password or token
- **THEN** no such input exists, and only a reference to a Secret is accepted

#### Scenario: A pull secret on a source kind that does not fetch an image is rejected

- **WHEN** a machine declares an LXC template source and names a pull secret
- **THEN** rendering fails with a message naming the field and the source kind it belongs to

#### Scenario: An empty pull secret reference is rejected

- **WHEN** a machine declares a pull secret whose name is empty or is not a valid Kubernetes object
  name
- **THEN** rendering fails naming the values path and the naming rule, rather than rendering a pod
  that cannot start
