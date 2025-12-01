import based/db
import based/pg
import based/sql
import based/sql/delete
import based/sql/insert
import based/sql/select
import exception
import gleam/dynamic
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import global_value
import pg/value

fn global_db() -> pg.Db {
  global_value.create_with_unique_name("pg_db_test", fn() {
    let db =
      pg.config
      |> pg.database("gleam_pgl_test")
      |> pg.username("postgres")
      |> pg.password("postgres")
      |> pg.new

    let assert Ok(_) = pg.start(db)

    db
  })
}

fn connect(next: fn(pg.Connection) -> a) -> a {
  let db = global_db()

  let assert Ok(res) = pg.with_connection(db, next)

  res
}

const drop_users_sql = "DROP TABLE IF EXISTS users"

const create_users_sql = "CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  name VARCHAR(128) NOT NULL,
  email VARCHAR(128) NOT NULL,
  created_at TIMESTAMP DEFAULT now()
)"

fn with_db_setup(next: fn(pg.Connection) -> a) -> a {
  use conn <- connect()

  let assert Ok(_) = drop_users_sql |> db.execute(conn, pg.execute)
  let assert Ok(_) = create_users_sql |> db.execute(conn, pg.execute)

  with_rollback(conn, next)
}

fn with_rollback(conn: pg.Connection, next: fn(pg.Connection) -> a) -> a {
  let assert Ok(tx) = pg.begin(conn)

  let res = next(tx)

  let assert Ok(_db) = pg.rollback(tx)

  res
}

pub fn execute_test() {
  use conn <- with_db_setup()

  let users = sql.name("users") |> sql.table

  let assert Ok(1) =
    insert.into(users)
    |> insert.columns(["name", "email"])
    |> insert.values([
      [
        sql.value("bill", of: value.text),
        sql.value("bill@example.com", of: value.text),
      ],
    ])
    |> insert.to_string(conn.fmt)
    |> db.execute(conn, pg.execute)

  let assert Ok(1) =
    insert.into(users)
    |> insert.columns(["name", "email"])
    |> insert.values([
      [
        sql.value("todd", of: value.text),
        sql.value("todd@example.com", of: value.text),
      ],
    ])
    |> insert.to_string(conn.fmt)
    |> db.execute(conn, pg.execute)

  let assert Ok(queried) =
    select.from(users)
    |> select.columns(["email", "id"])
    |> select.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  queried.count |> should.equal(2)
  queried.fields |> should.equal(["email", "id"])
  queried.rows
  |> should.equal([
    dynamic.array([dynamic.string("bill@example.com"), dynamic.int(1)]),
    dynamic.array([dynamic.string("todd@example.com"), dynamic.int(2)]),
  ])
}

