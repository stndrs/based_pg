import based.{
  type BasedAdapter, type BasedError, type Query, type Value, BasedAdapter,
  BasedError, Query,
}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/pgo.{type Connection, type QueryError, Returned}
import gleam/result
import gleam/string

pub type Config {
  Config(
    host: String,
    port: Int,
    database: String,
    user: String,
    password: Option(String),
    ssl: Bool,
    connection_parameters: List(#(String, String)),
    pool_size: Int,
    queue_target: Int,
    queue_interval: Int,
    idle_interval: Int,
    trace: Bool,
    ip_version: IpVersion,
  )
}

pub type IpVersion {
  Ipv4
  Ipv6
}

/// Returns a `BasedAdapter` that can be passed into `based.register`.
pub fn adapter(config: Config) -> BasedAdapter(Config, Connection, t) {
  BasedAdapter(with_connection: with_connection, conf: config, service: execute)
}

pub fn default_config() -> Config {
  pgo.default_config()
  |> from_pgo_config
}

fn with_connection(config: Config, callback: fn(Connection) -> t) -> t {
  let conn =
    config
    |> to_pgo_config
    |> pgo.connect

  let result = callback(conn)

  pgo.disconnect(conn)
  result
}

fn execute(query: Query, conn: Connection) -> Result(List(Dynamic), BasedError) {
  let Query(sql, args) = query
  let values = args |> to_pgo_values

  pgo.execute(sql, conn, values, dynamic.dynamic)
  |> result.map(fn(returned) {
    let Returned(_count, rows) = returned
    rows
  })
  |> result.map_error(to_based_error)
}

// TODO: improve error handling
fn to_based_error(error: QueryError) -> BasedError {
  case error {
    pgo.ConstraintViolated(msg, constraint, _detail) ->
      BasedError(code: "constraint_violated", name: constraint, message: msg)
    pgo.PostgresqlError(code, name, message) -> BasedError(code, name, message)
    pgo.UnexpectedArgumentCount(expected, got) ->
      BasedError(
        code: "unexpected_argument_count",
        name: "",
        message: "Expected "
          <> int.to_string(expected)
          <> ", got "
          <> int.to_string(got),
      )
    pgo.UnexpectedArgumentType(expected, got) ->
      BasedError(
        code: "unexpected_argument_count",
        name: "",
        message: "Expected " <> expected <> ", got " <> got,
      )
    pgo.UnexpectedResultType(decode_errors) ->
      BasedError(
        code: "unexpected_result_type",
        name: "",
        message: decode_error_message(decode_errors),
      )
    pgo.ConnectionUnavailable ->
      BasedError(code: "connection_unavailable", name: "", message: "")
  }
}

fn decode_error_message(errors: dynamic.DecodeErrors) -> String {
  let assert [dynamic.DecodeError(expected, actual, path), ..] = errors
  let path = string.join(path, ".")

  "Decoder failed, expected "
  <> expected
  <> ", got "
  <> actual
  <> " in "
  <> path
}

fn to_pgo_values(values: List(Value)) -> List(pgo.Value) {
  values
  |> list.map(fn(value) {
    case value {
      based.String(val) -> pgo.text(val)
      based.Int(val) -> pgo.int(val)
      based.Float(val) -> pgo.float(val)
      based.Bool(val) -> pgo.bool(val)
      based.Null -> pgo.null()
    }
  })
}

fn to_pgo_config(config: Config) -> pgo.Config {
  let Config(
    host,
    port,
    database,
    user,
    password,
    ssl,
    connection_parameters,
    pool_size,
    queue_target,
    queue_interval,
    idle_interval,
    trace,
    ip_version,
  ) = config

  pgo.Config(
    host,
    port,
    database,
    user,
    password,
    ssl,
    connection_parameters,
    pool_size,
    queue_target,
    queue_interval,
    idle_interval,
    trace,
    to_pgo_ip_version(ip_version),
  )
}

fn from_pgo_config(config: pgo.Config) -> Config {
  let pgo.Config(
    host,
    port,
    database,
    user,
    password,
    ssl,
    connection_parameters,
    pool_size,
    queue_target,
    queue_interval,
    idle_interval,
    trace,
    ip_version,
  ) = config

  Config(
    host,
    port,
    database,
    user,
    password,
    ssl,
    connection_parameters,
    pool_size,
    queue_target,
    queue_interval,
    idle_interval,
    trace,
    from_pgo_ip_version(ip_version),
  )
}

fn to_pgo_ip_version(ip_version: IpVersion) -> pgo.IpVersion {
  case ip_version {
    Ipv4 -> pgo.Ipv4
    Ipv6 -> pgo.Ipv6
  }
}

fn from_pgo_ip_version(ip_version: pgo.IpVersion) -> IpVersion {
  case ip_version {
    pgo.Ipv4 -> Ipv4
    pgo.Ipv6 -> Ipv6
  }
}
