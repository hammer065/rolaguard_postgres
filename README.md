# RoLaGuard Community Edition

## Postgres

This repository contains just a Dockerfile pointing to the latest version of PostgresSQL for Alpine Linux (see [postgres - Docker Official Images](https://hub.docker.com/_/postgres)).
At startup time, a postgres database will be created, and ready to use it, based on configuration parameters on enviromet variables and scrips SQL provided.

To access the main project with instructions to easily run the rolaguard locally visit the [RoLaGuard](https://github.com/Argeniss-Software/rolaguard) repository. For contributions, please visit the [CONTRIBUTIONS](https://github.com/Argeniss-Software/rolaguard/blob/master/CONTRIBUTIONS.md) file

### How to use it locally

Build a docker image locally:

```bash
docker build -t rolaguard-postgres .
```
