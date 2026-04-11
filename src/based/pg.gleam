import based
import based/sql
import gleam/dict.{type Dict}
import gleam/function
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/otp/supervision
import gleam/result
import pg_value
import pgl

pub type Config {
  Config(
    /// Application's name.
    application: String,
    /// (default: 127.0.0.1) Database server hostname.
    host: String,
    /// (default: 5432) Database server port.
    port: Int,
    /// Database username.
    username: String,
    /// Database user password.
    password: String,
    /// Database to use.
    database: String,
    /// Other Postgres connection parameters.
    connection_parameters: List(#(String, String)),
    /// (default: SslDisabled) SSL enabled or disabled.
    ssl: Ssl,
    /// (default: False) Return rows as `Dict` or n-tuple.
    rows_as_dict: Bool,
    /// (default: Ipv4) The IP version to use
    ip_version: IpVersion,
    /// (default: 1) Connection pool size.
    pool_size: Int,
    /// (default: 1000) Idle connections ping the database every `idle_interval`.
    idle_interval: Int,
    /// (default: 50) How long checking out a connection should take.
    queue_target: Int,
  )
}

/// The IP version to use
pub type IpVersion {
  Ipv4
  Ipv6
}

pub type Ssl {
  /// Disables SSL leaving connections unsecured. Avoid using this in production.
  SslDisabled
  /// Enables SSL and checks the CA certificate.
  SslVerified
  /// Enables SSL but does not check the CA certificate.
  SslUnverified
}

pub const config: Config = Config(
  application: "",
  host: "127.0.0.1",
  port: 5432,
  username: "",
  password: "",
  database: "",
  connection_parameters: [],
  ssl: SslDisabled,
  rows_as_dict: False,
  ip_version: Ipv4,
  pool_size: 1,
  queue_target: 50,
  idle_interval: 1000,
)

/// Name of the application connecting to the database.
pub fn application(conf: Config, application: String) -> Config {
  Config(..conf, application:)
}

/// The database server hostname.
pub fn host(config: Config, host: String) -> Config {
  Config(..config, host:)
}

/// The port on which the database server is listening.
pub fn port(config: Config, port: Int) -> Config {
  Config(..config, port:)
}

/// The username to connect to the database as.
pub fn username(config: Config, username: String) -> Config {
  Config(..config, username:)
}

/// The password of the user.
pub fn password(config: Config, password: String) -> Config {
  Config(..config, password:)
}

/// The name of the database to use.
pub fn database(conf: Config, database: String) -> Config {
  Config(..conf, database:)
}

/// Sets other postgres connection parameters.
pub fn connection_parameter(
  conf: Config,
  name name: String,
  value value: String,
) -> Config {
  let connection_parameters =
    list.prepend(conf.connection_parameters, #(name, value))

  Config(..conf, connection_parameters:)
}

/// Whether SSL should be used.
pub fn ssl(conf: Config, ssl: Ssl) -> Config {
  Config(..conf, ssl:)
}

/// Configures rows to be returns as `Dict` rather than n-tuples.
pub fn rows_as_dict(conf: Config, rows_as_dict: Bool) -> Config {
  Config(..conf, rows_as_dict:)
}

/// Which IP version to use
pub fn ip_version(conf: Config, ip_version: IpVersion) -> Config {
  Config(..conf, ip_version:)
}

/// Sets the size of the connection pool.
pub fn pool_size(conf: Config, pool_size: Int) -> Config {
  Config(..conf, pool_size:)
}

/// How often idle connections should ping the database server.
pub fn idle_interval(conf: Config, idle_interval: Int) -> Config {
  Config(..conf, idle_interval:)
}

/// How long it should take to check out a connection from the connection pool.
pub fn queue_target(conf: Config, queue_target: Int) -> Config {
  Config(..conf, queue_target:)
}

/// Build a `Config` from a connection url
pub fn from_url(url: String) -> Result(Config, Nil) {
  url
  |> pgl.from_url
  |> result.map(from_pgl_config)
}

fn from_pgl_config(conf: pgl.Config) -> Config {
  let pg_ssl = case conf.ssl {
    pgl.SslDisabled -> SslDisabled
    pgl.SslUnverified -> SslUnverified
    pgl.SslVerified -> SslVerified
  }

  let pg_ip_version = case conf.ip_version {
    pgl.Ipv4 -> Ipv4
    pgl.Ipv6 -> Ipv6
  }

  let pg_config =
    config
    |> application(conf.application)
    |> host(conf.host)
    |> port(conf.port)
    |> username(conf.username)
    |> password(conf.password)
    |> database(conf.database)
    |> ssl(pg_ssl)
    |> rows_as_dict(conf.rows_as_dict)
    |> ip_version(pg_ip_version)
    |> pool_size(conf.pool_size)
    |> idle_interval(conf.idle_interval)
    |> queue_target(conf.queue_target)

  Config(..pg_config, connection_parameters: conf.connection_parameters)
}

fn to_pgl_config(config: Config) -> pgl.Config {
  let ssl = case config.ssl {
    SslDisabled -> pgl.SslDisabled
    SslUnverified -> pgl.SslUnverified
    SslVerified -> pgl.SslVerified
  }

  let pgl_ip_version = case config.ip_version {
    Ipv4 -> pgl.Ipv4
    Ipv6 -> pgl.Ipv6
  }

  pgl.default
  |> pgl.application(config.application)
  |> pgl.host(config.host)
  |> pgl.port(config.port)
  |> pgl.username(config.username)
  |> pgl.password(config.password)
  |> pgl.database(config.database)
  |> pgl.ssl(ssl)
  |> pgl.rows_as_dict(config.rows_as_dict)
  |> pgl.ip_version(pgl_ip_version)
  |> pgl.pool_size(config.pool_size)
  |> pgl.idle_interval(config.idle_interval)
  |> pgl.queue_target(config.queue_target)
}

fn adapter() -> sql.Adapter(pg_value.Value) {
  sql.adapter()
  |> sql.on_placeholder(fn(i) { "$" <> int.to_string(i) })
  |> sql.on_identifier(function.identity)
  |> sql.on_value(pg_value.to_string)
  |> sql.on_int(pg_value.int)
  |> sql.on_text(pg_value.text)
  |> sql.on_null(fn() { pg_value.Null })
}

pub opaque type Db {
  Db(db: pgl.Db)
}

pub fn new(conf: Config) -> Db {
  conf
  |> to_pgl_config
  |> pgl.new
  |> Db
}

pub fn start(db: Db) -> actor.StartResult(Supervisor) {
  pgl.start(db.db)
}

pub fn supervised(db: Db) -> supervision.ChildSpecification(Supervisor) {
  pgl.supervised(db.db)
}

pub opaque type Connection {
  Connection(conn: pgl.Connection)
}

pub fn db(db: Db) -> based.Db(pg_value.Value, Connection) {
  db.db
  |> pgl.connection
  |> Connection
  |> based.driver(on_query: query, on_execute: execute, on_batch: batch)
  |> based.new(adapter())
}

fn execute(sql: String, conn: Connection) -> Result(Int, based.BasedError) {
  pgl.execute(sql, conn.conn) |> result.map_error(handle_error)
}

fn batch(
  queries: List(sql.Query(pg_value.Value)),
  conn: Connection,
) -> Result(List(based.Queried), based.BasedError) {
  queries
  |> list.map(db_query_to_pg_query)
  |> pgl.batch(conn.conn)
  |> result.map_error(handle_error)
  |> result.map(fn(queried) {
    queried
    |> list.map(fn(pgl_queried) {
      let pgl.Queried(count:, fields:, rows:) = pgl_queried

      based.Queried(count:, fields:, rows:)
    })
  })
}

fn db_query_to_pg_query(query: sql.Query(pg_value.Value)) -> pgl.Query {
  pgl.sql(query.sql)
  |> pgl.params(query.values)
}

fn handle_error(err: pgl.PglError) -> based.BasedError {
  case err {
    pgl.PostgresError(code:, name:, message:, fields:) ->
      handle_postgres_error(code, name, message, fields)
      |> based.DbError
    pgl.ConnectionError(message:) ->
      based.ConnectionError(message:) |> based.DbError
    pgl.ConnectionTimeout -> based.ConnectionTimeout |> based.DbError
    pgl_error -> based.BasedError(message: pgl.error_to_string(pgl_error))
  }
}

fn handle_postgres_error(
  code: String,
  name: String,
  message: String,
  fields: Dict(pgl.Field, String),
) -> based.DatabaseError {
  case dict.has_key(fields, pgl.Constraint) {
    True -> based.ConstraintError(code:, name:, message:)
    False -> {
      case code {
        // constraint error codes
        "23000" | "23001" | "23502" | "23503" | "23505" | "23514" | "23P01" ->
          based.ConstraintError(code:, name:, message:)
        // syntax error codes
        "42601"
        | "42846"
        | "42803"
        | "42P20"
        | "42P19"
        | "42830"
        | "42602"
        | "42622"
        | "42939"
        | "42804"
        | "42P18"
        | "42P21"
        | "42P22"
        | "42809"
        | "428C9"
        | "42703"
        | "42883"
        | "42P01"
        | "42P02"
        | "42704"
        | "42701"
        | "42P03"
        | "42P04"
        | "42723"
        | "42P05"
        | "42P06"
        | "42P07"
        | "42712"
        | "42710"
        | "42702"
        | "42725"
        | "42P08"
        | "42P09"
        | "42P10"
        | "42611"
        | "42P11"
        | "42P12"
        | "42P13"
        | "42P14"
        | "42P15"
        | "42P16"
        | "42P17" -> based.SyntaxError(code:, name:, message:)
        _ -> based.DatabaseError(code:, name:, message:)
      }
    }
  }
}

fn query(
  query: sql.Query(pg_value.Value),
  conn: Connection,
) -> Result(based.Queried, based.BasedError) {
  query
  |> db_query_to_pg_query
  |> pgl.query(conn.conn)
  |> result.map_error(handle_error)
  |> result.map(fn(pgl_queried) {
    let pgl.Queried(count:, fields:, rows:) = pgl_queried

    based.Queried(count:, fields:, rows:)
  })
}

pub fn transaction(
  conn: Connection,
  next: fn(Connection) -> Result(t, err),
) -> Result(t, based.TransactionError(err)) {
  pgl.transaction(conn.conn, fn(pgl_tx) {
    let tx_conn = Connection(conn: pgl_tx)
    next(tx_conn)
  })
  |> result.map_error(pgl_tx_err_to_db_tx_err)
}

pub fn begin(
  conn: Connection,
) -> Result(Connection, based.TransactionError(err)) {
  pgl.begin(conn.conn)
  |> result.map(fn(pgl_conn) { Connection(conn: pgl_conn) })
  |> result.map_error(to_transaction_error)
}

fn pgl_tx_err_to_db_tx_err(
  err: pgl.TransactionError(err),
) -> based.TransactionError(err) {
  case err {
    pgl.RollbackError(cause:) -> based.Rollback(cause:)
    pgl.NotInTransaction -> based.NotInTransaction
    pgl.TransactionError(message:) -> based.TransactionError(message:)
  }
}

pub fn commit(
  conn: Connection,
) -> Result(Connection, based.TransactionError(err)) {
  pgl.commit(conn.conn)
  |> result.map(fn(pgl_conn) { Connection(conn: pgl_conn) })
  |> result.map_error(to_transaction_error)
}

pub fn rollback(
  conn: Connection,
) -> Result(Connection, based.TransactionError(err)) {
  pgl.rollback(conn.conn)
  |> result.map(fn(pgl_conn) { Connection(conn: pgl_conn) })
  |> result.map_error(to_transaction_error)
}

fn to_transaction_error(
  err: pgl.TransactionError(pgl.PglError),
) -> based.TransactionError(err) {
  case pgl_tx_err_to_db_tx_err(err) {
    based.NotInTransaction -> based.NotInTransaction
    based.Rollback(cause:) -> {
      cause
      |> handle_error
      |> based.error_to_string
      |> based.TransactionError
    }
    based.TransactionError(message:) -> based.TransactionError(message:)
  }
}
