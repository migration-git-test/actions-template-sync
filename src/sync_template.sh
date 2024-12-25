#!/usr/bin/env bash

set -e
# set -u
# set -x

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# shellcheck source=src/sync_template.sh
source "${SCRIPT_DIR}/sync_common.sh"

############################################
# Prechecks
############################################

if [[ -z "${PR_COMMIT_MSG}" ]]; then
  err "Missing env variable 'PR_COMMIT_MSG'";
  exit 1;
fi

if [[ -z "${SOURCE_REPO}" ]]; then
  err "Missing env variable 'SOURCE_REPO'";
  exit 1;
fi

if ! [ -x "$(command -v gh)" ]; then
  err "github-cli gh is not installed. 'https://github.com/cli/cli'";
  exit 1;
fi

if [[ -z "${TEMPLATE_SYNC_IGNORE_FILE_PATH}" ]]; then
  err "Missing env variable 'TEMPLATE_SYNC_IGNORE_FILE_PATH'";
  exit 1;
fi

########################################################
# Variables
########################################################

if [[ -z "${UPSTREAM_BRANCH}" ]]; then
  UPSTREAM_BRANCH="$(git remote show origin | awk '/HEAD branch/ {print $NF}')"
  info "Missing env variable 'UPSTREAM_BRANCH' setting to remote default ${UPSTREAM_BRANCH}";
fi

if [[ -n "${SRC_SSH_PRIVATEKEY_ABS_PATH}" ]]; then
  debug "using ssh private key for private source repository"
  export GIT_SSH_COMMAND="ssh -i ${SRC_SSH_PRIVATEKEY_ABS_PATH}"
fi

TEMPLATE_SYNC_IGNORE_FILE_PATH="${TEMPLATE_SYNC_IGNORE_FILE_PATH:-".templatesyncignore"}"
IS_WITH_TAGS="${IS_WITH_TAGS:-"false"}"
IS_FORCE_PUSH_PR="${IS_FORCE_PUSH_PR:-"false"}"
IS_KEEP_BRANCH_ON_PR_CLEANUP="${IS_KEEP_BRANCH_ON_PR_CLEANUP:-"false"}"
GIT_REMOTE_PULL_PARAMS="${GIT_REMOTE_PULL_PARAMS:---allow-unrelated-histories --squash --strategy=recursive -X theirs}"

TEMPLATE_REMOTE_GIT_HASH=$(git ls-remote "${SOURCE_REPO}" HEAD | awk '{print $1}')
SHORT_TEMPLATE_GIT_HASH=$(git rev-parse --short "${TEMPLATE_REMOTE_GIT_HASH}")

export TEMPLATE_GIT_HASH=${SHORT_TEMPLATE_GIT_HASH}
export PR_BRANCH="main"  # Use 'main' directly instead of creating a new branch
: "${PR_BODY:="Merge ${SOURCE_REPO} ${TEMPLATE_GIT_HASH}"}"
: "${PR_TITLE:-"upstream merge template repository"}"

