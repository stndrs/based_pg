import based
import based/db
import based/interval
import based/repo.{type Repo}
import based/uuid
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/otp/supervision
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import pg_value
import pg_value/interval as pg_interval
import pgl

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

pub fn repo() -> Repo(db.Value) {
  based.default()
  |> repo.on_placeholder(fn(idx) { "$" <> int.to_string(idx) })
}

pub opaque type Db {
  Db(pgl: pgl.Db, repo: Repo(db.Value))
}

pub opaque type Connection {
  Connection(conn: pgl.Connection)
}

pub fn connection(db: Db) -> Connection {
  let conn = pgl.connection(db.pgl)

  Connection(conn:)
}

pub fn new(conf: Config) -> Db {
  let pgl_db =
    conf
    |> to_pgl_config
    |> pgl.new

  Db(pgl: pgl_db, repo: repo())
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

pub fn execute(sql: String, conn: Connection) -> Result(Int, db.DbError) {
  pgl.execute(sql, conn.conn) |> result.map_error(handle_error)
}

pub fn batch(
  queries: List(db.Query(db.Value)),
  conn: Connection,
) -> Result(List(db.Queried), db.DbError) {
  queries
  |> list.map(db_query_to_pg_query)
  |> pgl.batch(conn.conn)
  |> result.map_error(handle_error)
  |> result.map(fn(queried) {
    queried
    |> list.map(fn(pgl_queried) {
      let pgl.Queried(count:, fields:, rows:) = pgl_queried

      db.Queried(count:, fields:, rows:)
    })
  })
}

fn db_query_to_pg_query(query: db.Query(db.Value)) -> pgl.Query {
  let pg_values =
    query.values
    |> list.map(based_value_to_pg_value)

  pgl.sql(query.sql)
  |> pgl.params(pg_values)
}

fn based_value_to_pg_value(value: db.Value) -> pg_value.Value {
  case value {
    db.Null -> pg_value.null
    db.Uuid(val) -> val |> uuid.to_bit_array |> pg_value.uuid
    db.Bool(val) -> pg_value.bool(val)
    db.Int(val) -> pg_value.int(val)
    db.Float(val) -> pg_value.float(val)
    db.Text(val) -> pg_value.text(val)
    db.Bytea(val) -> pg_value.bytea(val)
    db.Date(val) -> pg_value.date(val)
    db.Time(val) -> pg_value.time(val)
    db.Datetime(date, time) -> {
      timestamp.from_calendar(date:, time:, offset: duration.seconds(0))
      |> pg_value.timestamp
    }
    db.Timestamp(val) -> pg_value.timestamp(val)
    db.Timestamptz(val, offset) -> {
      let db.Offset(hours, minutes) = offset

      let pg_offset =
        pg_value.offset(hours)
        |> pg_value.minutes(minutes)

      pg_value.timestamptz(val, pg_offset)
    }
    db.Interval(val) -> {
      let interval.Interval(months:, days:, seconds:, microseconds:) = val

      pg_interval.Interval(months:, days:, seconds:, microseconds:)
      |> pg_value.interval
    }
    db.Array(val) -> pg_value.array(val, based_value_to_pg_value)
  }
}

fn handle_error(err: pgl.PglError) -> db.DbError {
  case err {
    pgl.PostgresError(code:, name:, message:, fields:) ->
      handle_postgres_error(code, name, message, fields)
    pgl.ConnectionError(message:) -> db.ConnectionError(message:)
    pgl.ConnectionTimeout -> db.ConnectionTimeout
    pgl_error -> db.DbError(message: pgl.error_to_string(pgl_error))
  }
}

fn handle_postgres_error(
  code: String,
  name: String,
  message: String,
  fields: Dict(pgl.Field, String),
) -> db.DbError {
  case dict.has_key(fields, pgl.Constraint) {
    True -> db.ConstraintError(code:, name:, message:)
    False -> {
      case code {
        // constraint error codes
        "23000" | "23001" | "23502" | "23503" | "23505" | "23514" | "23P01" ->
          db.ConstraintError(code:, name:, message:)
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
        | "42P17" -> db.SyntaxError(code:, name:, message:)
        _ -> db.DatabaseError(code:, name:, message:)
      }
    }
  }
}

pub fn query(
  query: db.Query(db.Value),
  conn: Connection,
) -> Result(db.Queried, db.DbError) {
  query
  |> db_query_to_pg_query
  |> pgl.query(conn.conn)
  |> result.map_error(handle_error)
  |> result.map(fn(pgl_queried) {
    let pgl.Queried(count:, fields:, rows:) = pgl_queried

    db.Queried(count:, fields:, rows:)
  })
}

pub fn all(
  query: db.Query(db.Value),
  conn: Connection,
  decoder: Decoder(a),
) -> Result(db.Returning(a), db.DbError) {
  query
  |> db_query_to_pg_query
  |> pgl.query(conn.conn)
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
    let tx_conn = Connection(conn: pgl_tx)
    next(tx_conn)
  })
  |> result.map_error(pgl_tx_err_to_db_tx_err)
}

pub fn begin(conn: Connection) -> Result(Connection, db.TransactionError(err)) {
  pgl.begin(conn.conn)
  |> result.map(fn(pgl_conn) { Connection(conn: pgl_conn) })
  |> result.map_error(to_transaction_error)
}

fn pgl_tx_err_to_db_tx_err(
  err: pgl.TransactionError(err),
) -> db.TransactionError(err) {
  case err {
    pgl.RollbackError(cause:) -> db.Rollback(cause:)
    pgl.NotInTransaction -> db.NotInTransaction
    pgl.TransactionError(message:) -> db.TransactionError(message:)
  }
}

pub fn commit(conn: Connection) -> Result(Connection, db.TransactionError(err)) {
  pgl.commit(conn.conn)
  |> result.map(fn(pgl_conn) { Connection(conn: pgl_conn) })
  |> result.map_error(to_transaction_error)
}

pub fn rollback(
  conn: Connection,
) -> Result(Connection, db.TransactionError(err)) {
  pgl.rollback(conn.conn)
  |> result.map(fn(pgl_conn) { Connection(conn: pgl_conn) })
  |> result.map_error(to_transaction_error)
}

fn to_transaction_error(
  err: pgl.TransactionError(pgl.PglError),
) -> db.TransactionError(err) {
  case pgl_tx_err_to_db_tx_err(err) {
    db.NotInTransaction -> db.NotInTransaction
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
