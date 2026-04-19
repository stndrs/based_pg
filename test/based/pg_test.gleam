import based
import based/pg
import based/sql
import exception
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/time/calendar
import gleam/time/timestamp
import global_value
import pg_value
import pg_value/interval

fn global_db() -> based.Db(pg_value.Value, pg.Connection) {
  global_value.create_with_unique_name("pg_db_test", fn() {
    let db =
      pg.config
      |> pg.database("based_pg")
      |> pg.username("postgres")
      |> pg.password("postgres")
      |> pg.port(54_322)
      |> pg.ssl(pg.SslDisabled)
      |> pg.new

    let assert Ok(_) = pg.start(db)

    pg.db(db)
  })
}

fn connect(next: fn(based.Db(pg_value.Value, pg.Connection)) -> a) -> a {
  global_db() |> next
}

const drop_users_sql = "DROP TABLE IF EXISTS users"

const create_users_sql = "CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  name VARCHAR(128) NOT NULL,
  email VARCHAR(128) NOT NULL,
  created_at TIMESTAMP DEFAULT now()
)"

fn with_db_setup(
  next: fn(based.Db(pg_value.Value, pg.Connection)) -> a,
) -> Result(a, based.TransactionError(Nil)) {
  use db <- connect()

  let assert Ok(_) = drop_users_sql |> based.execute(db)
  let assert Ok(_) = create_users_sql |> based.execute(db)

  with_rollback(db, next)
}

fn with_rollback(
  db: based.Db(v, pg.Connection),
  next: fn(based.Db(v, pg.Connection)) -> a,
) -> Result(a, based.TransactionError(Nil)) {
  based.transaction(db, pg.transaction, fn(tx) {
    next(tx)

    Error(Nil)
  })
}

