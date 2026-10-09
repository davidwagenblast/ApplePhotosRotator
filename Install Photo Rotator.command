#!/bin/bash
# Double-click in Finder to build, install and open Photo Rotator.
cd "$(dirname "$0")" && ./install.sh
status=$?
echo
read -n 1 -s -r -p "Press any key to close this window."
exit $status
