# dba-admin-scripts

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.21881333.svg)](https://doi.org/10.5281/zenodo.21881333)
[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD_3--Clause-blue.svg)](LICENSE)

Generic database and AWS command-line scripts, published by the Database
Administration team at the Laboratory for Atmospheric and Space Physics (LASP),
University of Colorado Boulder.

These are general-purpose helpers for people who work with databases and cloud
resources from the command line — routine administration, reporting, backup and
restore, and setup tasks that are otherwise repetitive to run by hand. They are
written to be readable and adaptable rather than tied to any particular
deployment, so they can serve as a starting point for your own environment.

## Layout

| Directory | Contents |
|---|---|
| `oracle/` | Oracle database administration |
| `postgres/` | PostgreSQL administration |
| `aws/` | AWS CLI helpers |
| `general/` | Utilities not specific to one platform |

Every script carries a comment header describing its purpose, usage, and
arguments. Read that header before running anything.

## Before you run these

They are provided as-is under the BSD 3-Clause License, with no warranty. Some
perform destructive or high-impact operations — backups, restores, schema
changes. Review a script, understand what it does, and try it somewhere safe
before pointing it at anything you care about.

Paths, credentials, and connection details will need to be adapted to your own
environment.

## Contributing

This repository is published automatically from an internal repository, so
edits made here are overwritten on the next publish and pull requests against
these files cannot be merged directly. Bug reports and suggestions are welcome
as issues — please open one rather than a PR.

## Citing

Archived on Zenodo. The DOI above is the *concept* DOI — it always resolves to
the most recent release, so it is the one to cite:

> McClellan, B., Turns, B., Schmidt, R., & Sadler, C. dba-admin-scripts:
> generic database and AWS command-line scripts. Zenodo.
> https://doi.org/10.5281/zenodo.21881333

To cite the exact version you used instead, take the version-specific DOI from
that release's Zenodo page. Machine-readable metadata is in
[CITATION.cff](CITATION.cff); GitHub's "Cite this repository" button reads it.

## License

BSD 3-Clause. See [LICENSE](LICENSE).

Copyright (c) 2026, Regents of the University of Colorado
