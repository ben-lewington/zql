#!/usr/bin/env bash

compose="podman compose -f ./container/db.yml"

$compose down
$compose build --pull
$compose up -d postgres
