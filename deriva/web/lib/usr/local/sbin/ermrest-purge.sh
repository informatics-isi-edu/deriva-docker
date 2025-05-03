#!/bin/bash

outfile=$(mktemp /tmp/ermrest-purge.XXXXX)

cleanup()
{
  rm -f "$outfile"
}

trap cleanup 0

su -c "ermrest-registry-purge" - ermrest > "$outfile" 2>&1
status=$?

grep -v DELETED "$outfile"

exit $status


