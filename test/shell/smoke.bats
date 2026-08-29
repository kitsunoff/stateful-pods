#!/usr/bin/env bats
#
# Proves the harness itself runs, so that an empty result is never mistaken for
# a passing suite.

@test "the test environment can run a script" {
  run bash -c 'echo ok'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
