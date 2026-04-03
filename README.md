# based_pg

[![Package Version](https://img.shields.io/hexpm/v/based_pg)](https://hex.pm/packages/based_pg)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/based_pg/)

## WIP

This package should be used with [`based`](https://github.com/stndrs/based)

```sh
gleam add based_pg
```

```gleam
import based/db
import based/pg
import based/sql

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

  let assert Ok(_) =
    sql.from(users)
    |> sql.select([sql.col("name"), sql.col("email")])
    |> sql.where([sql.col("id") |> sql.eq(sql.int(1), of: sql.value)])
    |> db.to_sql_query(db)
    |> db.query(db)
}
```

Further documentation can be found at <https://hexdocs.pm/based_pg>.

## Development

```sh
docker-compose up # Starts postgres and adminer containers. Required for tests
gleam run         # Run the project
gleam test        # Run the tests
gleam shell       # Run an Erlang shell
```
