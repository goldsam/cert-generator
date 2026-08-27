# Cert Generator

[![Version](https://img.shields.io/badge/version-latest-blue)](https://github.com/goldsam/cert-generator/releases)
[![Docker Image](https://img.shields.io/badge/docker%20image-ghcr.io/goldsam/cert--generator:latest-green)](https://ghcr.io/goldsam/cert-generator)

## Overview

`cert-generator` is a lightweight tool for generating and managing self-signed SSL certificates for testing using OpenSSL based on a simple configuration file. The tool reads a JSON or YAML configuration file that defines a list of certificates to generate—including subject details, SAN entries, key size, digest algorithm, and validity period. If an existing certificate’s properties differ from the desired configuration, the certificate is automatically regenerated.

Packaged in a minimal Docker image (based on Alpine Linux), Cert Manager is ideal for CI/CD pipelines or local development.

## Usage

### Running the Docker Image

Run the container while mounting your configuration file (JSON or YAML):

```shell
docker run --rm -v $(pwd)/config.yaml:/certs/config.yaml ghcr.io/goldsam/cert-generator:latest
```
Replace `config.yaml` with the path to your configuration file. The container expects the configuration file at `/certs/config.yaml`.

In practice you will want to mount the whole directory rather than just the
config file, so that the generated certificates are written back to the host:

```shell
docker run --rm -v $(pwd)/certs:/certs ghcr.io/goldsam/cert-generator:latest /certs/config.yml
```

### Certificate authority persistence

Mounting that one directory is all that is required. The root CA is stored in a
`ca/` subdirectory of the mount:

```
certs/
├── ca/
│   ├── rootCA.pem       # the CA certificate
│   └── rootCA-key.pem   # the CA private key -- keep this out of version control
├── rootCA.crt           # copy of the CA certificate, for distribution
├── ca-certificates.crt  # system trust bundle including the CA
├── service1.crt
└── service1.key
```

Because the CA lives inside the mount, re-running the container reuses it
instead of generating a new one, so certificates issued by earlier runs keep
validating. Delete `ca/` to deliberately start over with a fresh authority.

Set the `CAROOT` environment variable to override the location:

```shell
docker run --rm -e CAROOT=/certs/my-ca -v $(pwd)/certs:/certs ghcr.io/goldsam/cert-generator:latest /certs/config.yml
```

Note that leaf certificates are re-issued on every run. They remain valid, since
they are signed by the persisted CA, but their serial numbers and keys change.

## Configuration


The image uses a configuration file (JSON or YAML) format specified by the [`./config.schema.json`](./config.schema.json) specifying a list of SSL certificates to generate. 

### Example

An example configuration is provided in  [`./example/config.yml`](./example/config.yml).

### Exit codes and error output

The entrypoint exits non-zero for any configuration it cannot use, with a
distinct code per failure mode. Diagnostics are written to **stderr**, so
stdout carries only progress and success output.

| Code | Meaning |
| --- | --- |
| 0 | All certificates are up to date |
| 1 | Wrong number of arguments |
| 2 | One or more certificates failed to generate |
| 3 | Configuration file does not exist |
| 4 | Configuration file is not parseable as YAML or JSON |
| 5 | Configuration file does not satisfy the schema |
| 6 | The certificate authority could not be loaded or created |
| 7 | The configuration defines no certificates |

## Building

To build the Docker image locally, clone the repository and run the following command in the repository's root directory:

```shell
docker build -t cert-generator .
```

## Testing

Build the image, then run the suites through the single entry point:

```shell
docker build -t cert-generator:test .
test/run-tests.sh
```

`test/run-tests.sh` accepts an image tag as its only argument (defaulting to
`cert-generator:test`) and exits non-zero if any suite fails. It runs:

| Suite | What it covers |
| --- | --- |
| [`test/config-validation.sh`](./test/suites/config-validation.sh) | YAML and JSON configs are accepted, and each rejection path reports its own exit code with a readable explanation |
| [`test/ca-persistence.sh`](./test/suites/ca-persistence.sh) | The root CA survives repeated runs against one mounted directory, so previously issued certificates keep validating |

Certificates are inspected with `openssl`, which the suites expect on the host.
The same entry point runs in CI and gates publishing of the image.

