#!/bin/bash
# Build Script for bloom-telnet terminal capability detection tool

set -e # Exit on any error
set -u # Treat unset variables as errors

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="bloom-telnet"
BUILD_DIR="build"
INSTALL_PREFIX="$HOME/.local"
ENABLE_DEBUG=true
PARALLEL_JOBS=$(nproc)

# Logging functions
log_info() {
	echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
	echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

# Compute version from git tags
get_version() {
	if git describe --tags --match 'v*' HEAD >/dev/null 2>&1; then
		# v0.1 → "0.1", v0.1-5-gabc1234 → "0.1.5-abc1234"
		git describe --tags --match 'v*' HEAD | sed 's/^v//;s/-\([0-9]*\)-g/.\1-/'
	else
		# No tags: 0.0.N-HASH
		local count
		count=$(git rev-list --count HEAD)
		local hash
		hash=$(git rev-parse --short HEAD)
		echo "0.0.${count}-${hash}"
	fi
}

# Setup local dependencies (user-installed packages in ~/.local)
setup_local_deps() {
	local local_pkgconfig="$HOME/.local/lib/pkgconfig"
	local local_lib="$HOME/.local/lib"

	# Prioritize user-local pkgconfig path (prepend to find ~/.local packages first)
	if [ -d "$local_pkgconfig" ]; then
		if [ -f "$local_pkgconfig/bloom-lisp.pc" ]; then
			log_info "Found bloom-lisp in $local_pkgconfig"
			export PKG_CONFIG_PATH="${local_pkgconfig}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
			export LD_LIBRARY_PATH="${local_lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
		fi
	fi

	# Verify bloom-lisp is available
	if ! pkg-config --exists bloom-lisp 2>/dev/null; then
		log_error "bloom-lisp not found. Install it to ~/.local or system-wide."
		log_error "See: https://github.com/thomasc1971/bloom-lisp"
		return 1
	fi

	log_info "Using bloom-lisp: $(pkg-config --modversion bloom-lisp)"

	# Verify bloom-boba is available
	if ! pkg-config --exists bloom-boba 2>/dev/null; then
		log_error "bloom-boba not found. Install it to ~/.local or system-wide."
		log_error "Build it from: ../bloom-boba"
		return 1
	fi

	log_info "Using bloom-boba: $(pkg-config --modversion bloom-boba)"
	return 0
}

# Check if running on Fedora 41+
check_os() {
	log_info "Checking operating system..."
	if [ -f /etc/fedora-release ]; then
		FEDORA_VERSION=$(grep -oP 'Fedora release \K\d+' /etc/fedora-release)
		if [ "$FEDORA_VERSION" -ge 41 ]; then
			log_info "Running on Fedora $FEDORA_VERSION"
		else
			log_warn "Running on Fedora $FEDORA_VERSION (expected Fedora 41+)"
		fi
	else
		log_warn "Not running on Fedora. Some dependencies may differ."
	fi
}

# Generate configure script
generate_configure() {
	log_info "Generating configure script..."

	# Write version file for configure.ac
	get_version >version
	log_info "Version: $(cat version)"

	# Clean up any existing generated files
	log_info "Cleaning up generated files..."
	rm -f configure aclocal.m4
	rm -rf autom4te.cache

	if [ -f configure ]; then
		log_info "Removing existing configure script"
		rm -f configure
	fi

	autoreconf -fvi

	if [ $? -ne 0 ]; then
		log_error "Failed to generate configure script"
		return 1
	fi

	log_info "Configure script generated successfully"
	return 0
}

# Configure the build
configure_build() {
	log_info "Configuring build..."

	# Create build directory if it doesn't exist
	if [ -d "$BUILD_DIR" ]; then
		log_info "Removing existing build directory"
		rm -rf "$BUILD_DIR"
	fi

	mkdir -p "$BUILD_DIR"
	cd "$BUILD_DIR"

	# Build configure command
	CONFIGURE_CMD="../configure --prefix=$INSTALL_PREFIX"

	if [ "$ENABLE_DEBUG" = true ]; then
		CONFIGURE_CMD="$CONFIGURE_CMD CFLAGS='-O0 -g3 -DDEBUG'"
	fi

	log_info "Running: $CONFIGURE_CMD"
	eval $CONFIGURE_CMD

	if [ $? -ne 0 ]; then
		log_error "Configure failed"
		if [ -f "config.log" ]; then
			log_error "Last 50 lines of config.log:"
			tail -50 config.log
		fi
		cd ..
		return 1
	fi

	cd ..
	log_info "Build configured successfully"
	return 0
}

# Build the project
build_project() {
	local use_bear=${1:-false}

	log_info "Building project..."

	cd "$BUILD_DIR"

	if [ "$use_bear" = true ]; then
		log_info "Generating compile_commands.json with bear..."
		bear --output ../compile_commands.json -- make -j"$PARALLEL_JOBS"
	else
		log_info "Running make with $PARALLEL_JOBS parallel jobs"
		make -j"$PARALLEL_JOBS"
	fi

	if [ $? -ne 0 ]; then
		log_error "Build failed"
		cd ..
		return 1
	fi

	cd ..
	log_info "Project built successfully"
	return 0
}

# Install the project (optional)
install_project() {
	log_info "Installing project to $INSTALL_PREFIX..."

	cd "$BUILD_DIR"

	if ! make install; then
		log_error "Installation failed"
		cd ..
		return 1
	fi

	cd ..
	log_info "Project installed successfully"
	return 0
}

# Format source files
format_sources() {
	log_info "Formatting source files..."

	# Format C/C++ files with clang-format
	if command -v clang-format &>/dev/null; then
		log_info "Formatting C/C++ files with clang-format..."
		find src/ -name "*.c" -o -name "*.h" | xargs clang-format -i
	else
		log_warn "clang-format not found. Skipping C/C++ formatting."
	fi

	# Format shell scripts with shfmt
	if command -v shfmt &>/dev/null; then
		log_info "Formatting shell scripts with shfmt..."
		shfmt -w build.sh autogen.sh 2>/dev/null || true
	else
		log_warn "shfmt not found. Skipping shell script formatting."
	fi

	# Format Lisp files with lisp-fmt.lisp
	if [ -d "lisp" ]; then
		log_info "Formatting Lisp files with lisp-fmt.lisp..."
		local repl_path=""
		if [ -x "$INSTALL_PREFIX/bin/bloom-repl" ]; then
			repl_path="$INSTALL_PREFIX/bin/bloom-repl"
		elif command -v bloom-repl &>/dev/null; then
			repl_path="bloom-repl"
		fi

		# Find lisp-fmt.lisp in bloom-lisp installation or sibling directory
		local lisp_fmt=""
		if [ -f "$INSTALL_PREFIX/share/bloom-lisp/lisp-fmt.lisp" ]; then
			lisp_fmt="$INSTALL_PREFIX/share/bloom-lisp/lisp-fmt.lisp"
		elif [ -f "../bloom-lisp/lisp/lisp-fmt.lisp" ]; then
			lisp_fmt="../bloom-lisp/lisp/lisp-fmt.lisp"
		fi

		if [ -n "$repl_path" ] && [ -n "$lisp_fmt" ]; then
			find lisp/ -name "*.lisp" | while read -r file; do
				"$repl_path" "$lisp_fmt" -- -i "$file"
			done
		else
			if [ -z "$repl_path" ]; then
				log_warn "bloom-repl not found. Skipping Lisp formatting."
			elif [ -z "$lisp_fmt" ]; then
				log_warn "lisp-fmt.lisp not found. Skipping Lisp formatting."
			fi
		fi
	fi

	# Format Python files with black
	if command -v black &>/dev/null; then
		log_info "Formatting Python files with black..."
		find . -name "*.py" -not -path "./$BUILD_DIR/*" | xargs black 2>/dev/null || true
	else
		log_warn "black not found. Skipping Python formatting."
	fi

	# Format markdown files with prettier
	if command -v prettier &>/dev/null; then
		log_info "Formatting markdown files with prettier..."
		find . -name "*.md" | xargs prettier --write
	else
		log_warn "prettier not found. Skipping markdown formatting."
	fi

	log_info "Formatting completed."
}

# Default build action
do_build() {
	check_os

	# Setup local dependencies (bloom-lisp from ~/.local)
	if ! setup_local_deps; then
		exit 1
	fi

	# If --install flag is used, skip build and run steps
	if [ "${INSTALL_ONLY:-false}" = true ]; then
		log_info "Installing project only (--install flag used)"

		if ! generate_configure; then
			exit 1
		fi

		if ! configure_build; then
			exit 1
		fi

		log_info "Installing project to $INSTALL_PREFIX"
		if ! install_project; then
			log_error "Installation failed"
			exit 1
		fi
	else
		if ! generate_configure; then
			exit 1
		fi

		if ! configure_build; then
			exit 1
		fi

		if [ "${USE_BEAR:-false}" = true ]; then
			if ! build_project true; then
				exit 1
			fi
		else
			if ! build_project; then
				exit 1
			fi
		fi
	fi

	# Run tests if requested
	if [ "${RUN_TESTS:-false}" = true ]; then
		log_info "Running tests..."
		cd "$BUILD_DIR"
		if ! make check; then
			log_error "Tests failed"
			cd ..
			exit 1
		fi
		cd ..
		log_info "All tests passed"
	fi

	log_info "Build process completed successfully!"
	log_info "Build directory: $BUILD_DIR"
	log_info "To run the application: ./$BUILD_DIR/src/$PROJECT_NAME"
}

# Main execution
main() {
	local ACTION="build"

	# Parse all arguments first, then dispatch
	while [[ $# -gt 0 ]]; do
		case $1 in
		--install)
			INSTALL_ONLY=true
			shift
			;;
		--bear)
			USE_BEAR=true
			shift
			;;
		--no-debug)
			ENABLE_DEBUG=false
			shift
			;;
		--prefix=*)
			INSTALL_PREFIX="${1#*=}"
			shift
			;;
		--format)
			ACTION=format
			shift
			;;
		--test)
			RUN_TESTS=true
			shift
			;;
		--help)
			echo "Usage: $0 [options]"
			echo "Options:"
			echo "  --install         Only install the project (skip build and run)"
			echo "  --bear            Generate compile_commands.json using bear"
			echo "  --no-debug        Disable debug build"
			echo "  --test            Run tests after building (make check)"
			echo "  --format          Format source files with clang-format, shfmt, black, and prettier"
			echo "  --prefix=PATH     Set installation prefix (default: $HOME/.local)"
			echo "  --help            Show this help message"
			exit 0
			;;
		*)
			log_error "Unknown option: $1"
			echo "Use --help for usage information"
			exit 1
			;;
		esac
	done

	# Dispatch action
	case "$ACTION" in
	build)
		log_info "Starting build process for $PROJECT_NAME"
		do_build
		;;
	format)
		format_sources
		;;
	esac
}

# Run main function with all arguments
main "$@"
