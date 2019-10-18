#!/usr/bin/env bash

# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x
set -e
set -u

WORK="$(pwd)"

# Old bash versions can't expand empty arrays, so we always include at least this option.
CMAKE_OPTIONS=("-DCMAKE_OSX_ARCHITECTURES=x86_64")

uname

case "$(uname)" in
"Linux")
  GH_RELEASE_TOOL_ARCH="linux_amd64"
  NINJA_OS="linux"
  BUILD_PLATFORM="Linux_x64"
  PYTHON="python3"
  ;;

"Darwin")
  GH_RELEASE_TOOL_ARCH="darwin_amd64"
  NINJA_OS="mac"
  BUILD_PLATFORM="Mac_x64"
  PYTHON="python3"
  brew install md5sha1sum
  ;;

"MINGW"*)
  GH_RELEASE_TOOL_ARCH="windows_amd64"
  NINJA_OS="win"
  BUILD_PLATFORM="Windows_x64"
  PYTHON="python"
  CMAKE_OPTIONS+=("-DCMAKE_C_COMPILER=cl.exe" "-DCMAKE_CXX_COMPILER=cl.exe")
  choco install zip
  ;;

*)
  echo "Unknown OS"
  exit 1
  ;;
esac

###### START EDIT ######
TARGET_REPO_ORG="google"
TARGET_REPO_NAME="amber"
BUILD_REPO_ORG="google"
BUILD_REPO_NAME="gfbuild-amber"
###### END EDIT ######

COMMIT_ID="$(cat "${WORK}/COMMIT_ID")"

ARTIFACT="${BUILD_REPO_NAME}"
ARTIFACT_VERSION="${COMMIT_ID}"
GROUP_DOTS="github.${BUILD_REPO_ORG}"
GROUP_SLASHES="github/${BUILD_REPO_ORG}"
TAG="${GROUP_SLASHES}/${ARTIFACT}/${ARTIFACT_VERSION}"

BUILD_REPO_SHA="${GITHUB_SHA}"
CLASSIFIER="${BUILD_PLATFORM}_${CONFIG}"
POM_FILE="${BUILD_REPO_NAME}-${ARTIFACT_VERSION}.pom"
INSTALL_DIR="${ARTIFACT}-${ARTIFACT_VERSION}-${CLASSIFIER}"
AMBER_NDK_INSTALL_DIR="${ARTIFACT}-${ARTIFACT_VERSION}-android_ndk"

GH_RELEASE_TOOL_USER="c4milo"
GH_RELEASE_TOOL_VERSION="v1.1.0"

export PATH="${HOME}/bin:$PATH"

mkdir -p "${HOME}/bin"

pushd "${HOME}/bin"

# Install github-release.
curl -fsSL -o github-release.tar.gz "https://github.com/${GH_RELEASE_TOOL_USER}/github-release/releases/download/${GH_RELEASE_TOOL_VERSION}/github-release_${GH_RELEASE_TOOL_VERSION}_${GH_RELEASE_TOOL_ARCH}.tar.gz"
tar xf github-release.tar.gz

# Install ninja.
curl -fsSL -o ninja-build.zip "https://github.com/ninja-build/ninja/releases/download/v1.9.0/ninja-${NINJA_OS}.zip"
unzip ninja-build.zip

ls

popd

###### START EDIT ######
CMAKE_GENERATOR="Ninja"
CMAKE_BUILD_TYPE="${CONFIG}"
CMAKE_OPTIONS+=("-DAMBER_USE_LOCAL_VULKAN=1")

git clone https://github.com/${TARGET_REPO_ORG}/${TARGET_REPO_NAME}.git "${TARGET_REPO_NAME}"
cd "${TARGET_REPO_NAME}"
git checkout "${COMMIT_ID}"

"${PYTHON}" tools/git-sync-deps
###### END EDIT ######

###### BEGIN BUILD ######
BUILD_DIR="b_${CONFIG}"

mkdir -p "${BUILD_DIR}"
pushd "${BUILD_DIR}"

cmake -G "${CMAKE_GENERATOR}" .. "-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}" "${CMAKE_OPTIONS[@]}"
cmake --build . --config "${CMAKE_BUILD_TYPE}"
# Skip install step since Amber does not add install targets.
#cmake "-DCMAKE_INSTALL_PREFIX=../${INSTALL_DIR}" "-DBUILD_TYPE=${CMAKE_BUILD_TYPE}" -P cmake_install.cmake
popd

