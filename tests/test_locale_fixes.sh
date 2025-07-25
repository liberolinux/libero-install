#!/bin/bash
# Test script for locale configuration fixes

# Source the functions we want to test
# We'll mock the environment to avoid dependencies
LIBERO_INSTALL_REPO_DIR="$(dirname "$(dirname "$(realpath "$0")")")"

# Mock functions
function einfo() { echo "[INFO] $*"; }
function ewarn() { echo "[WARN] $*"; }
function eerror() { echo "[ERROR] $*"; }
function die() { echo "[FATAL] $*"; exit 1; }

# Source the functions
source "$LIBERO_INSTALL_REPO_DIR/scripts/main.sh"

# Test cases
function test_validate_locale_configuration() {
    echo "=== Testing validate_locale_configuration ==="
    
    # Test valid locale
    echo "Test 1: Valid locale configuration"
    LOCALE="en_US.UTF-8"
    LOCALES="en_US.UTF-8 UTF-8"
    MUSL="false"
    if validate_locale_configuration "$LOCALE" "$LOCALES"; then
        echo "✓ Valid configuration passed"
    else
        echo "✗ Valid configuration failed"
    fi
    
    # Test invalid locale format
    echo "Test 2: Invalid locale format"
    LOCALE="invalid-locale-name"
    if validate_locale_configuration "$LOCALE" "$LOCALES"; then
        echo "✓ Invalid format detected (warnings shown)"
    else
        echo "✗ Invalid format not properly handled"
    fi
    
    # Test missing locale in LOCALES
    echo "Test 3: Locale not in LOCALES"
    LOCALE="fr_FR.UTF-8"
    LOCALES="en_US.UTF-8 UTF-8"
    if validate_locale_configuration "$LOCALE" "$LOCALES"; then
        echo "✓ Missing locale detected (warnings shown)"
    else
        echo "✗ Missing locale not properly detected"
    fi
    
    echo ""
}

function test_auto_fix_locale_configuration() {
    echo "=== Testing auto_fix_locale_configuration ==="
    
    # Test auto-fix for empty LOCALES
    echo "Test 1: Auto-fix empty LOCALES with set LOCALE"
    LOCALE="de_DE.UTF-8"
    LOCALES=""
    MUSL="false"
    auto_fix_locale_configuration
    echo "After auto-fix, LOCALES='$LOCALES'"
    if [[ "$LOCALES" =~ de_DE\.UTF-8 ]]; then
        echo "✓ Auto-fix added locale to LOCALES"
    else
        echo "✗ Auto-fix failed to add locale to LOCALES"
    fi
    
    # Test fallback C.UTF-8 addition
    echo "Test 2: Auto-fix adds C.UTF-8 fallback"
    LOCALE="C.UTF-8"
    LOCALES=""
    auto_fix_locale_configuration
    if [[ "$LOCALES" =~ C\.UTF-8 ]]; then
        echo "✓ Auto-fix added C.UTF-8 fallback"
    else
        echo "✗ Auto-fix failed to add C.UTF-8 fallback"
    fi
    
    echo ""
}

# Run tests
test_validate_locale_configuration
test_auto_fix_locale_configuration

echo "=== Locale fixes test completed ==="
