FROM postgres:13-alpine

COPY *.sql /docker-entrypoint-initdb.d/

COPY data/*.csv /data/

EXPOSE 5432
