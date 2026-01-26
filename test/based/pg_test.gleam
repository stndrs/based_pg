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
import gleam/time/timestamp
import gleeunit/should
import global_value
import pg_value as value
import pg_value/interval

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
  global_db()
  |> pg.connection
  |> next
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

  let users = sql.table("users")

  let assert Ok(1) =
    insert.into(pg.repo(), users)
    |> insert.columns(["name", "email"])
    |> insert.values([
      [
        value.text("bill"),
        value.text("bill@example.com"),
      ],
    ])
    |> insert.to_string
    |> db.execute(conn, pg.execute)

  let assert Ok(1) =
    insert.into(pg.repo(), users)
    |> insert.columns(["name", "email"])
    |> insert.values([
      [
        value.text("todd"),
        value.text("todd@example.com"),
      ],
    ])
    |> insert.to_string
    |> db.execute(conn, pg.execute)

  let assert Ok(queried) =
    select.from(pg.repo(), users)
    |> select.columns([sql.column("email"), sql.column("id")])
    |> select.to_query
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
    |> db.params([value.float(12_345.6789)])
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn bind_text_test() {
  use conn <- connect()

  let assert Ok(queried) =
    db.sql("select $1::text")
    |> db.params([value.text("hello")])
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn bind_blob_test() {
  use conn <- connect()

  let assert Ok(queried) =
    db.sql("select $1::bytea")
    |> db.params([value.bytea(<<123, 0>>)])
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn bind_bool_test() {
  use conn <- connect()

  let assert Ok(queried) =
    db.sql("select $1::bool")
    |> db.params([value.Bool(True)])
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn query_test() {
  use conn <- with_db_setup()

  let users = sql.table("users")

  let assert Ok(queried) =
    insert.into(pg.repo(), users)
    |> insert.columns(["name", "email"])
    |> insert.values([
      [
        value.text("Tim"),
        value.text("tim@example.com"),
      ],
    ])
    |> insert.to_query
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)

  let assert Ok(queried) =
    db.sql("select name from users")
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn transaction_test() {
  use conn <- with_db_setup()

  let users = sql.table("users")

  let assert Ok(_) =
    delete.from(pg.repo(), users)
    |> delete.to_string
    |> db.execute(conn, pg.execute)

  let insert = fn(conn: pg.Connection, name, email) {
    let assert Ok(queried) =
      insert.into(pg.repo(), users)
      |> insert.columns(["name", "email"])
      |> insert.values([
        [value.text(name), value.text(email)],
      ])
      |> insert.returning([sql.column("id")])
      |> insert.to_query
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
    select.from(pg.repo(), users)
    |> select.columns([sql.column("id")])
    |> select.to_query
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

  let users = sql.table("users")

  let assert Ok(queried) =
    insert.into(pg.repo(), users)
    |> insert.columns(["id", "name", "email"])
    |> insert.values([
      [
        value.int(1),
        value.text("First User"),
        value.text("first_user@example.com"),
      ],
    ])
    |> insert.to_query
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)

  let assert Error(error) =
    insert.into(pg.repo(), users)
    |> insert.columns(["id", "name", "email"])
    |> insert.values([
      [
        value.int(1),
        value.text("Duplicate User"),
        value.text("duplicate_user@example.com"),
      ],
    ])
    |> insert.to_query
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

  let required = sql.table("required")

  let assert Error(error) =
    insert.into(pg.repo(), required)
    |> insert.columns(["id"])
    |> insert.values([[value.int(1)]])
    |> insert.to_query
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

  let tx_test = sql.table("tx_test")

  let assert Ok(_queried) =
    insert.into(pg.repo(), tx_test)
    |> insert.columns(["id", "name"])
    |> insert.values([
      [value.int(1), value.text("Before")],
    ])
    |> insert.returning([sql.all])
    |> insert.to_query
    |> db.query(conn, pg.query)

  let assert Ok(queried) =
    select.from(pg.repo(), tx_test)
    |> select.columns([sql.count("*")])
    |> select.to_query
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)

  let assert Error(error) =
    pg.transaction(conn, fn(tx) {
      let assert Ok(_queried) =
        insert.into(pg.repo(), tx_test)
        |> insert.columns(["id", "name"])
        |> insert.values([
          [
            value.int(2),
            value.text("Transaction"),
          ],
        ])
        |> insert.returning([sql.all])
        |> insert.to_query
        |> db.query(tx, pg.query)

      insert.into(pg.repo(), tx_test)
      |> insert.columns(["id", "name"])
      |> insert.values([
        [value.int(1), value.text("Duplicate")],
      ])
      |> insert.returning([sql.all])
      |> insert.to_query
      |> db.query(tx, pg.query)
      |> result.replace_error("Expected error")
    })

  let assert db.Rollback(message) = error

  message |> should.equal("Expected error")

  let assert Ok(queried) =
    select.from(pg.repo(), tx_test)
    |> select.columns([sql.count("*")])
    |> select.to_query
    |> db.query(conn, pg.query)

  queried.count |> should.equal(1)
}

pub fn table_not_exist_error_test() {
  use conn <- connect()

  let non_existent_table = sql.table("non_existent_table")

  let assert Error(error) =
    select.from(pg.repo(), non_existent_table)
    |> select.columns([sql.count("*")])
    |> select.to_query
    |> db.query(conn, pg.query)

  let assert db.SyntaxError(code:, name:, message:) = error

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
    |> db.params([value.date(date)])
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

  let date_test = sql.table("date_test")

  let decoder = fn() {
    use date <- decode.field(0, date_decoder())
    decode.success(date)
  }

  let returned = {
    use date <- list.flat_map(dates)

    let assert Ok(queried) =
      insert.into(pg.repo(), date_test)
      |> insert.columns(["date_col"])
      |> insert.values([[value.date(date)]])
      |> insert.returning([sql.column("date_col")])
      |> insert.to_query
      |> db.all(conn, decoder, pg.query)

    queried.count |> should.equal(1)

    queried.rows
  }

  returned |> should.equal(dates)
  returned |> list.length |> should.equal(5)
}

pub fn interval_bind_test() {
  use conn <- connect()

  let interval = interval.seconds(3600)

  let queried =
    db.sql("SELECT $1::interval")
    |> db.params([value.interval(interval)])
    |> db.query(conn, pg.query)
    |> should.be_ok

  queried.count |> should.equal(1)
  queried.rows
  |> should.equal([
    dynamic.array([
      dynamic.array([dynamic.int(0), dynamic.int(0), dynamic.int(3_600_000_000)]),
    ]),
  ])
}

pub fn interval_roundtrip_test() {
  use conn <- connect()

  "DROP TABLE IF EXISTS interval_test"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  "CREATE TABLE interval_test (id SERIAL PRIMARY KEY, dur_col INTERVAL)"
  |> db.execute(conn, pg.execute)
  |> should.be_ok

  let interval_test = sql.table("interval_test")

  let intervals = [
    // 1 minute
    interval.seconds(60),
    // 1 hour
    interval.seconds(3600),
    // 1 day
    interval.seconds(86_400),
    // 1 week
    interval.seconds(604_800),
    // 1 month
    interval.months(1),
    // 1 month, 1 day, 300 seconds, 500 milliseconds
    interval.months(1)
      |> interval.add(interval.days(1))
      |> interval.add(interval.seconds(300))
      |> interval.add(interval.microseconds(500)),
  ]

  {
    use interval <- list.each(intervals)

    let assert Ok(queried) =
      insert.into(pg.repo(), interval_test)
      |> insert.columns(["dur_col"])
      |> insert.values([[value.interval(interval)]])
      |> insert.returning([sql.column("dur_col")])
      |> insert.to_query
      |> db.query(conn, pg.query)

    queried.count |> should.equal(1)
  }

  let assert Ok(queried) =
    select.from(pg.repo(), interval_test)
    |> select.columns([sql.column("dur_col")])
    |> select.to_query
    |> db.query(conn, pg.query)

  queried.count |> should.equal(6)

  let assert Ok(returning) =
    db.decode(queried, fn() { decode.list(of: interval.decoder()) })

  let expected_intervals = [
    interval.Interval(months: 0, days: 0, seconds: 60, microseconds: 0),
    interval.Interval(months: 0, days: 0, seconds: 3600, microseconds: 0),
    interval.Interval(months: 0, days: 0, seconds: 86_400, microseconds: 0),
    interval.Interval(months: 0, days: 0, seconds: 604_800, microseconds: 0),
    interval.Interval(months: 1, days: 0, seconds: 0, microseconds: 0),
    interval.Interval(months: 1, days: 1, seconds: 300, microseconds: 500),
  ]

  assert expected_intervals == list.flatten(returning.rows)
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
    |> db.params([value.time(time)])
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

  let time_test = sql.table("time_test")

  {
    use time <- list.each(times)

    let assert Ok(queried) =
      insert.into(pg.repo(), time_test)
      |> insert.columns(["time_col"])
      |> insert.values([[value.time(time)]])
      |> insert.to_query
      |> db.query(conn, pg.query)

    queried.count |> should.equal(1)
  }

  let assert Ok(returning) =
    select.from(pg.repo(), time_test)
    |> select.columns([sql.column("time_col")])
    |> select.order_by(["id"])
    |> select.to_query
    |> db.query(conn, pg.query)
    |> result.try(db.decode(_, time_decoder))

  returning.count |> should.equal(5)
  returning.rows |> should.equal(times)
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
    |> db.params([value.timestamp(ts)])
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

  let timestamp_test = sql.table("timestamp_test")

  {
    use ts <- list.each(timestamps)

    let assert Ok(queried) =
      insert.into(pg.repo(), timestamp_test)
      |> insert.columns(["ts_col"])
      |> insert.values([[value.timestamp(ts)]])
      |> insert.to_query
      |> db.query(conn, pg.query)

    queried.count |> should.equal(1)
  }

  let decoder = {
    use ts <- decode.field(0, timestamp_decoder())
    decode.success(ts)
  }

  let assert Ok(returning) =
    select.from(pg.repo(), timestamp_test)
    |> select.columns([sql.column("ts_col")])
    |> select.order_by(["id"])
    |> select.to_query
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