pub fn bind_float_test() {
  use conn <- connect()

  let assert Ok(queried) =
    db.sql("select $1::float4")
    |> db.values([value.float(12_345.6789)])
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn bind_text_test() {
  use conn <- connect()

  let assert Ok(queried) =
    db.sql("select $1::text")
    |> db.values([value.text("hello")])
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn bind_blob_test() {
  use conn <- connect()

  let assert Ok(queried) =
    db.sql("select $1::bytea")
    |> db.values([value.bytea(<<123, 0>>)])
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn bind_bool_test() {
  use conn <- connect()

  let assert Ok(queried) =
    db.sql("select $1::bool")
    |> db.values([value.Bool(True)])
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn query_test() {
  use conn <- with_db_setup()

  let users = sql.name("users") |> sql.table

  let assert Ok(queried) =
    insert.into(users)
    |> insert.columns(["name", "email"])
    |> insert.values([
      [
        sql.value("Tim", of: value.text),
        sql.value("tim@example.com", of: value.text),
      ],
    ])
    |> insert.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)

  let assert Ok(queried) =
    db.sql("select name from users")
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn transaction_test() {
  use conn <- with_db_setup()

  let users = sql.name("users") |> sql.table

  let assert Ok(_) =
    delete.from(users)
    |> delete.to_string(conn.fmt)
    |> db.execute(conn, pg.execute)

  let insert = fn(conn: pg.Connection, name, email) {
    let assert Ok(queried) =
      insert.into(users)
      |> insert.columns(["name", "email"])
      |> insert.values([
        [sql.value(name, of: value.text), sql.value(email, of: value.text)],
      ])
      |> insert.returning(["id"])
      |> insert.to_query(conn.fmt)
      |> db.query(conn, pg.query)

    queried.rows
    |> list.try_map(fn(row) {
      decode.run(row, {
        use id <- decode.field(0, decode.int)
        decode.success(id)
      })
    })
    |> should.be_ok
    |> list.first
    |> should.be_ok
  }

  pg.transaction(conn, fn(tx_db) {
    let id1 = insert(tx_db, "Tim", "tim@example.com")
    let id2 = insert(tx_db, "Tom", "tom@example.com")

    Ok(#(id1, id2))
  })
  |> should.be_ok
  |> should.equal(#(1, 2))

  pg.transaction(conn, fn(tx_db) {
    let _id1 = insert(tx_db, "Tim", "tim@example.com")
    let _id2 = insert(tx_db, "Tom", "tom@example.com")

    Error("Nope")
  })
  |> should.be_error

  let _ =
    exception.rescue(fn() {
      pg.transaction(conn, fn(tx_db) {
        let _id1 = insert(tx_db, "Tim", "tim@example.com")
        let _id2 = insert(tx_db, "Tom", "tom@example.com")

        panic as "omg"
      })
    })

  let assert Ok(queried) =
    select.from(users)
    |> select.columns(["id"])
    |> select.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  queried.rows
  |> list.try_map(fn(row) {
    decode.run(row, {
      use id <- decode.field(0, decode.int)
      decode.success(id)
    })
    |> result.replace_error(Nil)
  })
  |> should.be_ok
  |> should.equal([1, 2])
}

pub fn syntax_error_test() {
  use conn <- connect()

  let result =
    "SELEKT * FROM non_existent_table"
    |> db.execute(conn, pg.execute)
    |> should.be_error

  let assert db.SyntaxError(code, name, message) = result

  code |> should.equal("42601")
  name |> should.equal("syntax_error")
  message |> should.equal("syntax error at or near \"SELEKT\"")
}

pub fn constraint_error_primary_key_test() {
  use conn <- with_db_setup()

  let users = sql.name("users") |> sql.table

  let assert Ok(queried) =
    insert.into(users)
    |> insert.columns(["id", "name", "email"])
    |> insert.values([
      [
        sql.value(1, of: value.int),
        sql.value("First User", of: value.text),
        sql.value("first_user@example.com", of: value.text),
      ],
    ])
    |> insert.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)

  let assert Error(error) =
    insert.into(users)
    |> insert.columns(["id", "name", "email"])
    |> insert.values([
      [
        sql.value(1, of: value.int),
        sql.value("Duplicate User", of: value.text),
        sql.value("duplicate_user@example.com", of: value.text),
      ],
    ])
    |> insert.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  let assert db.ConstraintError(code, name, message) = error

  code |> should.equal("23505")
  name |> should.equal("unique_violation")
  message
  |> should.equal(
    "duplicate key value violates unique constraint \"users_pkey\"",
  )
}

pub fn constraint_error_not_null_test() {
  use conn <- connect()

  let assert Ok(0) =
    "DROP TABLE IF EXISTS required" |> db.execute(conn, pg.execute)

  let assert Ok(0) =
    "CREATE TABLE required (id INTEGER, name TEXT NOT NULL)"
    |> db.execute(conn, pg.execute)

  let required = sql.name("required") |> sql.table

  let assert Error(error) =
    insert.into(required)
    |> insert.columns(["id"])
    |> insert.values([[sql.value(1, of: value.int)]])
    |> insert.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  let assert db.ConstraintError(code, name, message) = error

  code |> should.equal("23502")
  name |> should.equal("not_null_violation")
  message
  |> should.equal(
    "null value in column \"name\" of relation \"required\" violates not-null constraint",
  )
}

pub fn transaction_rollback_test() {
  use conn <- connect()

  "DROP TABLE IF EXISTS tx_test"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  "CREATE TABLE tx_test (id INTEGER PRIMARY KEY, name TEXT)"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  let tx_test = sql.name("tx_test") |> sql.table

  let assert Ok(_queried) =
    insert.into(tx_test)
    |> insert.columns(["id", "name"])
    |> insert.values([
      [sql.value(1, of: value.int), sql.value("Before", of: value.text)],
    ])
    |> insert.returning(["*"])
    |> insert.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  let assert Ok(queried) =
    select.from(tx_test)
    |> select.columns(["COUNT(*)"])
    |> select.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)

  let assert Error(error) =
    pg.transaction(conn, fn(tx) {
      let assert Ok(_queried) =
        insert.into(tx_test)
        |> insert.columns(["id", "name"])
        |> insert.values([
          [
            sql.value(2, of: value.int),
            sql.value("Transaction", of: value.text),
          ],
        ])
        |> insert.returning(["*"])
        |> insert.to_query(tx.fmt)
        |> db.query(tx, pg.query)

      insert.into(tx_test)
      |> insert.columns(["id", "name"])
      |> insert.values([
        [sql.value(1, of: value.int), sql.value("Duplicate", of: value.text)],
      ])
      |> insert.returning(["*"])
      |> insert.to_query(tx.fmt)
      |> db.query(tx, pg.query)
      |> result.replace_error("Expected error")
    })

  let assert db.Rollback(message) = error

  message |> should.equal("Expected error")

  let assert Ok(queried) =
    select.from(tx_test)
    |> select.columns(["COUNT(*)"])
    |> select.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn table_not_exist_error_test() {
  use conn <- connect()

  let non_existent_table = sql.name("non_existent_table") |> sql.table

  let assert Error(error) =
    select.from(non_existent_table)
    |> select.columns(["*"])
    |> select.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  let assert db.DatabaseError(code:, name:, message:) = error

  code |> should.equal("42P01")
  name |> should.equal("undefined_table")
  message
  |> should.equal("relation \"non_existent_table\" does not exist")
}

// Date tests

pub fn date_bind_test() {
  use conn <- connect()

  let date = calendar.Date(year: 2025, month: calendar.April, day: 19)

  let queried =
    db.sql("SELECT $1::date")
    |> db.values([value.date(date)])
    |> db.query(conn, pg.query)
    |> should.be_ok

  queried.count |> should.equal(1)
}

pub fn date_roundtrip_test() {
  use conn <- connect()

  "DROP TABLE IF EXISTS date_test"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  "CREATE TABLE date_test (id SERIAL PRIMARY KEY, date_col DATE)"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  let dates = [
    calendar.Date(2025, calendar.April, 19),
    // Today
    calendar.Date(2000, calendar.January, 1),
    // Millennium
    calendar.Date(1999, calendar.December, 31),
    // End of century
    calendar.Date(1970, calendar.January, 1),
    // Unix epoch
    calendar.Date(2038, calendar.January, 19),
    // Unix time rollover
  ]

  let date_test = sql.name("date_test") |> sql.table

  let decoder = fn() {
    use date <- decode.field(0, date_decoder())
    decode.success(date)
  }

  let returned = {
    use date <- list.flat_map(dates)

    let assert Ok(queried) =
      insert.into(date_test)
      |> insert.columns(["date_col"])
      |> insert.values([[sql.value(date, of: value.date)]])
      |> insert.returning(["date_col"])
      |> insert.to_query(conn.fmt)
      |> db.all(conn, decoder, pg.query)

    queried.count |> should.equal(1)

    queried.rows
  }

  returned |> should.equal(dates)
  returned |> list.length |> should.equal(5)
}

pub fn duration_bind_test() {
  use conn <- connect()

  // 1 hour
  let dur = duration.seconds(3600)

  let queried =
    db.sql("SELECT $1::interval")
    |> db.values([value.interval(dur)])
    |> db.query(conn, pg.query)
    |> should.be_ok

  queried.count |> should.equal(1)
  queried.rows |> should.equal([dynamic.array([dynamic.int(3_600_000_000)])])
}

pub fn duration_roundtrip_test() {
  use conn <- connect()

  "DROP TABLE IF EXISTS duration_test"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  "CREATE TABLE duration_test (id SERIAL PRIMARY KEY, dur_col INTERVAL)"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  let duration_test = sql.name("duration_test") |> sql.table

  let durations = [
    // 1 minute
    duration.seconds(60),
    // 1 hour
    duration.seconds(3600),
    // 1 day
    duration.seconds(86_400),
    // 1 week
    duration.seconds(604_800),
    // 30 days (approx. 1 month)
    duration.seconds(2_592_000),
  ]

  {
    use dur <- list.each(durations)

    let assert Ok(queried) =
      insert.into(duration_test)
      |> insert.columns(["dur_col"])
      |> insert.values([[sql.value(dur, of: value.interval)]])
      |> insert.returning(["dur_col"])
      |> insert.to_query(conn.fmt)
      |> db.query(conn, pg.query)

    queried.count |> should.equal(1)
  }

  let assert Ok(queried) =
    select.from(duration_test)
    |> select.columns(["dur_col"])
    |> select.to_query(conn.fmt)
    |> db.query(conn, pg.query)

  queried.count |> should.equal(5)

  let assert Ok(_) = db.decode(queried, duration_decoder)
}

fn duration_decoder() -> decode.Decoder(duration.Duration) {
  use dur_val <- decode.field(0, decode.int)

  dur_val
  |> duration.nanoseconds
  |> decode.success
}

// Time tests

pub fn time_bind_test() {
  use conn <- connect()

  let time =
    calendar.TimeOfDay(
      hours: 14,
      minutes: 30,
      seconds: 45,
      nanoseconds: 123_456_789,
    )

  let queried =
    db.sql("SELECT $1::time")
    |> db.values([value.time(time)])
    |> db.query(conn, pg.query)
    |> should.be_ok

  queried.count |> should.equal(1)
}

pub fn time_roundtrip_test() {
  use conn <- connect()

  "DROP TABLE IF EXISTS time_test"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  "CREATE TABLE time_test (id SERIAL PRIMARY KEY, time_col TIME)"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  let times = [
    // Midnight
    calendar.TimeOfDay(0, 0, 0, 0),
    // Just before midnight
    calendar.TimeOfDay(23, 59, 59, 999_999_000),
    // Noon-ish
    calendar.TimeOfDay(12, 30, 45, 500_000_000),
    // Morning
    calendar.TimeOfDay(8, 15, 0, 0),
    // Evening
    calendar.TimeOfDay(18, 45, 30, 250_000_000),
  ]

  let time_test = sql.name("time_test") |> sql.table

  {
    use time <- list.each(times)

    let assert Ok(queried) =
      insert.into(time_test)
      |> insert.columns(["time_col"])
      |> insert.values([[sql.value(time, of: value.time)]])
      |> insert.to_query(conn.fmt)
      |> db.query(conn, pg.query)

    queried.count |> should.equal(1)
  }

  let assert Ok(returning) =
    select.from(time_test)
    |> select.columns(["time_col"])
    |> select.order_by(["id"])
    |> select.to_query(conn.fmt)
    |> db.query(conn, pg.query)
    |> result.try(db.decode(_, time_decoder))

  returning.count |> should.equal(5)
  // returning.rows |> should.equal(times)
}

fn time_decoder() -> decode.Decoder(calendar.TimeOfDay) {
  use time <- decode.field(0, decode.list(of: decode.int))

  let assert [hours, minutes, seconds, nanoseconds] = time

  calendar.TimeOfDay(hours:, minutes:, seconds:, nanoseconds:)
  |> decode.success
}

pub fn timestamp_bind_test() {
  use conn <- connect()

  // 2025-04-19 20:30:00 UTC
  let ts = timestamp.from_unix_seconds(1_713_557_400)

  let queried =
    db.sql("SELECT $1::timestamp")
    |> db.values([value.timestamp(ts)])
    |> db.query(conn, pg.query)
    |> should.be_ok

  queried.count |> should.equal(1)
}

pub fn timestamp_roundtrip_test() {
  use conn <- connect()

  "DROP TABLE IF EXISTS timestamp_test"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  "CREATE TABLE timestamp_test (id SERIAL PRIMARY KEY, ts_col TIMESTAMP)"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  let timestamps = [
    // 2025-04-19 20:30:00 UTC
    timestamp.from_unix_seconds(1_713_557_400),
    // 2000-01-01 00:00:00 UTC (Millennium)
    timestamp.from_unix_seconds(946_684_800),
    // 2022-01-01 00:00:00 UTC
    timestamp.from_unix_seconds(1_640_995_200),
    // 1970-01-01 00:00:00 UTC (Unix epoch)
    timestamp.from_unix_seconds(0),
    // 2038-01-19 03:14:07 UTC (Unix time max)
    timestamp.from_unix_seconds(2_147_483_647),
  ]

  let timestamp_test = sql.name("timestamp_test") |> sql.table

  {
    use ts <- list.each(timestamps)

    let assert Ok(queried) =
      insert.into(timestamp_test)
      |> insert.columns(["ts_col"])
      |> insert.values([[sql.value(ts, of: value.timestamp)]])
      |> insert.to_query(conn.fmt)
      |> db.query(conn, pg.query)

    queried.count |> should.equal(1)
  }

  let decoder = {
    use ts <- decode.field(0, timestamp_decoder())
    decode.success(ts)
  }

  let assert Ok(returning) =
    select.from(timestamp_test)
    |> select.columns(["ts_col"])
    |> select.order_by(["id"])
    |> select.to_query(conn.fmt)
    |> db.all(conn, fn() { decoder }, pg.query)

  returning.count |> should.equal(5)
  returning.rows |> should.equal(timestamps)
}

fn timestamp_decoder() -> decode.Decoder(timestamp.Timestamp) {
  use microseconds <- decode.map(decode.int)
  let seconds = microseconds / 1_000_000
  let nanoseconds = { microseconds % 1_000_000 } * 1000
  timestamp.from_unix_seconds_and_nanoseconds(seconds, nanoseconds)
}

fn date_decoder() -> decode.Decoder(calendar.Date) {
  use year <- decode.field(0, decode.int)
  use month <- decode.field(1, decode.int)
  use day <- decode.field(2, decode.int)

  case calendar.month_from_int(month) {
    Ok(month) -> calendar.Date(year:, month:, day:) |> decode.success
    _ ->
      calendar.Date(0, calendar.January, 1)
      |> decode.failure("Date")
  }
}
