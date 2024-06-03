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

    let sql = "SELECT 1"

    db.execute(sql, db.conn, [], None)
  }

  result
  |> should.be_ok
}