# for some reasons the substitution is not working as expected
# so we substitute manually
# shellcheck disable=SC2016
PR_BODY=${PR_BODY//'${TEMPLATE_GIT_HASH}'/"${TEMPLATE_GIT_HASH}"}
# shellcheck disable=SC2016
PR_BODY=${PR_BODY//'${SOURCE_REPO}'/"${SOURCE_REPO}"}

# shellcheck disable=SC2016
PR_TITLE=${PR_TITLE//'${TEMPLATE_GIT_HASH}'/"${TEMPLATE_GIT_HASH}"}
# shellcheck disable=SC2016
PR_TITLE=${PR_TITLE//'${SOURCE_REPO}'/"${SOURCE_REPO}"}

debug "TEMPLATE_GIT_HASH ${TEMPLATE_GIT_HASH}"
debug "PR_BRANCH ${PR_BRANCH}"
debug "PR_BODY ${PR_BODY}"

# Check if the Ignore File exists inside .github folder or if it doesn't exist at all
if [[ -f ".github/${TEMPLATE_SYNC_IGNORE_FILE_PATH}" || ! -f "${TEMPLATE_SYNC_IGNORE_FILE_PATH}" ]]; then
  debug "using ignore file as in .github folder"
    TEMPLATE_SYNC_IGNORE_FILE_PATH=".github/${TEMPLATE_SYNC_IGNORE_FILE_PATH}"
fi

#####################################################
# Functions
#####################################################

# Check if the commit is already in history.
# exit 0 if so
# Arguments:
#   template_remote_git_hash
#######################################
function check_if_commit_already_in_hist_graceful_exit() {
  info "check if commit already in history"

  local template_remote_git_hash=$1

  git cat-file -e "${template_remote_git_hash}" || commit_not_in_hist=true
  if [ "${commit_not_in_hist}" != true ] ; then
    warn "repository is up to date!"
    exit 0
  fi
}

##########################################
# check if there are staged files.
# exit if not
##########################################
function check_staged_files_available_graceful_exit() {
  if git diff --quiet && git diff --staged --quiet; then
    info "nothing to commit"
    exit 0
  fi
}

#######################################
# force source file deletion if they had been deleted
#######################################
function force_delete_files() {
  info "force delete files"
  warn "force file deletion is enabled. Deleting files which are deleted within the target repository"
  local_current_git_hash=$(git rev-parse HEAD)

  info "current git hash: ${local_current_git_hash}"

  files_to_delete=$(git log --diff-filter D --pretty="format:" --name-only "${local_current_git_hash}"..HEAD | sed '/^$/d')
  warn "files to delete: ${files_to_delete}"
  if [[ -n "${files_to_delete}" ]]; then
    echo "${files_to_delete}" | xargs rm
  fi
}

#######################################
# pull source changes
# Arguments:
#   source_repo
#   git_remote_pull_params
##################################
function pull_source_changes() {
  info "pull changes from source repository"
  local source_repo=$1
  local git_remote_pull_params=$2

  eval "git pull ${source_repo} --tags ${git_remote_pull_params}" || pull_has_issues=true

  if [ "$pull_has_issues" == true ] ; then
    warn "There had been some git pull issues."
    warn "Maybe a merge issue."
    warn "We go on but it is likely that you need to fix merge issues within the created PR."
  fi
}

########################################################
# Logic
#######################################################

function arr_prechecks() {
  info "prechecks"
  echo "::group::prechecks"
  if [ "${IS_FORCE_PUSH_PR}" == "true" ]; then
    warn "skipping prechecks because we force push and pr"
    return 0
  fi

  check_if_commit_already_in_hist_graceful_exit "${TEMPLATE_REMOTE_GIT_HASH}"

  echo "::endgroup::"
}

function arr_checkout_branch_and_pull() {
  info "checkout branch and pull"
  cmd_from_yml "prepull"

  echo "::group::checkout branch and pull"

  debug "pull changes from upstream repository directly to main"
  git checkout main
  pull_source_changes "${SOURCE_REPO}" "${GIT_REMOTE_PULL_PARAMS}"

  restore_templatesyncignore_file "${TEMPLATE_SYNC_IGNORE_FILE_PATH}"

  if [ "$IS_FORCE_DELETION" == "true" ]; then
    force_delete_files
  fi

  echo "::endgroup::"
}

function arr_commit() {
  info "commit"

  cmd_from_yml "precommit"

  echo "::group::commit changes"

  git add .
  git commit -m "${PR_COMMIT_MSG}" || commit_has_issues=true

  if [ "$commit_has_issues" == true ] ; then
    warn "No changes to commit."
  fi

  echo "::endgroup::"
}

function arr_push() {
  info "push changes"
  local is_force=$1
  local is_with_tags=$2

  args=(--set-upstream origin main)

  if [ "$is_force" == true ] ; then
    warn "forcing the push."
    args+=(--force)
  fi

  if [ "$is_with_tags" == true ] ; then
    warn "include tags."
    args+=(--tags)
  fi

  git push "${args[@]}"
}

function arr_create_pr() {
  info "create pr"
  local title=$1
  local body=$2

  gh pr create \
    --title "${title}" \
    --body "${body}" \
    --base main \
    --head main || create_pr_has_issues=true

  if [ "$create_pr_has_issues" == true ] ; then
    warn "Creating the PR failed."
    warn "Eventually it is already existent."
    return 1
  fi
  return 0
}

# Run the functions
arr_prechecks
arr_checkout_branch_and_pull
arr_commit
arr_push true false
arr_create_pr "${PR_TITLE}" "${PR_BODY}"
