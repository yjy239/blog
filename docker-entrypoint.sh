#!/bin/sh
set -e

if [ "$1" = 'web' ]; then
    exec nginx -g 'daemon off;'
fi

exec "$@"
