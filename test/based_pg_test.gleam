import based
import based_pg
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
    use db <- based.register(based_pg.with_connection, config)

    based.new_query("SELECT 1")
    |> based.exec(db)
    |> should.be_ok

    Nil
  }

  result |> should.equal(Nil)
}
