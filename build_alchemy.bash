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
# SCRIPT_FILENAME="$(basename "$FULL_PATH_TO_SCRIPT")"

# Function to install packages based on the package manager
install_packages() {
    case $1 in
        "apt")
            sudo apt update
            sudo apt install -y "${packages[@]}"
            ;;
        "pacman")
            sudo pacman -Syu --noconfirm "${packages[@]}"
            ;;
        "dnf")
            dnf install -y "${packages[@]}"
            ;;
        "emerge")
            sudo emerge "${packages[@]}"
            ;;
        *)
            echo "Unsupported package manager"
            exit 1
            ;;
    esac
}

# Function to read package names from the distribution-specific txt file
read_packages() {
    local file_path="$SCRIPT_DIRECTORY/needed_packages/$1.txt"
    if [ -f "$file_path" ]; then
        mapfile -t packages < "$file_path"
    else
        echo "Package file not found for $1"
        echo "Please submit a pull request once you got a package list that works for $1"
        exit 1
    fi
}

# Identify the distribution
if [ -f "/etc/os-release" ]; then
    source /etc/os-release
    packages_list="$ID"
    case $ID in
        "arch" | "manjaro")
            manager="pacman"
            ;;
        "debian" | "ubuntu")
            manager="apt"
            ;;
        "nobara")
            packages_list="fedora"
            ;&
        "fedora")
            manager="dnf"
            ;;
        "gentoo" | "funtoo")
            manager="emerge"
            ;;
        "pop")
            manager="apt"
            ;;
        *)
            echo "Unsupported distribution"
            exit 1
            ;;
    esac

    read_packages "$packages_list"
    install_packages "$manager"
else
    echo "Unable to determine the Linux distribution"
    exit 1
fi

echo "Packages installed successfully"

# Set up the build environment
virtualenv --python=/usr/bin/python3 ".venv"
source .venv/bin/activate
pip install --upgrade --quiet cmake llbase llsd certifi autobuild ninja
source .venv/bin/activate

# left here for future cross-compiling need
if [[ -z "$CARCH" ]]; then
  CARCH=$(uname -m)
fi

echo ""
echo "Configuring the build"
_logfile="build.${CARCH}.$(date +%s).log"
build_jobs=$(nproc)

AL_CMAKE_CONFIG=(
  -DLL_TESTS:BOOL="${ENABLE_TESTS:-ON}"
  -DDISABLE_FATAL_WARNINGS=ON
  -DUSE_LTO:BOOL=OFF
  -DVIEWER_CHANNEL="Alchemy Test"
)

if [[ -z "$NO_CCACHE" ]] && command -v ccache >/dev/null 2>&1; then
  AL_CMAKE_CONFIG+=("-DCMAKE_CXX_COMPILER_LAUNCHER=$(which ccache)")
  echo "ccache was found and will be used"
fi
if [[ -z "$NO_CLANG" ]] && command -v clang++ >/dev/null 2>&1; then
  AL_CMAKE_CONFIG+=("-DCMAKE_C_COMPILER=$(which clang)")
  AL_CMAKE_CONFIG+=("-DCMAKE_CXX_COMPILER=$(which clang++)")
  echo "clang was found and will be used instead of gcc"
fi

# The viewer requires an average of 2GB of memory per core to link
# Note: Behaviour change compared to the previous versions:
# This script will no longer try to allocate build memory into swap
# This is bad practice, and swap should be reserved to evict process
# memory from physical ram to make place for the current workset.
# This script will now try to check if swap is present and sufficent
# for the current used memory to be stored in swap before allocating,
# and will fallback to conservative allocation if swap is not available
if [[ -z "$NO_SMART_JOB_COUNT" ]]; then
  if [[ ${build_jobs} -gt 1 ]]; then
    mempercorekb=$((1048576))
    requiredmemorykb=$(($(nproc) * mempercorekb))
    free_output="$(free --kilo --total | tail -n+2 | tr -s ' ')"
    physical_output=$(grep "Mem:" <<<"$free_output")
    totalmemorykbphysical=$(cut -d ' ' -f 2 <<<"$physical_output")
    usedmemorykbphysical=$(cut -d ' ' -f 3 <<<"$physical_output")
    availablememorykbphysical=$(cut -d ' ' -f 7 <<<"$free_output")
    total_output=$(grep "Total:" <<<"$free_output")
    totalmemorykbcombined=$(cut -d ' ' -f 2 <<<"$total_output")
    # usedmemorytotal=$(cut -d ' ' -f 2 <<<"$total_output")
    # freememorytotal=$(cut -d ' ' -f 4 <<<"$total_output")
    swap_output=$(grep Swap: <<<"$free_output")
    availableswapkb=0
    if [[ -n "$swap_output" ]]; then
      availableswapkb=$(cut -d ' ' -f 4 <<<"$swap_output")
    fi
    echo "Required memory at $(nproc) jobs:         $((requiredmemorykb/1024/1024))GB"
    echo "Available memory (counting swap):   $((totalmemorykbcombined/1024/1024))GB"
    echo "Total RAM:                          $((totalmemorykbphysical/1024/1024))GB"
    if [[ ${requiredmemorykb} -gt ${totalmemorykbphysical} ]]; then
      echo "Not enough physical memory to use all cores"
      if [[ ${usedmemorykbphysical} -lt ${availableswapkb} ]]; then
        # There is enough swap to fit all the used memory. Use all physical ram as swap will do its job
        echo "Using swap memory to store current processes memory"
        # We do not want to compile in swap, so adjust accordingly
        jobs=$(((totalmemorykbphysical) / mempercorekb))
      else
        # TODO: Verify this logic on low-ram systems
        # Not enough swap to hold ram contents, calculate manually
        jobs=1
        echo "${jobs} job  would consume $(((jobs * mempercorekb) / 1024 / 1024))GB"
        while [[ $((jobs * mempercorekb)) -le ${availablememorykbphysical} ]]; do
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

# And now we configure and build the viewer with our adjusted configuration
autobuild configure -A 64 -c ReleaseOS -- "${AL_CMAKE_CONFIG[@]}" > >(tee -a "$_logfile") 2> >(tee -a "$_logfile" >&2)
echo "Building with ${AUTOBUILD_CPU_COUNT} jobs"
autobuild build -A 64 -c ReleaseOS --no-configure > >(tee -a "$_logfile") 2> >(tee -a "$_logfile" >&2)
