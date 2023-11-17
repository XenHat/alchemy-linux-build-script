#!/bin/bash
# Alchemy Viewer linux build script
#
# Copyright 2023 XenHat <me@xenh.at>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy 
# of this software and associated documentation files (the “Software”), to deal
# in the Software without restriction, including without limitation the rights 
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell 
# copies of the Software, and to permit persons to whom the Software is 
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in 
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
# THE SOFTWARE.

set -e

FULL_PATH_TO_SCRIPT="$(realpath "${BASH_SOURCE[-1]}")"
SCRIPT_DIRECTORY="$(dirname "$FULL_PATH_TO_SCRIPT")"
SCRIPT_FILENAME="$(basename "$FULL_PATH_TO_SCRIPT")"

distribution=$(awk -F'=' '/^ID=/ {print tolower($2)}' /etc/*-release 2> /dev/null)
packages_file=''
case "$distribution" in
  arch) packages_file=archlinux.txt
    is_archlinux=1
    ;;
  *) echo "Distribution $distribution is currently not supported"
    ;;
esac
# Install packages required to build the viewer if the distribution is 
# supported, otherwise try to build anyway instead of aborting.
# This can be useful if the user has the required packages already 
# installed on an unsupported distribution
echo "Installing build dependencies"
if [[ -n "$packages_file" ]]; then
  packages_to_install=()
  while IFS= read -r line
  do
    packages_to_install+=("$line")
  done < "${SCRIPT_DIRECTORY}"/packages/$packages_file

  # update system and Install missing packages
  if [[ $is_archlinux ]]; then
    # shellcheck disable=SC2068 
    sudo pacman -Syu --needed ${packages_to_install[@]}
  fi
fi

# Set up the build environment
virtualenv3 ".venv"
source .venv/bin/activate
pip install --upgrade cmake llbase llsd certifi autobuild ninja
source .venv/bin/activate

# left here for future cross-compiling need
if [[ -z "$CARCH" ]]; then
  CARCH=$(uname -m)
fi
_logfile="build.${CARCH}.$(date +%s).log"
build_jobs=$(nproc)

if [[ " ${BUILDENV[*]} " =~ ' ccache ' ]] && command -v ccache >/dev/null 2>&1; then
  AL_CMAKE_CONFIG+=("-DCMAKE_CXX_COMPILER_LAUNCHER=$(which ccache)")
  echo "ccache was found and will be used"
fi
if command -v clang++ >/dev/null 2>&1; then
  AL_CMAKE_CONFIG+=("-DCMAKE_C_COMPILER=$(which clang)")
  AL_CMAKE_CONFIG+=("-DCMAKE_CXX_COMPILER=$(which clang++)")
  echo "clang was found and will be used instead of gcc"
  NO_SMART_JOB_COUNT=1
fi

if [[ -z "$NO_SMART_JOB_COUNT" ]]; then
  if [[ ${build_jobs} -gt 1 ]]; then
    jobs=1
    # The viewer requires an average of 2GB of memory per core to link
    # Note: Behaviour change compared to the previous versions:
    # This script will no longer try to allocate build memory into swap
    # This is bad practice, and swap should be reserved to evict process
    # memory from physical ram to make place for the current workset.
    # This script will now try to check if swap is present and sufficent
    # for the current used memory to be stored in swap before allocating,
    # and will fallback to conservative allocation if swap is not available
    gigperlinkprocess=2
    mempercorekb=$((gigperlinkprocess * 1048576))
    requiredmemorykb=$(($(nproc) * mempercorekb))
    free_output="$(free --kilo --total | tail -n+2 | tr -s ' ')"
    physical_output=$(grep "Mem:" <<<"$free_output")
    usedmemorykbphysical=$(cut -d ' ' -f 3 <<<"$physical_output")
    totalmemorykbphysical=$(cut -d ' ' -f 2 <<<"$physical_output")
    swap_output=$(grep Swap: <<<"$free_output")
    # Determine available swap space
    availableswapkb=0
    if [[ -n "$swap_output" ]]; then
      availableswapkb=$(cut -d ' ' -f 4 <<<"$swap_output")
    fi
    availablememorykbphysical=$(cut -d ' ' -f 7 <<<"$free_output")
    if [[ ${requiredmemorykb} -gt ${availablememorykbphysical} ]]; then
      echo "Not enough physical memory to build with all cores"
      if [[ ${usedmemorykbphysical} -lt ${availableswapkb} ]]; then
        # There is enough swap to fit all the used memory
        # use all physical ram as swap will do its job
        echo "Using swap memory to store current processes memory"
        jobs=$(((totalmemorykbphysical / 1024 / 1024) / gigperlinkprocess))
      else
        # Not enough swap to hold ram contents, calculate manually
        while [[ $((jobs * mempercorekb)) -lt ${availablememorykbphysical} ]]; do
          ((jobs++))
          echo "${jobs} jobs would consume $(((jobs * mempercorekb) / 1024 / 1024))GB"
        done
        # Back off one job count. Not sure why I have to do this but
      fi
      build_jobs=${jobs}
    fi
  fi
  echo "Adjusted job count: ${build_jobs}"
fi
export AUTOBUILD_CPU_COUNT=$build_jobs
AL_CMAKE_CONFIG=(
  -DLL_TESTS:BOOL=ON
  -DDISABLE_FATAL_WARNINGS=ON
  -DUSE_LTO:BOOL=OFF
  -DVIEWER_CHANNEL="Alchemy Test"
)
# And now we configure and build the viewer with our adjusted configuration
autobuild configure -A 64 -c ReleaseOS -- "${AL_CMAKE_CONFIG[@]}" > >(tee -a "$_logfile") 2> >(tee -a "$_logfile" >&2)
echo "Building with ${AUTOBUILD_CPU_COUNT} jobs"
autobuild build -A 64 -c ReleaseOS --no-configure > >(tee -a "$_logfile") 2> >(tee -a "$_logfile" >&2)
