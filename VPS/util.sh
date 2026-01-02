# Prevent double sourcing
if [ -n "${UTIL_SH_SOURCED}" ]; then
    return
fi
readonly UTIL_SH_SOURCED=true

# Color Definitions
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Logging Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1" >&2
}

# Error Handling
error_exit() {
    log_error "$1"
    exit 1
}

# Dependency Checking
check_dependencies() {
    local missing_dependencies=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_dependencies+=("$dep")
        fi
    done

    if [[ ${#missing_dependencies[@]} -ne 0 ]]; then
        log_error "缺少以下依赖: ${missing_dependencies[*]}"
        log_info "请安装缺少的依赖后重试"
        return 1
    fi
}