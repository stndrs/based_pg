import based/db
import based/sql
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Pid}
import gleam/function
import gleam/int
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/otp/supervision
import gleam/result
import pgl
import pgl/value.{type Value}

pub type Config {
  Config(
    host: String,
    port: Int,
    user: String,
    password: String,
    database: String,
    timeout: Int,
    ping_timeout: Int,
    recv_timeout: Int,
    ssl: Ssl,
    // Pool config
    pool_size: Int,
    creation_timeout: Int,
    queue_target: Int,
    queue_interval: Int,
    idle_interval: Int,
    idle_limit: Int,
  )
}

pub type Ssl {
  SslDisabled
  SslVerified
  SslUnverified
}

pub const config: Config = Config(
  host: "127.0.0.1",
  port: 5432,
  user: "",
  password: "",
  database: "",
  timeout: 5000,
  ping_timeout: 1000,
  recv_timeout: 5000,
  ssl: SslDisabled,
  // Pool config
  pool_size: 1,
  creation_timeout: 50,
  queue_target: 50,
  queue_interval: 2000,
  idle_interval: 1000,
  idle_limit: 1,
)

pub fn database(config: Config, database: String) -> Config {
  Config(..config, database:)
}

pub fn host(config: Config, host: String) -> Config {
  Config(..config, host:)
}

pub fn username(config: Config, user: String) -> Config {
  Config(..config, user:)
}

pub fn password(config: Config, password: String) -> Config {
  Config(..config, password:)
}

pub fn ping_timeout(config: Config, ping_timeout: Int) -> Config {
  Config(..config, ping_timeout:)
}

fn to_pgl_config(config: Config) -> pgl.Config {
  let ssl = case config.ssl {
    SslDisabled -> pgl.SslDisabled
    SslUnverified -> pgl.SslUnverified
    SslVerified -> pgl.SslVerified
  }

  pgl.default
  |> pgl.host(config.host)
  |> pgl.port(config.port)
  |> pgl.username(config.user)
  |> pgl.password(config.password)
  |> pgl.database(config.database)
  |> pgl.ssl(ssl)
}

// ---------- SQL sql.SqlFmter ---------- //

fn fmt() -> sql.SqlFmt(Value) {
  sql.format()
  |> sql.on_identifier(function.identity)
  |> sql.on_placeholder(fn(idx) { "$" <> int.to_string(idx) })
  |> sql.on_value(value.to_string)
}

pub opaque type Db {
  Db(pgl: pgl.Db, fmt: sql.SqlFmt(Value))
}

pub type Connection {
  Connection(conn: pgl.Connection, fmt: sql.SqlFmt(Value))
}

pub fn with_connection(
  db: Db,
  next: fn(Connection) -> t,
) -> Result(t, db.DbError) {
  let self = process.self()

  use pgl_conn <- result.map(checkout(db.pgl, self))

  let conn = Connection(conn: pgl_conn, fmt: db.fmt)
  let res = next(conn)

  pgl.checkin(db.pgl, pgl_conn, self)

  res
}

pub fn new(conf: Config) -> Db {
  let pgl_db =
    conf
    |> to_pgl_config
    |> pgl.new

  Db(pgl: pgl_db, fmt: fmt())
}

pub fn start(db: Db) -> actor.StartResult(Supervisor) {
  pgl.start(db.pgl)
}

pub fn supervised(db: Db) -> supervision.ChildSpecification(Supervisor) {
  pgl.supervised(db.pgl)
}

pub fn shutdown(db: Db) -> Nil {
  let _ = pgl.shutdown(db.pgl)

  Nil
}

fn checkout(pool: pgl.Db, caller: Pid) -> Result(pgl.Connection, db.DbError) {
  pgl.checkout(pool, caller)
  |> result.map_error(fn(err) {
    echo err

    db.DbError("Checkout error")
  })
}

pub fn execute(sql: String, conn: Connection) -> Result(Int, db.DbError) {
  pgl.exec(sql, conn.conn) |> result.map_error(handle_error)
}