# Do Android build when on Linux Debug.
case "$(uname)" in
"Linux")
  if test "${CONFIG}" = "Debug"; then

    # Download NDK.

    pushd "${HOME}"
    ANDROID_HOST_PLATFORM="linux"
    echo "Installing Android NDK ${ANDROID_HOST_PLATFORM} (linux, darwin, or windows) ..."

    ANDROID_NDK_FILENAME="android-ndk-r20-${ANDROID_HOST_PLATFORM}-x86_64.zip"

    ANDROID_NDK_HOME="$(pwd)/android-ndk-r20"
    export ANDROID_NDK_HOME

    echo "... to ${ANDROID_NDK_HOME}"

    if test ! -d "${ANDROID_NDK_HOME}"; then
      # Android "android-ndk.zip" "ndk-bundle"
      curl -sSo "${ANDROID_NDK_FILENAME}" "https://dl.google.com/android/repository/${ANDROID_NDK_FILENAME}"
      unzip -q "${ANDROID_NDK_FILENAME}"
      rm "${ANDROID_NDK_FILENAME}"
      test -d "${ANDROID_NDK_HOME}"
    fi

    popd

    "${PYTHON}" tools/update_build_version.py . samples/ third_party/
    "${PYTHON}" tools/update_vk_wrappers.py . .
    mkdir -p "${AMBER_NDK_INSTALL_DIR}"
    pushd "${AMBER_NDK_INSTALL_DIR}"
    # Build all ABIs.
    "${ANDROID_NDK_HOME}/ndk-build" -C ../samples NDK_PROJECT_PATH=. "NDK_LIBS_OUT=$(pwd)/libs" "NDK_APP_OUT=$(pwd)/app" -j2 APP_ABI="arm64-v8a armeabi-v7a x86 x86_64"
    popd
  fi
  ;;

*)
  echo "Skipping Android build."
  ;;
esac

###### END BUILD ######

###### START EDIT ######

# Amber has no install targets, so manually copy amber binary.

mkdir -p "${INSTALL_DIR}/bin"

case "$(uname)" in
"Linux")
  cp "${BUILD_DIR}/amber" "${INSTALL_DIR}/bin/"
  ;;

"Darwin")
  cp "${BUILD_DIR}/amber" "${INSTALL_DIR}/bin/"
  ;;

"MINGW"*)
  cp "${BUILD_DIR}/amber.exe" "${INSTALL_DIR}/bin/"
  cp "${BUILD_DIR}/amber.pdb" "${INSTALL_DIR}/bin/" || true
  ;;

*)
  echo "Unknown OS"
  exit 1
  ;;
esac

for f in "${INSTALL_DIR}/bin/"*; do
  echo "${BUILD_REPO_SHA}">"${f}.build-version"
  cp "${WORK}/COMMIT_ID" "${f}.version"
done

