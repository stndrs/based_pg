import based
import based_pg
import gleam/dynamic
import gleam/option.{Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn with_connection_test() {
  let config = test_config()

  let result = {
    use db <- based.register(based_pg.adapter(config))

    based.new_query("SELECT 1")
    |> based.execute(db)
    |> should.be_ok

    Nil
  }

  result |> should.equal(Nil)
}

pub fn multiple_queries_with_register() {
  let config = test_config()

  let result = {
    use conn <- based.register(based_pg.adapter(config))

    let decoder =
      dynamic.decode1(fn(int) { int }, dynamic.element(0, dynamic.int))
    let decoder_two =
      dynamic.decode1(fn(str) { str }, dynamic.element(0, dynamic.string))

    let ret =
      based.new_query("SELECT 1")
      |> based.one(conn, decoder)
      |> should.be_ok

    let ret_two =
      based.new_query("SELECT '2'")
      |> based.one(conn, decoder_two)
      |> should.be_ok

    #(ret, ret_two)
  }

  let #(ret, ret_two) = result

  ret |> should.equal(1)
  ret_two |> should.equal("2")
}

fn test_config() -> based_pg.Config {
  based_pg.Config(
    ..based_pg.default_config(),
    host: "localhost",
    port: 54_322,
    database: "based_pg",
    user: "postgres",
    password: Some("based_pg_password"),
  )
}
