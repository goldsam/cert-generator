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

## Configuration


The image uses a configuration file (JSON or YAML) format specified by the [`./config.schema.json`](./config.schema.json) specifying a list of SSL certificates to generate. 

### Example

An example configuration is provided in  [`./example/config.yml`](./example/config.yml).

## Building

To build the Docker image locally, clone the repository and run the following command in the repository's root directory:

```shell
docker build -t cert-generator .
```