pub fn execute_test() {
  use db <- with_db_setup()

  let users = sql.table("users")

  let assert Ok(1) =
    sql.insert(into: users)
    |> sql.values(
      sql.rows([#("bill", "bill@example.com")])
      |> sql.value("name", fn(r) { pg_value.text(r.0) })
      |> sql.value("email", fn(r) { pg_value.text(r.1) }),
    )
    |> sql.to_string(db.sql)
    |> based.execute(db)

  let assert Ok(1) =
    sql.insert(into: users)
    |> sql.values(
      sql.rows([#("todd", "todd@example.com")])
      |> sql.value("name", fn(r) { pg_value.text(r.0) })
      |> sql.value("email", fn(r) { pg_value.text(r.1) }),
    )
    |> sql.to_string(db.sql)
    |> based.execute(db)

  let assert Ok(rows) =
    sql.from(users)
    |> sql.select([sql.column("email"), sql.column("id")])
    |> sql.to_query(db.sql)
    |> based.all(db, {
      use email <- decode.field(0, decode.string)
      use id <- decode.field(1, decode.int)

      decode.success(#(id, email))
    })

  assert 2 == list.length(rows)
  assert rows == [#(1, "bill@example.com"), #(2, "todd@example.com")]
}

pub fn bind_float_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("select $1::float4")
    |> sql.params([pg_value.float(12_345.6789)])
    |> based.query(db)

  assert 1 == queried.count
}

pub fn bind_text_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("select $1::text")
    |> sql.params([pg_value.text("hello")])
    |> based.query(db)

  assert 1 == queried.count
}

pub fn bind_blob_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("select $1::bytea")
    |> sql.params([pg_value.bytea(<<123, 0>>)])
    |> based.query(db)

  assert 1 == queried.count
}

pub fn bind_bool_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("select $1::bool")
    |> sql.params([pg_value.true])
    |> based.query(db)

  assert 1 == queried.count
}

pub fn query_test() {
  use db <- with_db_setup()

  let users = sql.table("users")

  let assert Ok(queried) =
    sql.insert(into: users)
    |> sql.values(
      sql.rows([#("Tim", "tim@example.com")])
      |> sql.value("name", fn(r) { pg_value.text(r.0) })
      |> sql.value("email", fn(r) { pg_value.text(r.1) }),
    )
    |> sql.to_query(db.sql)
    |> based.query(db)

  assert 1 == queried.count

  let assert Ok(queried) =
    sql.query("select name from users")
    |> based.query(db)

  assert 1 == queried.count
}

pub fn transaction_test() {
  use db <- with_db_setup()

  let users = sql.table("users")

  let assert Ok(_) =
    sql.from(users)
    |> sql.delete
    |> sql.to_string(db.sql)
    |> based.execute(db)

  let insert = fn(db: based.Db(pg_value.Value, pg.Connection), name, email) {
    let assert Ok(queried) =
      sql.insert(into: users)
      |> sql.values(
        sql.rows([#(name, email)])
        |> sql.value("name", fn(r) { pg_value.text(r.0) })
        |> sql.value("email", fn(r) { pg_value.text(r.1) }),
      )
      |> sql.returning([sql.column("id")])
      |> sql.to_query(db.sql)
      |> based.query(db)

    let assert Ok(ids) =
      queried.rows
      |> list.try_map(fn(row) {
        decode.run(row, {
          use id <- decode.field(0, decode.int)
          decode.success(id)
        })
      })

    let assert Ok(id) = list.first(ids)
    id
  }

  let assert Ok(result) =
    based.transaction(db, pg.transaction, fn(tx_conn) {
      let id1 = insert(tx_conn, "Tim", "tim@example.com")
      let id2 = insert(tx_conn, "Tom", "tom@example.com")

      Ok(#(id1, id2))
    })

  assert result == #(1, 2)

  let assert Error(_) =
    based.transaction(db, pg.transaction, fn(tx_conn) {
      let _id1 = insert(tx_conn, "Tim", "tim@example.com")
      let _id2 = insert(tx_conn, "Tom", "tom@example.com")

      Error("Nope")
    })

  let _ =
    exception.rescue(fn() {
      based.transaction(db, pg.transaction, fn(tx_conn) {
        let _id1 = insert(tx_conn, "Tim", "tim@example.com")
        let _id2 = insert(tx_conn, "Tom", "tom@example.com")

        panic as "omg"
      })
    })

  let assert Ok(queried) =
    sql.from(users)
    |> sql.select([sql.column("id")])
    |> sql.to_query(db.sql)
    |> based.query(db)

  let assert Ok(ids) =
    queried.rows
    |> list.try_map(fn(row) {
      decode.run(row, {
        use id <- decode.field(0, decode.int)
        decode.success(id)
      })
      |> result.replace_error(Nil)
    })

  assert ids == [1, 2]
}

pub fn syntax_error_test() {
  use db <- connect()

  let assert Error(result) =
    "SELEKT * FROM non_existent_table"
    |> based.execute(db)

  let assert based.DbError(based.SyntaxError(code, name, message)) = result

  assert code == "42601"
  assert name == "syntax_error"
  assert message == "syntax error at or near \"SELEKT\""
}

pub fn constraint_error_primary_key_test() {
  use db <- with_db_setup()

  let users = sql.table("users")

  let assert Ok(queried) =
    sql.insert(into: users)
    |> sql.values(
      sql.rows([#(1, "First User", "first_user@example.com")])
      |> sql.value("id", fn(r) { pg_value.int(r.0) })
      |> sql.value("name", fn(r) { pg_value.text(r.1) })
      |> sql.value("email", fn(r) { pg_value.text(r.2) }),
    )
    |> sql.to_query(db.sql)
    |> based.query(db)

  assert 1 == queried.count

  let assert Error(error) =
    sql.insert(into: users)
    |> sql.values(
      sql.rows([#(1, "Duplicate User", "duplicate_user@example.com")])
      |> sql.value("id", fn(r) { pg_value.int(r.0) })
      |> sql.value("name", fn(r) { pg_value.text(r.1) })
      |> sql.value("email", fn(r) { pg_value.text(r.2) }),
    )
    |> sql.to_query(db.sql)
    |> based.query(db)

  let assert based.DbError(based.ConstraintError(code, name, message)) = error

  assert code == "23505"
  assert name == "unique_violation"
  assert message
    == "duplicate key value violates unique constraint \"users_pkey\""
}

pub fn constraint_error_not_null_test() {
  use db <- connect()

  let assert Ok(0) = "DROP TABLE IF EXISTS required" |> based.execute(db)

  let assert Ok(0) =
    "CREATE TABLE required (id INTEGER, name TEXT NOT NULL)"
    |> based.execute(db)

  let required = sql.table("required")

  let assert Error(error) =
    sql.insert(into: required)
    |> sql.values(
      sql.rows([1])
      |> sql.value("id", pg_value.int),
    )
    |> sql.to_query(db.sql)
    |> based.query(db)

  let assert based.DbError(based.ConstraintError(code, name, message)) = error

  assert code == "23502"
  assert name == "not_null_violation"
  assert message
    == "null value in column \"name\" of relation \"required\" violates not-null constraint"
}

pub fn transaction_rollback_test() {
  use db <- connect()

  let assert Ok(_) =
    "DROP TABLE IF EXISTS tx_test"
    |> based.execute(db)

  let assert Ok(_) =
    "CREATE TABLE tx_test (id INTEGER PRIMARY KEY, name TEXT)"
    |> based.execute(db)

  let tx_test = sql.table("tx_test")

  let assert Ok(_queried) =
    sql.insert(into: tx_test)
    |> sql.values(
      sql.rows([#(1, "Before")])
      |> sql.value("id", fn(r) { pg_value.int(r.0) })
      |> sql.value("name", fn(r) { pg_value.text(r.1) }),
    )
    |> sql.returning([sql.star])
    |> sql.to_query(db.sql)
    |> based.query(db)

  let assert Ok(queried) =
    sql.from(tx_test)
    |> sql.select([sql.count("*")])
    |> sql.to_query(db.sql)
    |> based.query(db)

  assert 1 == queried.count

  let assert Error(error) =
    based.transaction(db, pg.transaction, fn(tx) {
      let assert Ok(_queried) =
        sql.insert(into: tx_test)
        |> sql.values(
          sql.rows([#(2, "Transaction")])
          |> sql.value("id", fn(r) { pg_value.int(r.0) })
          |> sql.value("name", fn(r) { pg_value.text(r.1) }),
        )
        |> sql.returning([sql.star])
        |> sql.to_query(tx.sql)
        |> based.query(tx)

      sql.insert(into: tx_test)
      |> sql.values(
        sql.rows([#(1, "Duplicate")])
        |> sql.value("id", fn(r) { pg_value.int(r.0) })
        |> sql.value("name", fn(r) { pg_value.text(r.1) }),
      )
      |> sql.returning([sql.star])
      |> sql.to_query(tx.sql)
      |> based.query(tx)
      |> result.replace_error("Expected error")
    })

  let assert based.Rollback(message) = error
  assert message == "Expected error"

  let assert Ok(queried) =
    sql.from(tx_test)
    |> sql.select([sql.count("*")])
    |> sql.to_query(db.sql)
    |> based.query(db)

  assert 1 == queried.count
}

pub fn table_not_exist_error_test() {
  use db <- connect()

  let non_existent_table = sql.table("non_existent_table")

  let assert Error(error) =
    sql.from(non_existent_table)
    |> sql.select([sql.count("*")])
    |> sql.to_query(db.sql)
    |> based.query(db)

  let assert based.DbError(based.SyntaxError(code:, name:, message:)) = error

  assert code == "42P01"
  assert name == "undefined_table"
  assert message == "relation \"non_existent_table\" does not exist"
}

// Date tests

pub fn date_bind_test() {
  use db <- connect()

  let date = calendar.Date(year: 2025, month: calendar.April, day: 19)

  let assert Ok(queried) =
    sql.query("SELECT $1::date")
    |> sql.params([pg_value.date(date)])
    |> based.query(db)

  assert 1 == queried.count
}

pub fn date_roundtrip_test() {
  use db <- connect()

  let assert Ok(_) =
    "DROP TABLE IF EXISTS date_test"
    |> based.execute(db)

  let assert Ok(_) =
    "CREATE TABLE date_test (id SERIAL PRIMARY KEY, date_col DATE)"
    |> based.execute(db)

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

  let decoder = {
    use date <- decode.field(0, pg_value.date_decoder())
    decode.success(date)
  }

  let returned = {
    use date <- list.flat_map(dates)

    let assert Ok(queried) =
      sql.insert(into: date_test)
      |> sql.values(
        sql.rows([date])
        |> sql.value("date_col", pg_value.date),
      )
      |> sql.returning([sql.column("date_col")])
      |> sql.to_query(db.sql)
      |> based.all(db, decoder)

    queried
  }

  assert returned == dates
  assert 5 == list.length(returned)
}

pub fn interval_bind_test() {
  use db <- connect()

  let interval = interval.seconds(3600)

  let assert Ok(queried) =
    sql.query("SELECT $1::interval")
    |> sql.params([pg_value.interval(interval)])
    |> based.query(db)

  assert 1 == queried.count
  assert queried.rows
    == [
      dynamic.array([
        dynamic.array([
          dynamic.int(0),
          dynamic.int(0),
          dynamic.int(3_600_000_000),
        ]),
      ]),
    ]
}

pub fn interval_roundtrip_test() {
  use db <- connect()

  let assert Ok(_) =
    "DROP TABLE IF EXISTS interval_test"
    |> based.execute(db)

  let assert Ok(_) =
    "CREATE TABLE interval_test (id SERIAL PRIMARY KEY, dur_col INTERVAL)"
    |> based.execute(db)

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
      sql.insert(into: interval_test)
      |> sql.values(
        sql.rows([interval])
        |> sql.value("dur_col", pg_value.interval),
      )
      |> sql.returning([sql.column("dur_col")])
      |> sql.to_query(db.sql)
      |> based.query(db)

    assert 1 == queried.count
  }

  let assert Ok(queried) =
    sql.from(interval_test)
    |> sql.select([sql.column("dur_col")])
    |> sql.to_query(db.sql)
    |> based.query(db)

  assert 6 == queried.count

  let assert Ok(returning) =
    based.decode(queried, decode.list(of: interval.decoder()))

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
  use db <- connect()

  let time =
    calendar.TimeOfDay(
      hours: 14,
      minutes: 30,
      seconds: 45,
      nanoseconds: 123_456_789,
    )

  let assert Ok(queried) =
    sql.query("SELECT $1::time")
    |> sql.params([pg_value.time(time)])
    |> based.query(db)

  assert 1 == queried.count
}

pub fn time_roundtrip_test() {
  use db <- connect()

  let assert Ok(_) =
    "DROP TABLE IF EXISTS time_test"
    |> based.execute(db)

  let assert Ok(_) =
    "CREATE TABLE time_test (id SERIAL PRIMARY KEY, time_col TIME)"
    |> based.execute(db)

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
      sql.insert(into: time_test)
      |> sql.values(
        sql.rows([time])
        |> sql.value("time_col", pg_value.time),
      )
      |> sql.to_query(db.sql)
      |> based.query(db)

    assert 1 == queried.count
  }

  let assert Ok(returning) =
    sql.from(time_test)
    |> sql.select([sql.column("time_col")])
    |> sql.order_by([sql.asc(sql.column("id"))])
    |> sql.to_query(db.sql)
    |> based.query(db)
    |> result.try(based.decode(_, time_decoder()))

  assert 5 == returning.count
  assert returning.rows == times
}

fn time_decoder() -> decode.Decoder(calendar.TimeOfDay) {
  use time <- decode.field(0, decode.list(of: decode.int))

  let assert [hours, minutes, seconds, microseconds] = time

  let nanoseconds = microseconds * 1000

  calendar.TimeOfDay(hours:, minutes:, seconds:, nanoseconds:)
  |> decode.success
}

pub fn timestamp_bind_test() {
  use db <- connect()

  // 2025-04-19 20:30:00 UTC
  let ts = timestamp.from_unix_seconds(1_713_557_400)

  let assert Ok(queried) =
    sql.query("SELECT $1::timestamp")
    |> sql.params([pg_value.timestamp(ts)])
    |> based.query(db)

  assert 1 == queried.count
}

pub fn timestamp_roundtrip_test() {
  use db <- connect()

  let assert Ok(_) =
    "DROP TABLE IF EXISTS timestamp_test"
    |> based.execute(db)

  let assert Ok(_) =
    "CREATE TABLE timestamp_test (id SERIAL PRIMARY KEY, ts_col TIMESTAMP)"
    |> based.execute(db)

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
      sql.insert(into: timestamp_test)
      |> sql.values(
        sql.rows([ts])
        |> sql.value("ts_col", pg_value.timestamp),
      )
      |> sql.to_query(db.sql)
      |> based.query(db)

    assert 1 == queried.count
  }

  let decoder = {
    use ts <- decode.field(0, pg_value.timestamp_decoder())
    decode.success(ts)
  }

  let assert Ok(returned) =
    sql.from(timestamp_test)
    |> sql.select([sql.column("ts_col")])
    |> sql.order_by([sql.asc(sql.column("id"))])
    |> sql.to_query(db.sql)
    |> based.all(db, decoder)

  assert timestamps == returned
}

pub fn from_url_valid_test() {
  let assert Ok(_config) =
    pg.from_url("postgres://user:pass@localhost:5432/mydb")
}

pub fn from_url_without_password_test() {
  let assert Ok(_config) = pg.from_url("postgres://user@localhost:5432/mydb")
}

pub fn from_url_postgresql_scheme_test() {
  let assert Ok(_config) =
    pg.from_url("postgresql://user:pass@localhost:5432/mydb")
}

pub fn from_url_invalid_scheme_test() {
  let assert Error(Nil) = pg.from_url("mysql://user:pass@localhost:5432/mydb")
}

pub fn from_url_invalid_string_test() {
  let assert Error(Nil) = pg.from_url("not a url at all")
}

pub fn batch_test() {
  use db <- with_db_setup()

  let users = sql.table("users")

  let queries =
    ["alice", "bob", "charlie"]
    |> list.map(fn(name) {
      sql.insert(into: users)
      |> sql.values(
        sql.rows([name])
        |> sql.value("name", pg_value.text)
        |> sql.value("email", fn(n) { pg_value.text(n <> "@example.com") }),
      )
      |> sql.to_query(db.sql)
    })

  let assert Ok(results) = based.batch(queries, db)

  assert 3 == list.length(results)
  list.each(results, fn(queried) {
    assert 1 == queried.count
  })

  let assert Ok(queried) =
    sql.from(users)
    |> sql.select([sql.count("*")])
    |> sql.to_query(db.sql)
    |> based.query(db)

  assert 1 == queried.count
}

pub fn batch_empty_test() {
  use db <- connect()

  let assert Ok(results) = based.batch([], db)
  assert results == []
}

pub fn begin_commit_test() {
  use db <- connect()

  let assert Ok(_) =
    "DROP TABLE IF EXISTS manual_tx_test"
    |> based.execute(db)

  let assert Ok(_) =
    "CREATE TABLE manual_tx_test (id INTEGER PRIMARY KEY, name TEXT)"
    |> based.execute(db)

  let manual_tx_test = sql.table("manual_tx_test")

  let assert Ok(_) =
    based.transaction(db, pg.transaction, fn(tx) {
      let assert Ok(1) =
        sql.insert(into: manual_tx_test)
        |> sql.values(
          sql.rows([#(1, "committed")])
          |> sql.value("id", fn(r) { pg_value.int(r.0) })
          |> sql.value("name", fn(r) { pg_value.text(r.1) }),
        )
        |> sql.to_string(tx.sql)
        |> based.execute(tx)

      let assert Ok(queried) =
        sql.from(manual_tx_test)
        |> sql.select([sql.count("*")])
        |> sql.to_query(tx.sql)
        |> based.query(tx)

      assert 1 == queried.count

      Ok(Nil)
    })

  let assert Ok(queried) =
    sql.from(manual_tx_test)
    |> sql.select([sql.count("*")])
    |> sql.to_query(db.sql)
    |> based.query(db)

  assert 1 == queried.count
}

pub fn begin_rollback_via_error_test() {
  use db <- connect()

  let assert Ok(_) =
    "DROP TABLE IF EXISTS manual_rb_test"
    |> based.execute(db)

  let assert Ok(_) =
    "CREATE TABLE manual_rb_test (id INTEGER PRIMARY KEY, name TEXT)"
    |> based.execute(db)

  let manual_rb_test = sql.table("manual_rb_test")

  let assert Ok(1) =
    sql.insert(into: manual_rb_test)
    |> sql.values(
      sql.rows([#(1, "before")])
      |> sql.value("id", fn(r) { pg_value.int(r.0) })
      |> sql.value("name", fn(r) { pg_value.text(r.1) }),
    )
    |> sql.to_string(db.sql)
    |> based.execute(db)

  let assert Error(_) =
    based.transaction(db, pg.transaction, fn(tx) {
      let assert Ok(1) =
        sql.insert(into: manual_rb_test)
        |> sql.values(
          sql.rows([#(2, "rolled_back")])
          |> sql.value("id", fn(r) { pg_value.int(r.0) })
          |> sql.value("name", fn(r) { pg_value.text(r.1) }),
        )
        |> sql.to_string(tx.sql)
        |> based.execute(tx)

      Error("rollback please")
    })

  let assert Ok(queried) =
    sql.from(manual_rb_test)
    |> sql.select([sql.count("*")])
    |> sql.to_query(db.sql)
    |> based.query(db)

  assert 1 == queried.count
}

pub fn bind_null_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("SELECT $1::text")
    |> sql.params([pg_value.Null])
    |> based.query(db)

  assert 1 == queried.count
}

pub fn null_insert_roundtrip_test() {
  use db <- with_db_setup()

  let users = sql.table("users")

  let assert Ok(queried) =
    sql.insert(into: users)
    |> sql.values(
      sql.rows([#("no_ts", "no_ts@example.com")])
      |> sql.value("name", fn(r) { pg_value.text(r.0) })
      |> sql.value("email", fn(r) { pg_value.text(r.1) })
      |> sql.value("created_at", fn(_) { pg_value.Null }),
    )
    |> sql.returning([sql.column("created_at")])
    |> sql.to_query(db.sql)
    |> based.query(db)

  assert 1 == queried.count
}

pub fn rows_as_dict_test() {
  let db =
    pg.config
    |> pg.database("based_pg")
    |> pg.username("postgres")
    |> pg.password("postgres")
    |> pg.port(54_322)
    |> pg.ssl(pg.SslDisabled)
    |> pg.rows_as_dict(True)
    |> pg.new

  let assert Ok(_) = pg.start(db)

  let db = pg.db(db)

  let assert Ok(queried) =
    sql.query("SELECT 1 as num, 'hello' as greeting")
    |> based.query(db)

  assert 1 == queried.count

  let assert [row] = queried.rows
  let assert Ok(row_dict) =
    decode.run(row, decode.dict(decode.string, decode.dynamic))

  assert dict.has_key(row_dict, "num")
  assert dict.has_key(row_dict, "greeting")
}

pub fn bind_empty_string_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("SELECT $1::text")
    |> sql.params([pg_value.text("")])
    |> based.query(db)

  assert 1 == queried.count

  let assert Ok(rows) =
    based.decode(queried, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })

  assert rows.rows == [""]
}

pub fn bind_large_int_test() {
  use db <- connect()

  let large = 9_223_372_036_854_775_807

  let assert Ok(queried) =
    sql.query("SELECT $1::bigint")
    |> sql.params([pg_value.int(large)])
    |> based.query(db)

  assert 1 == queried.count

  let assert Ok(rows) =
    based.decode(queried, {
      use val <- decode.field(0, decode.int)
      decode.success(val)
    })

  assert rows.rows == [large]
}

pub fn bind_negative_int_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("SELECT $1::integer")
    |> sql.params([pg_value.int(-42)])
    |> based.query(db)

  assert 1 == queried.count

  let assert Ok(rows) =
    based.decode(queried, {
      use val <- decode.field(0, decode.int)
      decode.success(val)
    })

  assert rows.rows == [-42]
}

pub fn bind_empty_bytea_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("SELECT $1::bytea")
    |> sql.params([pg_value.bytea(<<>>)])
    |> based.query(db)

  assert 1 == queried.count
}

pub fn bind_false_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("SELECT $1::bool")
    |> sql.params([pg_value.false])
    |> based.query(db)

  assert 1 == queried.count

  let assert Ok(rows) =
    based.decode(queried, {
      use val <- decode.field(0, decode.bool)
      decode.success(val)
    })

  assert rows.rows == [False]
}

pub fn bind_zero_float_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("SELECT $1::float8")
    |> sql.params([pg_value.float(0.0)])
    |> based.query(db)

  assert 1 == queried.count

  let assert Ok(rows) =
    based.decode(queried, {
      use val <- decode.field(0, decode.float)
      decode.success(val)
    })

  assert rows.rows == [0.0]
}

pub fn bind_negative_float_test() {
  use db <- connect()

  let assert Ok(queried) =
    sql.query("SELECT $1::float8")
    |> sql.params([pg_value.float(-123.456)])
    |> based.query(db)

  assert 1 == queried.count
}
