FROM postgres:9

COPY ./anchore-bootstrap.sql.gz /docker-entrypoint-initdb.d/