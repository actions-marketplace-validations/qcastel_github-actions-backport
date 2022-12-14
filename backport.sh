#!/usr/bin/env bash
set -e

# avoid the release loop by checking if the latest commit is a release commit
readonly local last_commit_author=$(git --no-pager show -s --format='%an' "${GITHUB_SHA}")
echo "Last commit author: ${last_commit_author}"
if [[ "${last_commit_author}" == "${GIT_RELEASE_BOT_NAME}" ]]; then
     echo "Skipping current commit, as the author is the bot '${GIT_RELEASE_BOT_NAME}'"
     exit 0
fi

# Making sure we are on top of the branch
echo "Git checkout branch ${GITHUB_REF##*/}"
git checkout ${GITHUB_REF##*/}
echo "Git reset hard to ${GITHUB_SHA}"
git reset --hard ${GITHUB_SHA}

# This script will do a release of the artifact according to http://maven.apache.org/maven-release/maven-release-plugin/
echo "Setup git user name to '$GIT_RELEASE_BOT_NAME'"
git config --global user.name "$GIT_RELEASE_BOT_NAME";
echo "Setup git user email to '$GIT_RELEASE_BOT_EMAIL'"
git config --global user.email "$GIT_RELEASE_BOT_EMAIL";

# Set up .netrc file with GitHub credentials
cat <<- EOF > $HOME/.netrc
    machine github.com
    login $GIT_RELEASE_BOT_NAME
    password $GITHUB_ACCESS_TOKEN
    machine api.github.com
    login $GIT_RELEASE_BOT_NAME
    password $GITHUB_ACCESS_TOKEN
EOF
chmod 600 $HOME/.netrc

# Setup GPG
echo "GPG_ENABLED '$GPG_ENABLED'"
if [[ $GPG_ENABLED == "true" ]]; then
     echo "Enable GPG signing in git config"
     git config --global commit.gpgsign true
     echo "Using the GPG key ID $GPG_KEY_ID"
     git config --global user.signingkey $GPG_KEY_ID
     echo "GPG_KEY_ID = $GPG_KEY_ID"
     echo "Import the GPG key"
     echo  "$GPG_KEY" | base64 -d > private.key
     gpg --import ./private.key
     rm ./private.key
else
  echo "GPG signing is not enabled"
fi

reviewers=""
if [[ -n $REVIEWERS_USERS ]]; then
  echo "User reviewers: ${REVIEWERS_USERS}"
  reviewers="\"reviewers\": $REVIEWERS_USERS"
else
    echo "No user reviewer defined for this github action"
fi

if [[ -n $REVIEWERS_TEAMS ]]; then
  echo "Team reviewers: ${REVIEWERS_TEAMS}"
  if [[ -n $REVIEWERS_USERS ]]; then
      reviewers="${reviewers},"
  fi
  reviewers="${reviewers}\"team_reviewers\": $REVIEWERS_TEAMS"
else
  echo "No team reviewer defined for this github action"
fi
echo "The reviewers for those PRs: $reviewers"

echo "Show how the remote are setup"
git remote -v

echo "Create the backport PR for each of the ${BACKPORT_BRANCHES_REGEX} branches"
# Cherry pick master in every select branches and create a PR
for branch in $(git branch -r | grep ${BACKPORT_BRANCHES_REGEX} | sed 's/origin\///'); do
    echo "Backporting to branch ??{branch}"
    git checkout -b auto-${branch} origin/${branch}

    echo "Cherry-pick the latest commit"
    git cherry-pick ${GITHUB_SHA}

    echo "Push branch to upstream"
    git push -f origin auto-${branch}

    echo "Create PR"
    response=$(curl -v -X POST \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls?access_token=$GITHUB_ACCESS_TOKEN" \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${GITHUB_ACCESS_TOKEN}" \
      -d "{
            \"title\": \"${PR_TITLE}\",
            \"body\": \"${PR_BODY}\",
            \"head\": \"auto-${branch}\",
            \"base\": \"${branch}\"
          }")

    echo "Response: ${response}"

    if [[ -n $reviewers ]]; then
      echo "Add reviewers"
      pull_request_id=$(echo "$response" | jq .number)
      echo "pull request ID: ${pull_request_id}"
      echo "Request body \"{ ${reviewers} }\""
      curl -v -X POST \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${pull_request_id}/requested_reviewers?access_token=$GITHUB_ACCESS_TOKEN" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer ${GITHUB_ACCESS_TOKEN}" \
        -d "{ ${reviewers} }"
    fi
done