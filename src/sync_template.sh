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
debug "PR_TITLE ${PR_TITLE}"
debug "PR_BODY ${PR_BODY}"

# Check if the Ignore File exists inside .github folder or if it doesn't exist at all
if [[ -f ".github/${TEMPLATE_SYNC_IGNORE_FILE_PATH}" || ! -f "${TEMPLATE_SYNC_IGNORE_FILE_PATH}" ]]; then
  debug "using ignore file as in .github folder"
    TEMPLATE_SYNC_IGNORE_FILE_PATH=".github/${TEMPLATE_SYNC_IGNORE_FILE_PATH}"
fi

#####################################################
# Functions
#####################################################

# Skip the branch creation and PR directly from the source repository
function create_pr_from_source_repo() {
  info "create pr from source repo"
  
  gh pr create \
    --title "${PR_TITLE}" \
    --body "${PR_BODY}" \
    --base "${UPSTREAM_BRANCH}" \
    --head "${SOURCE_REPO}:${UPSTREAM_BRANCH}" \
    --label "${PR_LABELS}" \
    --reviewer "${REVIEWERS}" || create_pr_has_issues=true

  if [ "$create_pr_has_issues" == true ] ; then
    warn "Creating the PR failed."
    warn "Eventually it is already existent."
    return 1
  fi
  return 0
}

# cleanup older prs based on labels
function cleanup_older_prs () {
  info "cleanup older prs"

  local upstream_branch=$1
  local pr_labels=$2
  local is_keep_branch_on_pr_cleanup=$3

  if [[ -z "${pr_labels}" ]]; then
    warn "env var 'PR_LABELS' is empty. Skipping older prs cleanup"
    return 0
  fi

  older_prs=$(gh pr list \
    --base "${upstream_branch}" \
    --state open \
    --label "${pr_labels}" \
    --json number,headRefName \
    --jq '.[]')

  for older_pr in $older_prs
  do
    branch_name=$(echo "$older_pr" | jq -r .headRefName)
    pr_number=$(echo "$older_pr" | jq -r .number)

    if [ "$branch_name" == "${UPSTREAM_BRANCH}" ] ; then
      warn "local branch name equals remote pr branch name ${UPSTREAM_BRANCH}. Skipping pr cleanup for this branch"
      continue
    fi

    if [ "$is_keep_branch_on_pr_cleanup" == true ] ; then
      gh pr close -c "[actions-template-sync] :construction_worker: automatically closed because there is a new open PR. Branch is kept alive" "$pr_number"
      debug "Closed PR #${older_pr} but kept the branch"
    else
      gh pr close -c "[actions-template-sync] :construction_worker: automatically closed because there is a new open PR" -d "$pr_number"
      debug "Closed PR #${older_pr}"
    fi
  done
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
  echo "::endgroup::"
}

# Main logic to create PR directly from source repo
arr_prechecks
create_pr_from_source_repo
cleanup_older_prs "${UPSTREAM_BRANCH}" "${PR_LABELS}" "${IS_KEEP_BRANCH_ON_PR_CLEANUP}"
