FROM postgres:13.0-alpine

COPY *.sql /docker-entrypoint-initdb.d/

RUN mkdir /data
COPY data/*.csv /data/

EXPOSE 5432