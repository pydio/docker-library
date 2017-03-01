#!/bin/bash
set -e

if [ "${1:0:1}" = '-' ]; then
	set -- pydio "$@"
fi

if [ "$1" = 'pydio' ]; then
    shift
    exec php /usr/share/pydio/cmd.php "$@"
fi

exec "$@"