# Do the Android "install" step when on Linux Debug.
case "$(uname)" in
"Linux")
  if test "${CONFIG}" = "Debug"; then
    # We just want the libs directory.
    # amber-1827383-android_ndk/app/local/{arm64-v8a, ...}/...
    # amber-1827383-android_ndk/libs/{arm64-v8a, ...}/amber_ndk
    rm -rf "${AMBER_NDK_INSTALL_DIR}/app"
    for f in "${AMBER_NDK_INSTALL_DIR}/libs/"*/*; do
      echo "${BUILD_REPO_SHA}">"${f}.build-version"
      cp "${WORK}/COMMIT_ID" "${f}.version"
    done
  fi
  ;;

*)
  echo "Skipping Android install step."
  ;;
esac

###### END EDIT ######

GRAPHICSFUZZ_COMMIT_SHA="b82cf495af1dea454218a332b88d2d309657594d"
OPEN_SOURCE_LICENSES_URL="https://github.com/google/gfbuild-graphicsfuzz/releases/download/github/google/gfbuild-graphicsfuzz/${GRAPHICSFUZZ_COMMIT_SHA}/OPEN_SOURCE_LICENSES.TXT"

# Add licenses file.
curl -fsSL -o OPEN_SOURCE_LICENSES.TXT "${OPEN_SOURCE_LICENSES_URL}"
cp OPEN_SOURCE_LICENSES.TXT "${INSTALL_DIR}/"

# zip file.
pushd "${INSTALL_DIR}"
zip -r "../${INSTALL_DIR}.zip" ./*
popd

sha1sum "${INSTALL_DIR}.zip" >"${INSTALL_DIR}.zip.sha1"

# POM file.
sed -e "s/@GROUP@/${GROUP_DOTS}/g" -e "s/@ARTIFACT@/${ARTIFACT}/g" -e "s/@VERSION@/${ARTIFACT_VERSION}/g" "../fake_pom.xml" >"${POM_FILE}"

sha1sum "${POM_FILE}" >"${POM_FILE}.sha1"

DESCRIPTION="$(echo -e "Automated build for ${TARGET_REPO_NAME} version ${COMMIT_ID}.\n$(git log --graph -n 3 --abbrev-commit --pretty='format:%h - %s <%an>')")"


# Do the Android zip step when on Linux Debug.
case "$(uname)" in
"Linux")
  if test "${CONFIG}" = "Debug"; then
    cp OPEN_SOURCE_LICENSES.TXT "${AMBER_NDK_INSTALL_DIR}/"

    pushd "${AMBER_NDK_INSTALL_DIR}"
    zip -r "../${AMBER_NDK_INSTALL_DIR}.zip" ./*
    popd

    sha1sum "${AMBER_NDK_INSTALL_DIR}.zip" >"${AMBER_NDK_INSTALL_DIR}.zip.sha1"

  fi
  ;;

*)
  echo "Skipping Android zip step."
  ;;
esac

# Only release from master branch commits.
# shellcheck disable=SC2153
if test "${GITHUB_REF}" != "refs/heads/master"; then
  exit 0
fi

# We do not use the GITHUB_TOKEN provided by GitHub Actions.
# We cannot set enviroment variables or secrets that start with GITHUB_ in .yml files,
# but the github-release tool requires GITHUB_TOKEN, so we set it here.
export GITHUB_TOKEN="${GH_TOKEN}"

github-release \
  "${BUILD_REPO_ORG}/${BUILD_REPO_NAME}" \
  "${TAG}" \
  "${BUILD_REPO_SHA}" \
  "${DESCRIPTION}" \
  "${INSTALL_DIR}.zip"

github-release \
  "${BUILD_REPO_ORG}/${BUILD_REPO_NAME}" \
  "${TAG}" \
  "${BUILD_REPO_SHA}" \
  "${DESCRIPTION}" \
  "${INSTALL_DIR}.zip.sha1"

# Do the Android release step when on Linux Debug.
case "$(uname)" in
"Linux")
  if test "${CONFIG}" = "Debug"; then
    github-release \
      "${BUILD_REPO_ORG}/${BUILD_REPO_NAME}" \
      "${TAG}" \
      "${BUILD_REPO_SHA}" \
      "${DESCRIPTION}" \
      "${AMBER_NDK_INSTALL_DIR}.zip"

    github-release \
      "${BUILD_REPO_ORG}/${BUILD_REPO_NAME}" \
      "${TAG}" \
      "${BUILD_REPO_SHA}" \
      "${DESCRIPTION}" \
      "${AMBER_NDK_INSTALL_DIR}.zip.sha1"
  fi
  ;;

*)
  echo "Skipping Android release step."
  ;;
esac


# Don't fail if pom cannot be uploaded, as it might already be there.

github-release \
  "${BUILD_REPO_ORG}/${BUILD_REPO_NAME}" \
  "${TAG}" \
  "${BUILD_REPO_SHA}" \
  "${DESCRIPTION}" \
  "${POM_FILE}" || true

github-release \
  "${BUILD_REPO_ORG}/${BUILD_REPO_NAME}" \
  "${TAG}" \
  "${BUILD_REPO_SHA}" \
  "${DESCRIPTION}" \
  "${POM_FILE}.sha1" || true

# Don't fail if OPEN_SOURCE_LICENSES.TXT cannot be uploaded, as it might already be there.

github-release \
  "${BUILD_REPO_ORG}/${BUILD_REPO_NAME}" \
  "${TAG}" \
  "${BUILD_REPO_SHA}" \
  "${DESCRIPTION}" \
  "OPEN_SOURCE_LICENSES.TXT" || true
