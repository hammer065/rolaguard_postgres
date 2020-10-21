FROM postgres:alpine

COPY *.sql /docker-entrypoint-initdb.d/

RUN mkdir /data
COPY data/*.csv /data/

EXPOSE 5432