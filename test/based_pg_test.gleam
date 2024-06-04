import based.{Query}
import based_pg
import gleam/option.{None}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn with_connection_test() {
  let config =
    based_pg.Config(
      host: "localhost",
      port: 54_322,
      database: "based_pg",
      username: "postgres",
      password: "based_pg_password",
    )

  let result = {
    use db <- based_pg.with_connection(config)

    Query(sql: "SELECT 1", args: [], decoder: None) |> db.execute(db.conn)
  }

  result |> should.be_ok
}
