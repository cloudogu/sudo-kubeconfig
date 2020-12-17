#!/usr/bin/env bash
if [[ -n "${DEBUG}" ]]; then set -x; fi
set -o errexit -o nounset -o pipefail

# Creates a sudo kubeconfig for the current context
# Result is either printed to stdout or added to current KUBECONFIG (queried interactively)
# 
# Options can be passed via env vars:
# * SUDO_PREFIX - Prefix added to current kubecontext and user to flag it as "sudo". Default: SUDO-
# * SUDO_CONTEXT_POSTFIX - Postfix added to current kubecontext to raise attention to it being for sudo only. Default: empty.
# * DEBUG - prints echo of commands (set -x)

# Note: Keep it simple to allow auto completion with '--context='
SUDO_PREFIX=${SUDO_PREFIX:-'SUDO-'}
# Note: Be careful with this - emojis lead to escaping with kubectx, exclamation mark are special chars in shell, etc
SUDO_CONTEXT_POSTFIX=${SUDO_CONTEXT_POSTFIX:-''} # How about '-:-O'? 

context=$(kubectl config current-context)
user=$(kubectl config view -o "jsonpath={.contexts[?(@.name==\"$context\")].context.user}")
cluster="$(kubectl config view -o "jsonpath={.contexts[?(@.name==\"$context\")].context.cluster}")"
namespace="$(kubectl config view -o "jsonpath={.contexts[?(@.name==\"$context\")].context.namespace}")"

tmpConfig="$(mktemp)"

function main() {

  printStdErr "Creating sudo kubeconfig for current kube context $context"
  printStdErr 
  
  extractCurrentContextAndAddSudoUser "$tmpConfig"

  createAndActivateContextWithSudoUser
  
  sudoConfig="$(mktemp)"
  createCleanSudoKubeconfig "${sudoConfig}"
  
  printOrAddKubeconfig "${sudoConfig}"
  
  unset KUBECONFIG
  # Reset to non-sudo context, because using the sudo context is only meant to be used explicitly via --context
  kubectl config use-context "$context" > /dev/null
}

function extractCurrentContextAndAddSudoUser() {
  # export current kubeconfig only
  kubectl config view --minify --raw | \
    # Workaround sed being unable to match \n
    tr '\n' '\r' | \
    # Add sudo user
    sed -e "s/- name: $user\r\( *\)user:/- name: $SUDO_PREFIX$user\n\1user:\n\1  as: $USER\n\1  as-groups:\n\1  - system:masters/" | \
    # Bring back line breaks and write to file
    tr '\r' '\n' >  "$1"
    
  # Fail when sed failed
  grep "$SUDO_PREFIX$user" "$tmpConfig" > /dev/null || (echo "Failed to create sudo user in kubeconfig. Run with DEBUG=true for details" && return 1)
  export KUBECONFIG=${tmpConfig}:~/.kube/config 
}

function createAndActivateContextWithSudoUser() {
  kubectl config set-context "$SUDO_PREFIX$context$SUDO_CONTEXT_POSTFIX" \
    --cluster="$cluster" --user="$SUDO_PREFIX$user" --namespace="$namespace" >/dev/null
  # Active context can be exported more easily
  kubectl config use-context "$SUDO_PREFIX$context$SUDO_CONTEXT_POSTFIX" >/dev/null
}

function createCleanSudoKubeconfig() {
  # Keep only the active context, remove potential other contexts
  kubectl config view --minify --raw > "$sudoConfig"
}

function printOrAddKubeconfig() {
  if confirm "Add context '$SUDO_PREFIX$context$SUDO_CONTEXT_POSTFIX' to $HOME/.kube/config?" "Otherwise print to stdout" "y/n [n]"; then
    backup="$HOME/.kube/config.bck-$(date +%s)"
    printStdErr "Creating backup at $backup"
    cp ~/.kube/config "$backup"
    
    printStdErr
    KUBECONFIG=${sudoConfig}:~/.kube/config kubectl config view --flatten >~/.kube/config2 && mv ~/.kube/config2 ~/.kube/config
    chmod 700 ~/.kube/config
    
    printStdErr "Use sudo-kubecontext with 'kubectl --context=$SUDO_PREFIX$context$SUDO_CONTEXT_POSTFIX'"
    printStdErr "Hint 1: Use auto completion for the context"
    printStdErr "Hint 2: Also works with helm --kube-context, k9s --context, fluxctl --context, istictl, etc."
  else 
    cat "$sudoConfig"
    printStdErr 
    printStdErr "Pipe content to file an 'export KUBECONFIG=file' to use kubeconfig"
  fi
}

function confirm() {
  # shellcheck disable=SC2145
  # - the line break between args is intended here!
  >&2 printf "%s\n" "${@:-Are you sure? [y/N]} "
  
  read -r response
  case "$response" in
  [yY][eE][sS] | [yY])
    true
    ;;
  *)
    false
    ;;
  esac
}

function printStdErr() {
    # Print "logs" to stderr, so output of kubeconfig is no obstructed. 
    # Allows for ./create-sudo-kubeconfig.sh > kubeconfig-sudo.yaml
    echo "$@" 1>&2;
}

main "$@"