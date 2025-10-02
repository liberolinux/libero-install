if [[ "$LIBERO_INSTALL_REPO_SCRIPT_ACTIVE" != "true" ]]; then
    printf '%b\n' "\e[1;31m * ERROR:\e[m This script must not be executed directly!" >&2
    exit 1
fi
