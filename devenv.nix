{
  pkgs,
  ...
}:

{
  languages = {
    gleam.enable = true;
    erlang.enable = true;
  };

  # Match the port and credentials used in tests
  env = {
    PGUSER = "postgres";
    PGPASSWORD = "postgres";
    PGDATABASE = "based_pg";
  };

  services.postgres = {
    enable = true;
    package = pkgs.postgresql_18;
    listen_addresses = "127.0.0.1,::1";
    port = 5432;

    initdbArgs = [
      "--locale=C"
      "--encoding=UTF8"
      "--username=postgres"
    ];

    initialDatabases = [
      { name = "based_pg"; }
    ];

    initialScript = ''
      ALTER USER postgres WITH PASSWORD 'postgres';
    '';

    settings = {
      log_statement = "all";
    };
  };

  enterTest = ''
    echo "Running tests"
    pg_isready -p 5432
  '';
}