fn handle_error(err: pgl.PglError) -> db.DbError {
  case err {
    pgl.PglError(message:) -> db.DbError(message: "pgl error: " <> message)
    pgl.PostgresError(code:, name:, message:, fields:) ->
      handle_postgres_error(code, name, message, fields)
  }
}

fn handle_postgres_error(
  code: String,
  name: String,
  message: String,
  _fields: Dict(String, String),
) -> db.DbError {
  // let code = db.ErrorCode(code:, name:)

  // case dict.get(fields, error.Constraint) {
  //   Ok(_message) -> db.ConstraintError(code:, message:)
  //   _ -> db.DatabaseError(code:, message:)
  // }

  case code {
    "23505" -> db.ConstraintError(code:, name:, message:)
    "23502" -> db.ConstraintError(code:, name:, message:)
    "42P01" -> db.DatabaseError(code:, name:, message:)
    "42601" -> db.SyntaxError(code:, name:, message:)
    _ -> db.DbError(message:)
  }
}

pub fn query(
  query: db.Query(Value),
  conn: Connection,
) -> Result(db.Queried, db.DbError) {
  pgl.query(query.sql, query.values, conn.conn)
  |> result.map_error(handle_error)
  |> result.map(fn(pgl_queried) {
    let pgl.Queried(count:, fields:, rows:) = pgl_queried

    db.Queried(count:, fields:, rows:)
  })
}

pub fn all(
  query: db.Query(Value),
  conn: Connection,
  decoder: fn() -> Decoder(a),
) -> Result(db.Returning(a), db.DbError) {
  pgl.query(query.sql, query.values, conn.conn)
  |> result.map_error(handle_error)
  |> result.try(fn(pgl_queried) {
    let pgl.Queried(count:, fields:, rows:) = pgl_queried

    db.Queried(count:, fields:, rows:)
    |> db.decode(decoder)
  })
}

pub fn transaction(
  conn: Connection,
  next: fn(Connection) -> Result(t, err),
) -> Result(t, db.TransactionError(err)) {
  pgl.transaction(conn.conn, fn(pgl_tx) {
    let tx_conn = Connection(..conn, conn: pgl_tx)
    next(tx_conn)
  })
  |> result.map_error(pgl_tx_err_to_db_tx_err)
}

pub fn begin(conn: Connection) -> Result(Connection, db.TransactionError(err)) {
  pgl.begin(conn.conn)
  |> result.replace(conn)
  |> result.map_error(to_transaction_error)
}

fn pgl_tx_err_to_db_tx_err(
  err: pgl.TransactionError(err),
) -> db.TransactionError(err) {
  case err {
    pgl.RollbackError(cause:) -> db.Rollback(cause:)
    pgl.NotInTransaction(message:) -> db.TransactionError(message:)
    pgl.FailedTransaction(message: _, cause:) -> {
      cause
      |> handle_error
      |> db.error_to_string
      |> db.TransactionError
    }
    pgl.TransactionError -> db.TransactionError("Transaction failed")
  }
}

pub fn commit(conn: Connection) -> Result(Connection, db.TransactionError(err)) {
  pgl.commit(conn.conn)
  |> result.replace(conn)
  |> result.map_error(to_transaction_error)
}

pub fn rollback(
  conn: Connection,
) -> Result(Connection, db.TransactionError(err)) {
  pgl.rollback(conn.conn)
  |> result.replace(conn)
  |> result.map_error(to_transaction_error)
}

fn to_transaction_error(
  err: pgl.TransactionError(pgl.PglError),
) -> db.TransactionError(err) {
  case pgl_tx_err_to_db_tx_err(err) {
    db.Rollback(cause:) -> {
      cause
      |> handle_error
      |> db.error_to_string
      |> db.TransactionError
    }
    db.TransactionFailure(cause:) -> {
      cause
      |> handle_error
      |> db.error_to_string
      |> db.TransactionError
    }
    db.TransactionError(message:) -> db.TransactionError(message:)
  }
}
