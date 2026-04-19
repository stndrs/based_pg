# based_pg

[![Package Version](https://img.shields.io/hexpm/v/based_pg)](https://hex.pm/packages/based_pg)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/based_pg/)

A PostgreSQL adapter for [`based`](https://github.com/stndrs/based).

```sh
gleam add based_pg
```

```gleam
import based
import based/pg
import based/sql
import gleam/dynamic/decode
import pg_value

pub fn main() {
  let database =
    pg.config
    |> pg.database("my_database")
    |> pg.username("postgres")
    |> pg.password("postgres")
    |> pg.new

  let assert Ok(_) = pg.start(database)

  let db = pg.db(database)

  let users = sql.table("users")

  let decoder = {
    use name <- decode.field(0, decode.string)
    use email <- decode.field(1, decode.string)
    decode.success(#(name, email))
  }

  let assert Ok(rows) =
    sql.from(users)
    |> sql.select([sql.column("name"), sql.column("email")])
    |> sql.where([sql.column("id") |> sql.eq(pg_value.int(1), of: sql.val)])
    |> sql.to_query(db.sql)
    |> based.all(db, decoder)
}
```

Further documentation can be found at <https://hexdocs.pm/based_pg>.

## Development

```sh
docker-compose up # Starts postgres container. Required for tests
gleam test        # Run the tests
gleam shell       # Run an Erlang shell
```
