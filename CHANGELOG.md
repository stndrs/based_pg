# Changelog

## v5.0.0

### Breaking changes

- Replaced `pgo` with `pgl` as the underlying PostgreSQL driver.
- Replaced `based_pg` module with `based/pg`. The library now exports a
  single `based/pg` module.
- Removed `Config` record in favour of a builder API (`pg.config |> pg.database("mydb") |> ...`).
- Removed `default_config` and `adapter` functions.
- `new` now returns an opaque `Db` type. Use `pg.start` to open the
  connection pool and `pg.db` to get a `based.Db` for querying.
- Connections are managed via a supervised pool rather than
  connect-per-callback.

### Added

- Builder functions for all connection options: `host`, `port`, `username`,
  `password`, `database`, `ssl`, `pool_size`, `idle_interval`,
  `queue_target`, `ip_version`, `rows_as_dict`, `connection_parameter`,
  and `application`.
- `from_url` to parse a PostgreSQL connection URL into a `Config`.
- `start` to launch the connection pool under a new supervisor.
- `supervised` to add the connection pool to an existing supervision tree.
- `transaction` for callback-based transactions with automatic
  commit/rollback.
- `begin`, `commit`, and `rollback` for manual transaction control.
- `Ssl` type with `SslDisabled`, `SslVerified`, and `SslUnverified` variants.
- `IpVersion` type with `Ipv4` and `Ipv6` variants.
- Adapter now quotes identifiers with double quotes.
- Structured error mapping: PostgreSQL errors are classified as
  `ConstraintError`, `SyntaxError`, or generic `DatabaseError` based on
  error codes and fields.
- Doc comments on all public functions and types.
- Apache-2.0 license.

### Upgraded dependencies

- `based` v4
- `pgl` v3
- `pg_value` v3
- `gleam_otp` v1.2
- `gleam_time` v1.6
